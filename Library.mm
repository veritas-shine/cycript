/* Cyrker - Remove Execution Server and Disassembler
 * Copyright (C) 2009  Jay Freeman (saurik)
*/

/* Modified BSD License {{{ */
/*
 *        Redistribution and use in source and binary
 * forms, with or without modification, are permitted
 * provided that the following conditions are met:
 *
 * 1. Redistributions of source code must retain the
 *    above copyright notice, this list of conditions
 *    and the following disclaimer.
 * 2. Redistributions in binary form must reproduce the
 *    above copyright notice, this list of conditions
 *    and the following disclaimer in the documentation
 *    and/or other materials provided with the
 *    distribution.
 * 3. The name of the author may not be used to endorse
 *    or promote products derived from this software
 *    without specific prior written permission.
 *
 * THIS SOFTWARE IS PROVIDED BY THE AUTHOR ``AS IS''
 * AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING,
 * BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF
 * MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
 * ARE DISCLAIMED. IN NO EVENT SHALL THE AUTHOR BE
 * LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL,
 * EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT
 * NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
 * SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
 * INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF
 * LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR
 * TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN
 * ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF
 * ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
*/
/* }}} */

#define _GNU_SOURCE

#include <substrate.h>
#include "cycript.hpp"

#include "sig/parse.hpp"
#include "sig/ffi_type.hpp"

#include "Pooling.hpp"
#include "Struct.hpp"

#include <unistd.h>

#include <CoreFoundation/CoreFoundation.h>
#include <CoreFoundation/CFLogUtilities.h>

#include <CFNetwork/CFNetwork.h>

#include <WebKit/WebScriptObject.h>

#include <sys/types.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <sys/mman.h>

#include <iostream>
#include <ext/stdio_filebuf.h>
#include <set>
#include <map>

#include <cmath>

#include "Parser.hpp"
#include "Cycript.tab.hh"

#undef _assert
#undef _trace

#define _assert(test) do { \
    if (!(test)) \
        @throw [NSException exceptionWithName:NSInternalInconsistencyException reason:[NSString stringWithFormat:@"_assert(%s):%s(%u):%s", #test, __FILE__, __LINE__, __FUNCTION__] userInfo:nil]; \
} while (false)

#define _trace() do { \
    CFLog(kCFLogLevelNotice, CFSTR("_trace():%u"), __LINE__); \
} while (false)

#define CYPoolTry { \
    id _saved(nil); \
    NSAutoreleasePool *_pool([[NSAutoreleasePool alloc] init]); \
    @try
#define CYPoolCatch(value) \
    @catch (NSException *error) { \
        _saved = [error retain]; \
        @throw; \
        return value; \
    } @finally { \
        [_pool release]; \
        if (_saved != nil) \
            [_saved autorelease]; \
    } \
}

static JSGlobalContextRef Context_;
static JSObjectRef System_;

static JSClassRef Functor_;
static JSClassRef Instance_;
static JSClassRef Pointer_;
static JSClassRef Runtime_;
static JSClassRef Selector_;
static JSClassRef Struct_;

static JSObjectRef Array_;
static JSObjectRef Function_;

static JSStringRef name_;
static JSStringRef message_;
static JSStringRef length_;

static Class NSCFBoolean_;

static NSArray *Bridge_;

struct Client {
    CFHTTPMessageRef message_;
    CFSocketRef socket_;
};

struct CYData {
    apr_pool_t *pool_;

    virtual ~CYData() {
    }

    void *operator new(size_t size) {
        apr_pool_t *pool;
        apr_pool_create(&pool, NULL);
        void *data(apr_palloc(pool, size));
        reinterpret_cast<CYData *>(data)->pool_ = pool;
        return data;;
    }

    static void Finalize(JSObjectRef object) {
        CYData *data(reinterpret_cast<CYData *>(JSObjectGetPrivate(object)));
        data->~CYData();
        apr_pool_destroy(data->pool_);
    }
};

struct Pointer_privateData :
    CYData
{
    void *value_;
    sig::Type type_;

    Pointer_privateData() {
    }

    Pointer_privateData(void *value) :
        value_(value)
    {
    }
};

struct Functor_privateData :
    Pointer_privateData
{
    sig::Signature signature_;
    ffi_cif cif_;

    Functor_privateData(const char *type, void (*value)()) :
        Pointer_privateData(reinterpret_cast<void *>(value))
    {
        sig::Parse(pool_, &signature_, type);
        sig::sig_ffi_cif(pool_, &sig::ObjectiveC, &signature_, &cif_);
    }
};

struct ffoData :
    Functor_privateData
{
    JSContextRef context_;
    JSObjectRef function_;

    ffoData(const char *type) :
        Functor_privateData(type, NULL)
    {
    }
};

struct Selector_privateData : Pointer_privateData {
    Selector_privateData(SEL value) :
        Pointer_privateData(value)
    {
    }

    SEL GetValue() const {
        return reinterpret_cast<SEL>(value_);
    }
};

struct Instance_privateData :
    Pointer_privateData
{
    bool transient_;

    Instance_privateData(id value, bool transient) :
        Pointer_privateData(value)
    {
    }

    virtual ~Instance_privateData() {
        if (!transient_)
            [GetValue() release];
    }

    id GetValue() const {
        return reinterpret_cast<id>(value_);
    }
};

namespace sig {

void Copy(apr_pool_t *pool, Type &lhs, Type &rhs);

void Copy(apr_pool_t *pool, Element &lhs, Element &rhs) {
    lhs.name = apr_pstrdup(pool, rhs.name);
    if (rhs.type == NULL)
        lhs.type = NULL;
    else {
        lhs.type = new(pool) Type;
        Copy(pool, *lhs.type, *rhs.type);
    }
    lhs.offset = rhs.offset;
}

void Copy(apr_pool_t *pool, Signature &lhs, Signature &rhs) {
    size_t count(rhs.count);
    lhs.count = count;
    lhs.elements = new(pool) Element[count];
    for (size_t index(0); index != count; ++index)
        Copy(pool, lhs.elements[index], rhs.elements[index]);
}

void Copy(apr_pool_t *pool, Type &lhs, Type &rhs) {
    lhs.primitive = rhs.primitive;
    lhs.name = apr_pstrdup(pool, rhs.name);
    lhs.flags = rhs.flags;

    if (sig::IsAggregate(rhs.primitive))
        Copy(pool, lhs.data.signature, rhs.data.signature);
    else {
        if (rhs.data.data.type != NULL) {
            lhs.data.data.type = new(pool) Type;
            Copy(pool, *lhs.data.data.type, *rhs.data.data.type);
        }

        lhs.data.data.size = rhs.data.data.size;
    }
}

void Copy(apr_pool_t *pool, ffi_type &lhs, ffi_type &rhs) {
    lhs.size = rhs.size;
    lhs.alignment = rhs.alignment;
    lhs.type = rhs.type;
    if (rhs.elements == NULL)
        lhs.elements = NULL;
    else {
        size_t count(0);
        while (rhs.elements[count] != NULL)
            ++count;

        lhs.elements = new(pool) ffi_type *[count + 1];
        lhs.elements[count] = NULL;

        for (size_t index(0); index != count; ++index) {
            // XXX: if these are libffi native then you can just take them
            ffi_type *ffi(new(pool) ffi_type);
            lhs.elements[index] = ffi;
            sig::Copy(pool, *ffi, *rhs.elements[index]);
        }
    }
}

}

struct Type_privateData {
    sig::Type type_;
    ffi_type ffi_;
    //size_t count_;

    Type_privateData(apr_pool_t *pool, sig::Type *type, ffi_type *ffi) {
        sig::Copy(pool, type_, *type);
        sig::Copy(pool, ffi_, *ffi);

        /*sig::Element element;
        element.name = NULL;
        element.type = type;
        element.offset = 0;

        sig::Signature signature;
        signature.elements = &element;
        signature.count = 1;

        ffi_cif cif;
        sig::sig_ffi_cif(pool, &sig::ObjectiveC, &signature, &cif);
        ffi_ = *cif.rtype;*/

        /*if (type_->type != FFI_TYPE_STRUCT)
            count_ = 0;
        else {
            size_t count(0);
            while (type_->elements[count] != NULL)
                ++count;
            count_ = count;
        }*/
    }
};

struct Struct_privateData :
    Pointer_privateData
{
    JSObjectRef owner_;
    Type_privateData *type_;

    Struct_privateData() {
    }
};

struct CStringMapLess :
    std::binary_function<const char *, const char *, bool>
{
    _finline bool operator ()(const char *lhs, const char *rhs) const {
        return strcmp(lhs, rhs) < 0;
    }
};

typedef std::map<const char *, Type_privateData *, CStringMapLess> TypeMap;
static TypeMap Types_;

JSObjectRef CYMakeStruct(JSContextRef context, void *data, sig::Type *type, ffi_type *ffi, JSObjectRef owner) {
    Struct_privateData *internal(new Struct_privateData());
    apr_pool_t *pool(internal->pool_);
    Type_privateData *typical(new(pool) Type_privateData(pool, type, ffi));
    internal->type_ = typical;

    if (owner != NULL) {
        internal->owner_ = owner;
        internal->value_ = data;
    } else {
        internal->owner_ = NULL;

        size_t size(typical->ffi_.size);
        void *copy(apr_palloc(internal->pool_, size));
        memcpy(copy, data, size);
        internal->value_ = copy;
    }

    return JSObjectMake(context, Struct_, internal);
}

JSObjectRef CYMakeInstance(JSContextRef context, id object, bool transient) {
    if (!transient)
        object = [object retain];
    Instance_privateData *data(new Instance_privateData(object, transient));
    return JSObjectMake(context, Instance_, data);
}

const char *CYPoolCString(apr_pool_t *pool, NSString *value) {
    if (pool == NULL)
        return [value UTF8String];
    else {
        size_t size([value maximumLengthOfBytesUsingEncoding:NSUTF8StringEncoding] + 1);
        char *string(new(pool) char[size]);
        if (![value getCString:string maxLength:size encoding:NSUTF8StringEncoding])
            @throw [NSException exceptionWithName:NSInvalidArgumentException reason:@"[NSString getCString:maxLength:encoding:] == NO" userInfo:nil];
        return string;
    }
}

JSValueRef CYCastJSValue(JSContextRef context, bool value) {
    return JSValueMakeBoolean(context, value);
}

JSValueRef CYCastJSValue(JSContextRef context, double value) {
    return JSValueMakeNumber(context, value);
}

#define CYCastJSValue_(Type_) \
    JSValueRef CYCastJSValue(JSContextRef context, Type_ value) { \
        return JSValueMakeNumber(context, static_cast<double>(value)); \
    }

CYCastJSValue_(int)
CYCastJSValue_(unsigned int)
CYCastJSValue_(long int)
CYCastJSValue_(long unsigned int)
CYCastJSValue_(long long int)
CYCastJSValue_(long long unsigned int)

JSValueRef CYJSUndefined(JSContextRef context) {
    return JSValueMakeUndefined(context);
}

@interface NSMethodSignature (Cycript)
- (NSString *) _typeString;
@end

@interface NSObject (Cycript)
- (bool) cy$isUndefined;
- (NSString *) cy$toJSON;
- (JSValueRef) cy$JSValueInContext:(JSContextRef)context transient:(bool)transient;
- (NSObject *) cy$getProperty:(NSString *)name;
- (bool) cy$setProperty:(NSString *)name to:(NSObject *)value;
- (bool) cy$deleteProperty:(NSString *)name;
@end

@interface NSString (Cycript)
- (void *) cy$symbol;
@end

@interface NSNumber (Cycript)
- (void *) cy$symbol;
@end

@implementation NSObject (Cycript)

- (bool) cy$isUndefined {
    return false;
}

- (NSString *) cy$toJSON {
    return [self description];
}

- (JSValueRef) cy$JSValueInContext:(JSContextRef)context transient:(bool)transient {
    return CYMakeInstance(context, self, transient);
}

- (NSObject *) cy$getProperty:(NSString *)name {
    if (![name isEqualToString:@"prototype"])
        NSLog(@"get:%@", name);
    return nil;
}

- (bool) cy$setProperty:(NSString *)name to:(NSObject *)value {
    NSLog(@"set:%@", name);
    return false;
}

- (bool) cy$deleteProperty:(NSString *)name {
    NSLog(@"delete:%@", name);
    return false;
}

@end

@implementation WebUndefined (Cycript)

- (bool) cy$isUndefined {
    return true;
}

- (NSString *) cy$toJSON {
    return @"undefined";
}

- (JSValueRef) cy$JSValueInContext:(JSContextRef)context transient:(bool)transient {
    return CYJSUndefined(context);
}

@end

@implementation NSNull (Cycript)

- (NSString *) cy$toJSON {
    return @"null";
}

@end

@implementation NSArray (Cycript)

- (NSString *) cy$toJSON {
    NSMutableString *json([[[NSMutableString alloc] init] autorelease]);
    [json appendString:@"["];

    bool comma(false);
    for (id object in self) {
        if (comma)
            [json appendString:@","];
        else
            comma = true;
        if (![object cy$isUndefined])
            [json appendString:[object cy$toJSON]];
        else {
            [json appendString:@","];
            comma = false;
        }
    }

    [json appendString:@"]"];
    return json;
}

- (NSObject *) cy$getProperty:(NSString *)name {
    int index([name intValue]);
    if (index < 0 || index >= static_cast<int>([self count]))
        return [super cy$getProperty:name];
    else
        return [self objectAtIndex:index];
}

@end

@implementation NSMutableArray (Cycript)

- (bool) cy$setProperty:(NSString *)name to:(NSObject *)value {
    int index([name intValue]);
    if (index < 0 || index >= static_cast<int>([self count]))
        return [super cy$setProperty:name to:value];
    else {
        [self replaceObjectAtIndex:index withObject:(value ?: [NSNull null])];
        return true;
    }
}

- (bool) cy$deleteProperty:(NSString *)name {
    int index([name intValue]);
    if (index < 0 || index >= static_cast<int>([self count]))
        return [super cy$deleteProperty:name];
    else {
        [self removeObjectAtIndex:index];
        return true;
    }
}

@end

@implementation NSDictionary (Cycript)

- (NSString *) cy$toJSON {
    NSMutableString *json([[[NSMutableString alloc] init] autorelease]);
    [json appendString:@"({"];

    bool comma(false);
    for (id key in self) {
        if (comma)
            [json appendString:@","];
        else
            comma = true;
        [json appendString:[key cy$toJSON]];
        [json appendString:@":"];
        NSObject *object([self objectForKey:key]);
        [json appendString:[object cy$toJSON]];
    }

    [json appendString:@"})"];
    return json;
}

- (NSObject *) cy$getProperty:(NSString *)name {
    return [self objectForKey:name];
}

@end

@implementation NSMutableDictionary (Cycript)

- (bool) cy$setProperty:(NSString *)name to:(NSObject *)value {
    [self setObject:(value ?: [NSNull null]) forKey:name];
    return true;
}

- (bool) cy$deleteProperty:(NSString *)name {
    if ([self objectForKey:name] == nil)
        return false;
    else {
        [self removeObjectForKey:name];
        return true;
    }
}

@end

@implementation NSNumber (Cycript)

- (NSString *) cy$toJSON {
    return [self class] != NSCFBoolean_ ? [self stringValue] : [self boolValue] ? @"true" : @"false";
}

- (JSValueRef) cy$JSValueInContext:(JSContextRef)context transient:(bool)transient {
    return [self class] != NSCFBoolean_ ? CYCastJSValue(context, [self doubleValue]) : CYCastJSValue(context, [self boolValue]);
}

- (void *) cy$symbol {
    return [self pointerValue];
}

@end

@implementation NSString (Cycript)

- (NSString *) cy$toJSON {
    CFMutableStringRef json(CFStringCreateMutableCopy(kCFAllocatorDefault, 0, (CFStringRef) self));

    CFStringFindAndReplace(json, CFSTR("\\"), CFSTR("\\\\"), CFRangeMake(0, CFStringGetLength(json)), 0);
    CFStringFindAndReplace(json, CFSTR("\""), CFSTR("\\\""), CFRangeMake(0, CFStringGetLength(json)), 0);
    CFStringFindAndReplace(json, CFSTR("\t"), CFSTR("\\t"), CFRangeMake(0, CFStringGetLength(json)), 0);
    CFStringFindAndReplace(json, CFSTR("\r"), CFSTR("\\r"), CFRangeMake(0, CFStringGetLength(json)), 0);
    CFStringFindAndReplace(json, CFSTR("\n"), CFSTR("\\n"), CFRangeMake(0, CFStringGetLength(json)), 0);

    CFStringInsert(json, 0, CFSTR("\""));
    CFStringAppend(json, CFSTR("\""));

    return [reinterpret_cast<const NSString *>(json) autorelease];
}

- (void *) cy$symbol {
    CYPool pool;
    return dlsym(RTLD_DEFAULT, CYPoolCString(pool, self));
}

@end

@interface CYJSObject : NSDictionary {
    JSObjectRef object_;
    JSContextRef context_;
}

- (id) initWithJSObject:(JSObjectRef)object inContext:(JSContextRef)context;

- (NSUInteger) count;
- (id) objectForKey:(id)key;
- (NSEnumerator *) keyEnumerator;
- (void) setObject:(id)object forKey:(id)key;
- (void) removeObjectForKey:(id)key;

@end

@interface CYJSArray : NSArray {
    JSObjectRef object_;
    JSContextRef context_;
}

- (id) initWithJSObject:(JSObjectRef)object inContext:(JSContextRef)context;

- (NSUInteger) count;
- (id) objectAtIndex:(NSUInteger)index;

@end

CYRange WordStartRange_(0x1000000000LLU,0x7fffffe87fffffeLLU); // A-Za-z_$
CYRange WordEndRange_(0x3ff001000000000LLU,0x7fffffe87fffffeLLU); // A-Za-z_$0-9

JSGlobalContextRef CYGetJSContext() {
    return Context_;
}

#define CYTry \
    @try
#define CYCatch \
    @catch (id error) { \
        CYThrow(context, error, exception); \
        return NULL; \
    }

void CYThrow(JSContextRef context, JSValueRef value);

apr_status_t CYPoolRelease_(void *data) {
    id object(reinterpret_cast<id>(data));
    [object release];
    return APR_SUCCESS;
}

id CYPoolRelease(apr_pool_t *pool, id object) {
    if (pool == NULL)
        return [object autorelease];
    else {
        apr_pool_cleanup_register(pool, object, &CYPoolRelease_, &apr_pool_cleanup_null);
        return object;
    }
}

CFTypeRef CYPoolRelease(apr_pool_t *pool, CFTypeRef object) {
    return (CFTypeRef) CYPoolRelease(pool, (id) object);
}

id CYCastNSObject(apr_pool_t *pool, JSContextRef context, JSObjectRef object) {
    if (JSValueIsObjectOfClass(context, object, Instance_)) {
        Instance_privateData *data(reinterpret_cast<Instance_privateData *>(JSObjectGetPrivate(object)));
        return data->GetValue();
    }

    JSValueRef exception(NULL);
    bool array(JSValueIsInstanceOfConstructor(context, object, Array_, &exception));
    CYThrow(context, exception);
    id value(array ? [CYJSArray alloc] : [CYJSObject alloc]);
    return CYPoolRelease(pool, [value initWithJSObject:object inContext:context]);
}

JSStringRef CYCopyJSString(id value) {
    return value == NULL ? NULL : JSStringCreateWithCFString(reinterpret_cast<CFStringRef>([value description]));
}

JSStringRef CYCopyJSString(const char *value) {
    return value == NULL ? NULL : JSStringCreateWithUTF8CString(value);
}

JSStringRef CYCopyJSString(JSStringRef value) {
    return value == NULL ? NULL : JSStringRetain(value);
}

JSStringRef CYCopyJSString(JSContextRef context, JSValueRef value) {
    if (JSValueIsNull(context, value))
        return NULL;
    JSValueRef exception(NULL);
    JSStringRef string(JSValueToStringCopy(context, value, &exception));
    CYThrow(context, exception);
    return string;
}

class CYJSString {
  private:
    JSStringRef string_;

    void Clear_() {
        JSStringRelease(string_);
    }

  public:
    CYJSString(const CYJSString &rhs) :
        string_(CYCopyJSString(rhs.string_))
    {
    }

    template <typename Arg0_>
    CYJSString(Arg0_ arg0) :
        string_(CYCopyJSString(arg0))
    {
    }

    template <typename Arg0_, typename Arg1_>
    CYJSString(Arg0_ arg0, Arg1_ arg1) :
        string_(CYCopyJSString(arg0, arg1))
    {
    }

    CYJSString &operator =(const CYJSString &rhs) {
        Clear_();
        string_ = CYCopyJSString(rhs.string_);
        return *this;
    }

    ~CYJSString() {
        Clear_();
    }

    void Clear() {
        Clear_();
        string_ = NULL;
    }

    operator JSStringRef() const {
        return string_;
    }
};

CFStringRef CYCopyCFString(JSStringRef value) {
    return JSStringCopyCFString(kCFAllocatorDefault, value);
}

CFStringRef CYCopyCFString(JSContextRef context, JSValueRef value) {
    return CYCopyCFString(CYJSString(context, value));
}

double CYCastDouble(const char *value, size_t size) {
    char *end;
    double number(strtod(value, &end));
    if (end != value + size)
        return NAN;
    return number;
}

double CYCastDouble(const char *value) {
    return CYCastDouble(value, strlen(value));
}

double CYCastDouble(JSContextRef context, JSValueRef value) {
    JSValueRef exception(NULL);
    double number(JSValueToNumber(context, value, &exception));
    CYThrow(context, exception);
    return number;
}

CFNumberRef CYCopyCFNumber(JSContextRef context, JSValueRef value) {
    double number(CYCastDouble(context, value));
    return CFNumberCreate(kCFAllocatorDefault, kCFNumberDoubleType, &number);
}

CFStringRef CYCopyCFString(const char *value) {
    return CFStringCreateWithCString(kCFAllocatorDefault, value, kCFStringEncodingUTF8);
}

NSString *CYCastNSString(apr_pool_t *pool, const char *value) {
    return (NSString *) CYPoolRelease(pool, CYCopyCFString(value));
}

NSString *CYCastNSString(apr_pool_t *pool, JSStringRef value) {
    return (NSString *) CYPoolRelease(pool, CYCopyCFString(value));
}

bool CYCastBool(JSContextRef context, JSValueRef value) {
    return JSValueToBoolean(context, value);
}

CFTypeRef CYCFType(apr_pool_t *pool, JSContextRef context, JSValueRef value, bool cast) {
    CFTypeRef object;
    bool copy;

    switch (JSType type = JSValueGetType(context, value)) {
        case kJSTypeUndefined:
            object = [WebUndefined undefined];
            copy = false;
        break;

        case kJSTypeNull:
            return NULL;
        break;

        case kJSTypeBoolean:
            object = CYCastBool(context, value) ? kCFBooleanTrue : kCFBooleanFalse;
            copy = false;
        break;

        case kJSTypeNumber:
            object = CYCopyCFNumber(context, value);
            copy = true;
        break;

        case kJSTypeString:
            object = CYCopyCFString(context, value);
            copy = true;
        break;

        case kJSTypeObject:
            // XXX: this might could be more efficient
            object = (CFTypeRef) CYCastNSObject(pool, context, (JSObjectRef) value);
            copy = false;
        break;

        default:
            @throw [NSException exceptionWithName:NSInternalInconsistencyException reason:[NSString stringWithFormat:@"JSValueGetType() == 0x%x", type] userInfo:nil];
        break;
    }

    if (cast != copy)
        return object;
    else if (copy)
        return CYPoolRelease(pool, object);
    else
        return CFRetain(object);
}

CFTypeRef CYCastCFType(apr_pool_t *pool, JSContextRef context, JSValueRef value) {
    return CYCFType(pool, context, value, true);
}

CFTypeRef CYCopyCFType(apr_pool_t *pool, JSContextRef context, JSValueRef value) {
    return CYCFType(pool, context, value, false);
}

NSArray *CYCastNSArray(JSPropertyNameArrayRef names) {
    CYPool pool;
    size_t size(JSPropertyNameArrayGetCount(names));
    NSMutableArray *array([NSMutableArray arrayWithCapacity:size]);
    for (size_t index(0); index != size; ++index)
        [array addObject:CYCastNSString(pool, JSPropertyNameArrayGetNameAtIndex(names, index))];
    return array;
}

id CYCastNSObject(apr_pool_t *pool, JSContextRef context, JSValueRef value) {
    return reinterpret_cast<const NSObject *>(CYCastCFType(pool, context, value));
}

void CYThrow(JSContextRef context, JSValueRef value) {
    if (value == NULL)
        return;
    @throw CYCastNSObject(NULL, context, value);
}

JSValueRef CYJSNull(JSContextRef context) {
    return JSValueMakeNull(context);
}

JSValueRef CYCastJSValue(JSContextRef context, JSStringRef value) {
    return value == NULL ? CYJSNull(context) : JSValueMakeString(context, value);
}

JSValueRef CYCastJSValue(JSContextRef context, const char *value) {
    return CYCastJSValue(context, CYJSString(value));
}

JSValueRef CYCastJSValue(JSContextRef context, id value, bool transient = true) {
    return value == nil ? CYJSNull(context) : [value cy$JSValueInContext:context transient:transient];
}

JSObjectRef CYCastJSObject(JSContextRef context, JSValueRef value) {
    JSValueRef exception(NULL);
    JSObjectRef object(JSValueToObject(context, value, &exception));
    CYThrow(context, exception);
    return object;
}

JSValueRef CYGetProperty(JSContextRef context, JSObjectRef object, size_t index) {
    JSValueRef exception(NULL);
    JSValueRef value(JSObjectGetPropertyAtIndex(context, object, index, &exception));
    CYThrow(context, exception);
    return value;
}

JSValueRef CYGetProperty(JSContextRef context, JSObjectRef object, JSStringRef name) {
    JSValueRef exception(NULL);
    JSValueRef value(JSObjectGetProperty(context, object, name, &exception));
    CYThrow(context, exception);
    return value;
}

void CYSetProperty(JSContextRef context, JSObjectRef object, JSStringRef name, JSValueRef value) {
    JSValueRef exception(NULL);
    JSObjectSetProperty(context, object, name, value, kJSPropertyAttributeNone, &exception);
    CYThrow(context, exception);
}

void CYThrow(JSContextRef context, id error, JSValueRef *exception) {
    if (exception == NULL)
        throw error;
    *exception = CYCastJSValue(context, error);
}

@implementation CYJSObject

- (id) initWithJSObject:(JSObjectRef)object inContext:(JSContextRef)context {
    if ((self = [super init]) != nil) {
        object_ = object;
        context_ = context;
    } return self;
}

- (NSUInteger) count {
    JSPropertyNameArrayRef names(JSObjectCopyPropertyNames(context_, object_));
    size_t size(JSPropertyNameArrayGetCount(names));
    JSPropertyNameArrayRelease(names);
    return size;
}

- (id) objectForKey:(id)key {
    return CYCastNSObject(NULL, context_, CYGetProperty(context_, object_, CYJSString(key))) ?: [NSNull null];
}

- (NSEnumerator *) keyEnumerator {
    JSPropertyNameArrayRef names(JSObjectCopyPropertyNames(context_, object_));
    NSEnumerator *enumerator([CYCastNSArray(names) objectEnumerator]);
    JSPropertyNameArrayRelease(names);
    return enumerator;
}

- (void) setObject:(id)object forKey:(id)key {
    CYSetProperty(context_, object_, CYJSString(key), CYCastJSValue(context_, object));
}

- (void) removeObjectForKey:(id)key {
    JSValueRef exception(NULL);
    // XXX: this returns a bool... throw exception, or ignore?
    JSObjectDeleteProperty(context_, object_, CYJSString(key), &exception);
    CYThrow(context_, exception);
}

@end

@implementation CYJSArray

- (id) initWithJSObject:(JSObjectRef)object inContext:(JSContextRef)context {
    if ((self = [super init]) != nil) {
        object_ = object;
        context_ = context;
    } return self;
}

- (NSUInteger) count {
    return CYCastDouble(context_, CYGetProperty(context_, object_, length_));
}

- (id) objectAtIndex:(NSUInteger)index {
    JSValueRef exception(NULL);
    JSValueRef value(JSObjectGetPropertyAtIndex(context_, object_, index, &exception));
    CYThrow(context_, exception);
    return CYCastNSObject(NULL, context_, value) ?: [NSNull null];
}

@end

CFStringRef CYCopyJSONString(JSContextRef context, JSValueRef value, JSValueRef *exception) {
    CYTry {
        CYPoolTry {
            id object(CYCastNSObject(NULL, context, value));
            return reinterpret_cast<CFStringRef>([(object == nil ? @"null" : [object cy$toJSON]) retain]);
        } CYPoolCatch(NULL)
    } CYCatch
}

const char *CYPoolJSONString(apr_pool_t *pool, JSContextRef context, JSValueRef value, JSValueRef *exception) {
    if (NSString *json = (NSString *) CYCopyJSONString(context, value, exception)) {
        const char *string(CYPoolCString(pool, json));
        [json release];
        return string;
    } else return NULL;
}

static void OnData(CFSocketRef socket, CFSocketCallBackType type, CFDataRef address, const void *value, void *info) {
    switch (type) {
        case kCFSocketDataCallBack:
            CFDataRef data(reinterpret_cast<CFDataRef>(value));
            Client *client(reinterpret_cast<Client *>(info));

            if (client->message_ == NULL)
                client->message_ = CFHTTPMessageCreateEmpty(kCFAllocatorDefault, TRUE);

            if (!CFHTTPMessageAppendBytes(client->message_, CFDataGetBytePtr(data), CFDataGetLength(data)))
                CFLog(kCFLogLevelError, CFSTR("CFHTTPMessageAppendBytes()"));
            else if (CFHTTPMessageIsHeaderComplete(client->message_)) {
                CFURLRef url(CFHTTPMessageCopyRequestURL(client->message_));
                Boolean absolute;
                CFStringRef path(CFURLCopyStrictPath(url, &absolute));
                CFRelease(client->message_);

                CFStringRef code(CFURLCreateStringByReplacingPercentEscapes(kCFAllocatorDefault, path, CFSTR("")));
                CFRelease(path);

                JSStringRef script(JSStringCreateWithCFString(code));
                CFRelease(code);

                JSValueRef result(JSEvaluateScript(CYGetJSContext(), script, NULL, NULL, 0, NULL));
                JSStringRelease(script);

                CFHTTPMessageRef response(CFHTTPMessageCreateResponse(kCFAllocatorDefault, 200, NULL, kCFHTTPVersion1_1));
                CFHTTPMessageSetHeaderFieldValue(response, CFSTR("Content-Type"), CFSTR("application/json; charset=utf-8"));

                CFStringRef json(CYCopyJSONString(CYGetJSContext(), result, NULL));
                CFDataRef body(CFStringCreateExternalRepresentation(kCFAllocatorDefault, json, kCFStringEncodingUTF8, NULL));
                CFRelease(json);

                CFStringRef length(CFStringCreateWithFormat(kCFAllocatorDefault, NULL, CFSTR("%u"), CFDataGetLength(body)));
                CFHTTPMessageSetHeaderFieldValue(response, CFSTR("Content-Length"), length);
                CFRelease(length);

                CFHTTPMessageSetBody(response, body);
                CFRelease(body);

                CFDataRef serialized(CFHTTPMessageCopySerializedMessage(response));
                CFRelease(response);

                CFSocketSendData(socket, NULL, serialized, 0);
                CFRelease(serialized);

                CFRelease(url);
            }
        break;
    }
}

static void OnAccept(CFSocketRef socket, CFSocketCallBackType type, CFDataRef address, const void *value, void *info) {
    switch (type) {
        case kCFSocketAcceptCallBack:
            Client *client(new Client());

            client->message_ = NULL;

            CFSocketContext context;
            context.version = 0;
            context.info = client;
            context.retain = NULL;
            context.release = NULL;
            context.copyDescription = NULL;

            client->socket_ = CFSocketCreateWithNative(kCFAllocatorDefault, *reinterpret_cast<const CFSocketNativeHandle *>(value), kCFSocketDataCallBack, &OnData, &context);

            CFRunLoopAddSource(CFRunLoopGetCurrent(), CFSocketCreateRunLoopSource(kCFAllocatorDefault, client->socket_, 0), kCFRunLoopDefaultMode);
        break;
    }
}

static JSValueRef Instance_getProperty(JSContextRef context, JSObjectRef object, JSStringRef property, JSValueRef *exception) {
    CYTry {
        CYPool pool;
        NSString *self(CYCastNSObject(pool, context, object));
        NSString *name(CYCastNSString(pool, property));
        NSObject *data([self cy$getProperty:name]);
        return data == nil ? NULL : CYCastJSValue(context, data);
    } CYCatch
}

static bool Instance_setProperty(JSContextRef context, JSObjectRef object, JSStringRef property, JSValueRef value, JSValueRef *exception) {
    CYTry {
        CYPool pool;
        NSString *self(CYCastNSObject(pool, context, object));
        NSString *name(CYCastNSString(pool, property));
        NSString *data(CYCastNSObject(pool, context, value));
        return [self cy$setProperty:name to:data];
    } CYCatch
}

static bool Instance_deleteProperty(JSContextRef context, JSObjectRef object, JSStringRef property, JSValueRef *exception) {
    CYTry {
        CYPool pool;
        NSString *self(CYCastNSObject(pool, context, object));
        NSString *name(CYCastNSString(pool, property));
        return [self cy$deleteProperty:name];
    } CYCatch
}

static JSObjectRef Instance_callAsConstructor(JSContextRef context, JSObjectRef object, size_t count, const JSValueRef arguments[], JSValueRef *exception) {
    CYTry {
        Instance_privateData *data(reinterpret_cast<Instance_privateData *>(JSObjectGetPrivate(object)));
        return CYMakeInstance(context, [data->GetValue() alloc], true);
    } CYCatch
}

JSObjectRef CYMakeSelector(JSContextRef context, SEL sel) {
    Selector_privateData *data(new Selector_privateData(sel));
    return JSObjectMake(context, Selector_, data);
}

JSObjectRef CYMakePointer(JSContextRef context, void *pointer) {
    Pointer_privateData *data(new Pointer_privateData(pointer));
    return JSObjectMake(context, Pointer_, data);
}

JSObjectRef CYMakeFunctor(JSContextRef context, void (*function)(), const char *type) {
    Functor_privateData *data(new Functor_privateData(type, function));
    return JSObjectMake(context, Functor_, data);
}

const char *CYPoolCString(apr_pool_t *pool, JSStringRef value, size_t *length = NULL) {
    if (pool == NULL) {
        const char *string([CYCastNSString(NULL, value) UTF8String]);
        if (length != NULL)
            *length = strlen(string);
        return string;
    } else {
        size_t size(JSStringGetMaximumUTF8CStringSize(value));
        char *string(new(pool) char[size]);
        JSStringGetUTF8CString(value, string, size);
        // XXX: this is ironic
        if (length != NULL)
            *length = strlen(string);
        return string;
    }
}

const char *CYPoolCString(apr_pool_t *pool, JSContextRef context, JSValueRef value, size_t *length = NULL) {
    if (!JSValueIsNull(context, value))
        return CYPoolCString(pool, CYJSString(context, value), length);
    else {
        if (length != NULL)
            *length = 0;
        return NULL;
    }
}

// XXX: this macro is unhygenic
#define CYCastCString(context, value) ({ \
    char *utf8; \
    if (value == NULL) \
        utf8 = NULL; \
    else if (JSStringRef string = CYCopyJSString(context, value)) { \
        size_t size(JSStringGetMaximumUTF8CStringSize(string)); \
        utf8 = reinterpret_cast<char *>(alloca(size)); \
        JSStringGetUTF8CString(string, utf8, size); \
        JSStringRelease(string); \
    } else \
        utf8 = NULL; \
    utf8; \
})

SEL CYCastSEL(JSContextRef context, JSValueRef value) {
    if (JSValueIsNull(context, value))
        return NULL;
    else if (JSValueIsObjectOfClass(context, value, Selector_)) {
        Selector_privateData *data(reinterpret_cast<Selector_privateData *>(JSObjectGetPrivate((JSObjectRef) value)));
        return reinterpret_cast<SEL>(data->value_);
    } else
        return sel_registerName(CYCastCString(context, value));
}

void *CYCastPointer_(JSContextRef context, JSValueRef value) {
    switch (JSValueGetType(context, value)) {
        case kJSTypeNull:
            return NULL;
        /*case kJSTypeString:
            return dlsym(RTLD_DEFAULT, CYCastCString(context, value));
        case kJSTypeObject:
            if (JSValueIsObjectOfClass(context, value, Pointer_)) {
                Pointer_privateData *data(reinterpret_cast<Pointer_privateData *>(JSObjectGetPrivate((JSObjectRef) value)));
                return data->value_;
            }*/
        default:
            double number(CYCastDouble(context, value));
            if (std::isnan(number))
                @throw [NSException exceptionWithName:NSInvalidArgumentException reason:@"cannot convert value to pointer" userInfo:nil];
            return reinterpret_cast<void *>(static_cast<uintptr_t>(static_cast<long long>(number)));
    }
}

template <typename Type_>
_finline Type_ CYCastPointer(JSContextRef context, JSValueRef value) {
    return reinterpret_cast<Type_>(CYCastPointer_(context, value));
}

void CYPoolFFI(apr_pool_t *pool, JSContextRef context, sig::Type *type, ffi_type *ffi, void *data, JSValueRef value) {
    switch (type->primitive) {
        case sig::boolean_P:
            *reinterpret_cast<bool *>(data) = JSValueToBoolean(context, value);
        break;

#define CYPoolFFI_(primitive, native) \
        case sig::primitive ## _P: \
            *reinterpret_cast<native *>(data) = CYCastDouble(context, value); \
        break;

        CYPoolFFI_(uchar, unsigned char)
        CYPoolFFI_(char, char)
        CYPoolFFI_(ushort, unsigned short)
        CYPoolFFI_(short, short)
        CYPoolFFI_(ulong, unsigned long)
        CYPoolFFI_(long, long)
        CYPoolFFI_(uint, unsigned int)
        CYPoolFFI_(int, int)
        CYPoolFFI_(ulonglong, unsigned long long)
        CYPoolFFI_(longlong, long long)
        CYPoolFFI_(float, float)
        CYPoolFFI_(double, double)

        case sig::object_P:
        case sig::typename_P:
            *reinterpret_cast<id *>(data) = CYCastNSObject(pool, context, value);
        break;

        case sig::selector_P:
            *reinterpret_cast<SEL *>(data) = CYCastSEL(context, value);
        break;

        case sig::pointer_P:
            *reinterpret_cast<void **>(data) = CYCastPointer<void *>(context, value);
        break;

        case sig::string_P:
            *reinterpret_cast<const char **>(data) = CYPoolCString(pool, context, value);
        break;

        case sig::struct_P: {
            uint8_t *base(reinterpret_cast<uint8_t *>(data));
            bool aggregate(JSValueIsObject(context, value));
            for (size_t index(0); index != type->data.signature.count; ++index) {
                ffi_type *element(ffi->elements[index]);
                JSValueRef rhs(aggregate ? CYGetProperty(context, (JSObjectRef) value, index) : value);
                CYPoolFFI(pool, context, type->data.signature.elements[index].type, element, base, rhs);
                // XXX: alignment?
                base += element->size;
            }
        } break;

        case sig::void_P:
        break;

        default:
            NSLog(@"CYPoolFFI(%c)\n", type->primitive);
            _assert(false);
    }
}

JSValueRef CYFromFFI(JSContextRef context, sig::Type *type, ffi_type *ffi, void *data, JSObjectRef owner = NULL) {
    JSValueRef value;

    switch (type->primitive) {
        case sig::boolean_P:
            value = CYCastJSValue(context, *reinterpret_cast<bool *>(data));
        break;

#define CYFromFFI_(primitive, native) \
        case sig::primitive ## _P: \
            value = CYCastJSValue(context, *reinterpret_cast<native *>(data)); \
        break;

        CYFromFFI_(uchar, unsigned char)
        CYFromFFI_(char, char)
        CYFromFFI_(ushort, unsigned short)
        CYFromFFI_(short, short)
        CYFromFFI_(ulong, unsigned long)
        CYFromFFI_(long, long)
        CYFromFFI_(uint, unsigned int)
        CYFromFFI_(int, int)
        CYFromFFI_(ulonglong, unsigned long long)
        CYFromFFI_(longlong, long long)
        CYFromFFI_(float, float)
        CYFromFFI_(double, double)

        case sig::object_P:
            value = CYCastJSValue(context, *reinterpret_cast<id *>(data));
        break;

        case sig::typename_P:
            value = CYMakeInstance(context, *reinterpret_cast<Class *>(data), true);
        break;

        case sig::selector_P:
            if (SEL sel = *reinterpret_cast<SEL *>(data))
                value = CYMakeSelector(context, sel);
            else goto null;
        break;

        case sig::pointer_P:
            if (void *pointer = *reinterpret_cast<void **>(data))
                value = CYMakePointer(context, pointer);
            else goto null;
        break;

        case sig::string_P:
            if (char *utf8 = *reinterpret_cast<char **>(data))
                value = CYCastJSValue(context, utf8);
            else goto null;
        break;

        case sig::struct_P:
            value = CYMakeStruct(context, data, type, ffi, owner);
        break;

        case sig::void_P:
            value = CYJSUndefined(context);
        break;

        null:
            value = CYJSNull(context);
        break;

        default:
            NSLog(@"CYFromFFI(%c)\n", type->primitive);
            _assert(false);
    }

    return value;
}

void Index_(Struct_privateData *internal, double number, ssize_t &index, uint8_t *&base) {
    Type_privateData *typical(internal->type_);

    index = static_cast<ssize_t>(number);
    if (index != number)
        @throw [NSException exceptionWithName:NSInvalidArgumentException reason:@"struct index non-integral" userInfo:nil];
    if (index < 0)
        @throw [NSException exceptionWithName:NSInvalidArgumentException reason:@"struct index negative" userInfo:nil];

    base = reinterpret_cast<uint8_t *>(internal->value_);
    for (ssize_t local(0); local != index; ++local)
        if (ffi_type *element = typical->ffi_.elements[local])
            base += element->size;
        else
            @throw [NSException exceptionWithName:NSInvalidArgumentException reason:@"struct index out-of-range" userInfo:nil];
}

static JSValueRef Struct_getProperty(JSContextRef context, JSObjectRef object, JSStringRef property, JSValueRef *exception) {
    CYTry {
        CYPool pool;
        Struct_privateData *internal(reinterpret_cast<Struct_privateData *>(JSObjectGetPrivate(object)));
        Type_privateData *typical(internal->type_);

        size_t length;
        const char *name(CYPoolCString(pool, property, &length));
        double number(CYCastDouble(name, length));

        if (std::isnan(number)) {
            // XXX: implement!
            return NULL;
        }

        ssize_t index;
        uint8_t *base;

        Index_(internal, number, index, base);

        return CYFromFFI(context, typical->type_.data.signature.elements[index].type, typical->ffi_.elements[index], base, object);
    } CYCatch
}

static bool Struct_setProperty(JSContextRef context, JSObjectRef object, JSStringRef property, JSValueRef value, JSValueRef *exception) {
    CYTry {
        CYPool pool;
        Struct_privateData *internal(reinterpret_cast<Struct_privateData *>(JSObjectGetPrivate(object)));
        Type_privateData *typical(internal->type_);

        size_t length;
        const char *name(CYPoolCString(pool, property, &length));
        double number(CYCastDouble(name, length));

        if (std::isnan(number)) {
            // XXX: implement!
            return false;
        }

        ssize_t index;
        uint8_t *base;

        Index_(internal, number, index, base);

        CYPoolFFI(NULL, context, typical->type_.data.signature.elements[index].type, typical->ffi_.elements[index], base, value);
        return true;
    } CYCatch
}

static JSValueRef CYCallFunction(JSContextRef context, size_t count, const JSValueRef *arguments, JSValueRef *exception, sig::Signature *signature, ffi_cif *cif, void (*function)()) {
    CYTry {
        if (count != signature->count - 1)
            @throw [NSException exceptionWithName:NSInvalidArgumentException reason:@"incorrect number of arguments to ffi function" userInfo:nil];

        CYPool pool;
        void *values[count];

        for (unsigned index(0); index != count; ++index) {
            sig::Element *element(&signature->elements[index + 1]);
            ffi_type *ffi(cif->arg_types[index]);
            // XXX: alignment?
            values[index] = new(pool) uint8_t[ffi->size];
            CYPoolFFI(pool, context, element->type, ffi, values[index], arguments[index]);
        }

        uint8_t value[cif->rtype->size];
        ffi_call(cif, function, value, values);

        return CYFromFFI(context, signature->elements[0].type, cif->rtype, value);
    } CYCatch
}

void Closure_(ffi_cif *cif, void *result, void **arguments, void *arg) {
    ffoData *data(reinterpret_cast<ffoData *>(arg));

    JSContextRef context(data->context_);

    size_t count(data->cif_.nargs);
    JSValueRef values[count];

    for (size_t index(0); index != count; ++index)
        values[index] = CYFromFFI(context, data->signature_.elements[1 + index].type, data->cif_.arg_types[index], arguments[index]);

    JSValueRef exception(NULL);
    JSValueRef value(JSObjectCallAsFunction(context, data->function_, NULL, count, values, &exception));
    CYThrow(context, exception);

    CYPoolFFI(NULL, context, data->signature_.elements[0].type, data->cif_.rtype, result, value);
}

JSObjectRef CYMakeFunctor(JSContextRef context, JSObjectRef function, const char *type) {
    // XXX: in case of exceptions this will leak
    ffoData *data(new ffoData(type));

    ffi_closure *closure;
    _syscall(closure = (ffi_closure *) mmap(
        NULL, sizeof(ffi_closure),
        PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE,
        -1, 0
    ));

    ffi_status status(ffi_prep_closure(closure, &data->cif_, &Closure_, data));
    _assert(status == FFI_OK);

    _syscall(mprotect(closure, sizeof(*closure), PROT_READ | PROT_EXEC));

    data->value_ = closure;

    data->context_ = CYGetJSContext();
    data->function_ = function;

    return JSObjectMake(context, Functor_, data);
}

static JSValueRef Runtime_getProperty(JSContextRef context, JSObjectRef object, JSStringRef property, JSValueRef *exception) {
    CYTry {
        CYPool pool;
        NSString *name(CYCastNSString(pool, property));
        if (Class _class = NSClassFromString(name))
            return CYMakeInstance(context, _class, true);
        if (NSMutableArray *entry = [[Bridge_ objectAtIndex:0] objectForKey:name])
            switch ([[entry objectAtIndex:0] intValue]) {
                case 0:
                    return JSEvaluateScript(CYGetJSContext(), CYJSString([entry objectAtIndex:1]), NULL, NULL, 0, NULL);
                case 1:
                    return CYMakeFunctor(context, reinterpret_cast<void (*)()>([name cy$symbol]), CYPoolCString(pool, [entry objectAtIndex:1]));
                case 2:
                    // XXX: this is horrendously inefficient
                    sig::Signature signature;
                    sig::Parse(pool, &signature, CYPoolCString(pool, [entry objectAtIndex:1]));
                    ffi_cif cif;
                    sig::sig_ffi_cif(pool, &sig::ObjectiveC, &signature, &cif);
                    return CYFromFFI(context, signature.elements[0].type, cif.rtype, [name cy$symbol]);
            }
        return NULL;
    } CYCatch
}

bool stret(ffi_type *ffi_type) {
    return ffi_type->type == FFI_TYPE_STRUCT && (
        ffi_type->size > OBJC_MAX_STRUCT_BY_VALUE ||
        struct_forward_array[ffi_type->size] != 0
    );
}

extern "C" {
    int *_NSGetArgc(void);
    char ***_NSGetArgv(void);
    int UIApplicationMain(int argc, char *argv[], NSString *principalClassName, NSString *delegateClassName);
}

static JSValueRef System_print(JSContextRef context, JSObjectRef object, JSObjectRef _this, size_t count, const JSValueRef arguments[], JSValueRef *exception) {
    CYTry {
        NSLog(@"%s", CYCastCString(context, arguments[0]));
        return CYJSUndefined(context);
    } CYCatch
}

static JSValueRef CYApplicationMain(JSContextRef context, JSObjectRef object, JSObjectRef _this, size_t count, const JSValueRef arguments[], JSValueRef *exception) {
    CYTry {
        CYPool pool;
        NSString *name(CYCastNSObject(pool, context, arguments[0]));
        int argc(*_NSGetArgc());
        char **argv(*_NSGetArgv());
        for (int i(0); i != argc; ++i)
            NSLog(@"argv[%i]=%s", i, argv[i]);
        _pooled
        return CYCastJSValue(context, UIApplicationMain(argc, argv, name, name));
    } CYCatch
}

static JSValueRef $objc_msgSend(JSContextRef context, JSObjectRef object, JSObjectRef _this, size_t count, const JSValueRef arguments[], JSValueRef *exception) {
    const char *type;

    CYPool pool;

    CYTry {
        if (count < 2)
            @throw [NSException exceptionWithName:NSInvalidArgumentException reason:@"too few arguments to objc_msgSend" userInfo:nil];

        id self(CYCastNSObject(pool, context, arguments[0]));
        if (self == nil)
            return CYJSNull(context);

        SEL _cmd(CYCastSEL(context, arguments[1]));

        Class _class(object_getClass(self));
        if (Method method = class_getInstanceMethod(_class, _cmd))
            type = method_getTypeEncoding(method);
        else {
            CYPoolTry {
                NSMethodSignature *method([self methodSignatureForSelector:_cmd]);
                if (method == nil)
                    @throw [NSException exceptionWithName:NSInvalidArgumentException reason:[NSString stringWithFormat:@"unrecognized selector %s sent to object %p", sel_getName(_cmd), self] userInfo:nil];
                type = CYPoolCString(pool, [method _typeString]);
            } CYPoolCatch(NULL)
        }
    } CYCatch

    sig::Signature signature;
    sig::Parse(pool, &signature, type);

    ffi_cif cif;
    sig::sig_ffi_cif(pool, &sig::ObjectiveC, &signature, &cif);

    void (*function)() = stret(cif.rtype) ? reinterpret_cast<void (*)()>(&objc_msgSend_stret) : reinterpret_cast<void (*)()>(&objc_msgSend);
    return CYCallFunction(context, count, arguments, exception, &signature, &cif, function);
}

static JSValueRef Selector_callAsFunction(JSContextRef context, JSObjectRef object, JSObjectRef _this, size_t count, const JSValueRef arguments[], JSValueRef *exception) {
    JSValueRef setup[count + 2];
    setup[0] = _this;
    setup[1] = object;
    memmove(setup + 2, arguments, sizeof(JSValueRef) * count);
    return $objc_msgSend(context, NULL, NULL, count + 2, setup, exception);
}

static JSValueRef Functor_callAsFunction(JSContextRef context, JSObjectRef object, JSObjectRef _this, size_t count, const JSValueRef arguments[], JSValueRef *exception) {
    Functor_privateData *data(reinterpret_cast<Functor_privateData *>(JSObjectGetPrivate(object)));
    return CYCallFunction(context, count, arguments, exception, &data->signature_, &data->cif_, reinterpret_cast<void (*)()>(data->value_));
}

JSObjectRef Selector_new(JSContextRef context, JSObjectRef object, size_t count, const JSValueRef arguments[], JSValueRef *exception) {
    CYTry {
        if (count != 1)
            @throw [NSException exceptionWithName:NSInvalidArgumentException reason:@"incorrect number of arguments to Selector constructor" userInfo:nil];
        const char *name(CYCastCString(context, arguments[0]));
        return CYMakeSelector(context, sel_registerName(name));
    } CYCatch
}

JSObjectRef Functor_new(JSContextRef context, JSObjectRef object, size_t count, const JSValueRef arguments[], JSValueRef *exception) {
    CYTry {
        if (count != 2)
            @throw [NSException exceptionWithName:NSInvalidArgumentException reason:@"incorrect number of arguments to Functor constructor" userInfo:nil];
        const char *type(CYCastCString(context, arguments[1]));
        JSValueRef exception(NULL);
        if (JSValueIsInstanceOfConstructor(context, arguments[0], Function_, &exception)) {
            JSObjectRef function(CYCastJSObject(context, arguments[0]));
            return CYMakeFunctor(context, function, type);
        } else if (exception != NULL) {
            return NULL;
        } else {
            void (*function)()(CYCastPointer<void (*)()>(context, arguments[0]));
            return CYMakeFunctor(context, function, type);
        }
    } CYCatch
}

JSValueRef Pointer_getProperty_value(JSContextRef context, JSObjectRef object, JSStringRef property, JSValueRef *exception) {
    Pointer_privateData *data(reinterpret_cast<Pointer_privateData *>(JSObjectGetPrivate(object)));
    return CYCastJSValue(context, reinterpret_cast<uintptr_t>(data->value_));
}

JSValueRef Selector_getProperty_prototype(JSContextRef context, JSObjectRef object, JSStringRef property, JSValueRef *exception) {
    return Function_;
}

static JSValueRef Pointer_callAsFunction_valueOf(JSContextRef context, JSObjectRef object, JSObjectRef _this, size_t count, const JSValueRef arguments[], JSValueRef *exception) {
    CYTry {
        Pointer_privateData *data(reinterpret_cast<Pointer_privateData *>(JSObjectGetPrivate(_this)));
        return CYCastJSValue(context, reinterpret_cast<uintptr_t>(data->value_));
    } CYCatch
}

static JSValueRef Instance_callAsFunction_toString(JSContextRef context, JSObjectRef object, JSObjectRef _this, size_t count, const JSValueRef arguments[], JSValueRef *exception) {
    CYTry {
        Instance_privateData *data(reinterpret_cast<Instance_privateData *>(JSObjectGetPrivate(_this)));
        CYPoolTry {
            return CYCastJSValue(context, CYJSString([data->GetValue() description]));
        } CYPoolCatch(NULL)
    } CYCatch
}

static JSValueRef Selector_callAsFunction_toString(JSContextRef context, JSObjectRef object, JSObjectRef _this, size_t count, const JSValueRef arguments[], JSValueRef *exception) {
    CYTry {
        Selector_privateData *data(reinterpret_cast<Selector_privateData *>(JSObjectGetPrivate(_this)));
        return CYCastJSValue(context, sel_getName(data->GetValue()));
    } CYCatch
}

static JSValueRef Selector_callAsFunction_type(JSContextRef context, JSObjectRef object, JSObjectRef _this, size_t count, const JSValueRef arguments[], JSValueRef *exception) {
    CYTry {
        if (count != 2)
            @throw [NSException exceptionWithName:NSInvalidArgumentException reason:@"incorrect number of arguments to Selector.type" userInfo:nil];
        CYPool pool;
        Selector_privateData *data(reinterpret_cast<Selector_privateData *>(JSObjectGetPrivate(_this)));
        Class _class(CYCastNSObject(pool, context, arguments[0]));
        bool instance(CYCastBool(context, arguments[1]));
        SEL sel(data->GetValue());
        if (Method method = (*(instance ? &class_getInstanceMethod : class_getClassMethod))(_class, sel))
            return CYCastJSValue(context, method_getTypeEncoding(method));
        else if (NSString *type = [[Bridge_ objectAtIndex:1] objectForKey:CYCastNSString(pool, sel_getName(sel))])
            return CYCastJSValue(context, CYJSString(type));
        else
            return CYJSNull(context);
    } CYCatch
}

static JSStaticValue Pointer_staticValues[2] = {
    {"value", &Pointer_getProperty_value, NULL, kJSPropertyAttributeReadOnly | kJSPropertyAttributeDontDelete},
    {NULL, NULL, NULL, 0}
};

static JSStaticFunction Pointer_staticFunctions[2] = {
    {"valueOf", &Pointer_callAsFunction_valueOf, kJSPropertyAttributeDontEnum | kJSPropertyAttributeDontDelete},
    {NULL, NULL, 0}
};

/*static JSStaticValue Selector_staticValues[2] = {
    {"prototype", &Selector_getProperty_prototype, NULL, kJSPropertyAttributeReadOnly | kJSPropertyAttributeDontDelete},
    {NULL, NULL, NULL, 0}
};*/

static JSStaticFunction Instance_staticFunctions[2] = {
    {"toString", &Instance_callAsFunction_toString, kJSPropertyAttributeDontEnum | kJSPropertyAttributeDontDelete},
    {NULL, NULL, 0}
};

static JSStaticFunction Selector_staticFunctions[3] = {
    {"toString", &Selector_callAsFunction_toString, kJSPropertyAttributeDontEnum | kJSPropertyAttributeDontDelete},
    {"type", &Selector_callAsFunction_type, kJSPropertyAttributeDontEnum | kJSPropertyAttributeDontDelete},
    {NULL, NULL, 0}
};

CYDriver::CYDriver(const std::string &filename) :
    state_(CYClear),
    data_(NULL),
    size_(0),
    filename_(filename),
    source_(NULL)
{
    ScannerInit();
}

CYDriver::~CYDriver() {
    ScannerDestroy();
}

void cy::parser::error(const cy::parser::location_type &location, const std::string &message) {
    CYDriver::Error error;
    error.location_ = location;
    error.message_ = message;
    driver.errors_.push_back(error);
}

void CYSetArgs(int argc, const char *argv[]) {
    JSContextRef context(CYGetJSContext());
    JSValueRef args[argc];
    for (int i(0); i != argc; ++i)
        args[i] = CYCastJSValue(context, argv[i]);
    JSValueRef exception(NULL);
    JSObjectRef array(JSObjectMakeArray(context, argc, args, &exception));
    CYThrow(context, exception);
    CYSetProperty(context, System_, CYJSString("args"), array);
}

JSObjectRef CYGetGlobalObject(JSContextRef context) {
    return JSContextGetGlobalObject(context);
}

MSInitialize { _pooled
    apr_initialize();

    Bridge_ = [[NSMutableArray arrayWithContentsOfFile:@"/usr/lib/libcycript.plist"] retain];

    NSCFBoolean_ = objc_getClass("NSCFBoolean");

    pid_t pid(getpid());

    struct sockaddr_in address;
    address.sin_len = sizeof(address);
    address.sin_family = AF_INET;
    address.sin_addr.s_addr = INADDR_ANY;
    address.sin_port = htons(10000 + pid);

    CFDataRef data(CFDataCreate(kCFAllocatorDefault, reinterpret_cast<UInt8 *>(&address), sizeof(address)));

    CFSocketSignature signature;
    signature.protocolFamily = AF_INET;
    signature.socketType = SOCK_STREAM;
    signature.protocol = IPPROTO_TCP;
    signature.address = data;

    CFSocketRef socket(CFSocketCreateWithSocketSignature(kCFAllocatorDefault, &signature, kCFSocketAcceptCallBack, &OnAccept, NULL));
    CFRunLoopAddSource(CFRunLoopGetCurrent(), CFSocketCreateRunLoopSource(kCFAllocatorDefault, socket, 0), kCFRunLoopDefaultMode);

    JSClassDefinition definition;

    definition = kJSClassDefinitionEmpty;
    definition.className = "Pointer";
    definition.staticValues = Pointer_staticValues;
    definition.staticFunctions = Pointer_staticFunctions;
    definition.finalize = &CYData::Finalize;
    Pointer_ = JSClassCreate(&definition);

    definition = kJSClassDefinitionEmpty;
    definition.className = "Functor";
    definition.staticValues = Pointer_staticValues;
    definition.staticFunctions = Pointer_staticFunctions;
    definition.callAsFunction = &Functor_callAsFunction;
    definition.finalize = &CYData::Finalize;
    Functor_ = JSClassCreate(&definition);

    definition = kJSClassDefinitionEmpty;
    definition.className = "Struct";
    definition.getProperty = &Struct_getProperty;
    definition.setProperty = &Struct_setProperty;
    definition.finalize = &CYData::Finalize;
    Struct_ = JSClassCreate(&definition);

    definition = kJSClassDefinitionEmpty;
    definition.className = "Selector";
    definition.staticValues = Pointer_staticValues;
    //definition.staticValues = Selector_staticValues;
    definition.staticFunctions = Selector_staticFunctions;
    definition.callAsFunction = &Selector_callAsFunction;
    definition.finalize = &CYData::Finalize;
    Selector_ = JSClassCreate(&definition);

    definition = kJSClassDefinitionEmpty;
    definition.className = "Instance";
    definition.staticValues = Pointer_staticValues;
    definition.staticFunctions = Instance_staticFunctions;
    definition.getProperty = &Instance_getProperty;
    definition.setProperty = &Instance_setProperty;
    definition.deleteProperty = &Instance_deleteProperty;
    definition.callAsConstructor = &Instance_callAsConstructor;
    definition.finalize = &CYData::Finalize;
    Instance_ = JSClassCreate(&definition);

    definition = kJSClassDefinitionEmpty;
    definition.className = "Runtime";
    definition.getProperty = &Runtime_getProperty;
    Runtime_ = JSClassCreate(&definition);

    definition = kJSClassDefinitionEmpty;
    //definition.getProperty = &Global_getProperty;
    JSClassRef Global(JSClassCreate(&definition));

    JSGlobalContextRef context(JSGlobalContextCreate(Global));
    Context_ = context;

    JSObjectRef global(CYGetGlobalObject(context));

    JSObjectSetPrototype(context, global, JSObjectMake(context, Runtime_, NULL));
    CYSetProperty(context, global, CYJSString("ObjectiveC"), JSObjectMake(context, Runtime_, NULL));

    CYSetProperty(context, global, CYJSString("Selector"), JSObjectMakeConstructor(context, Selector_, &Selector_new));
    CYSetProperty(context, global, CYJSString("Functor"), JSObjectMakeConstructor(context, Functor_, &Functor_new));

    CYSetProperty(context, global, CYJSString("CYApplicationMain"), JSObjectMakeFunctionWithCallback(context, CYJSString("CYApplicationMain"), &CYApplicationMain));
    CYSetProperty(context, global, CYJSString("objc_msgSend"), JSObjectMakeFunctionWithCallback(context, CYJSString("objc_msgSend"), &$objc_msgSend));

    System_ = JSObjectMake(context, NULL, NULL);
    CYSetProperty(context, global, CYJSString("system"), System_);
    CYSetProperty(context, System_, CYJSString("args"), CYJSNull(context));
    //CYSetProperty(context, System_, CYJSString("global"), global);

    CYSetProperty(context, System_, CYJSString("print"), JSObjectMakeFunctionWithCallback(context, CYJSString("print"), &System_print));

    name_ = JSStringCreateWithUTF8CString("name");
    message_ = JSStringCreateWithUTF8CString("message");
    length_ = JSStringCreateWithUTF8CString("length");

    Array_ = CYCastJSObject(context, CYGetProperty(context, global, CYJSString("Array")));
    Function_ = CYCastJSObject(context, CYGetProperty(context, global, CYJSString("Function")));
}
