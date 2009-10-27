/* Cycript - Error.hppution Server and Disassembler
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

#ifndef CYPOOLING_HPP
#define CYPOOLING_HPP

#include <apr_pools.h>
#include <apr_strings.h>

#include "Exception.hpp"
#include "Standard.hpp"

_finline void *operator new(size_t size, apr_pool_t *pool) {
    return apr_palloc(pool, size);
}

_finline void *operator new [](size_t size, apr_pool_t *pool) {
    return apr_palloc(pool, size);
}

class CYPool {
  private:
    apr_pool_t *pool_;

  public:
    CYPool() {
        _aprcall(apr_pool_create(&pool_, NULL));
    }

    ~CYPool() {
        apr_pool_destroy(pool_);
    }

    void Clear() {
        apr_pool_clear(pool_);
    }

    operator apr_pool_t *() const {
        return pool_;
    }

    char *operator ()(const char *data) const {
        return apr_pstrdup(pool_, data);
    }

    char *operator ()(const char *data, size_t size) const {
        return apr_pstrndup(pool_, data, size);
    }
};

struct CYData {
    apr_pool_t *pool_;

    virtual ~CYData() {
    }

    static void *operator new(size_t size, apr_pool_t *pool) {
        void *data(apr_palloc(pool, size));
        reinterpret_cast<CYData *>(data)->pool_ = pool;
        return data;
    }

    static void *operator new(size_t size) {
        apr_pool_t *pool;
        _aprcall(apr_pool_create(&pool, NULL));
        return operator new(size, pool);
    }

    static void operator delete(void *data) {
        apr_pool_destroy(reinterpret_cast<CYData *>(data)->pool_);
    }

};

#endif/*CYPOOLING_HPP*/
