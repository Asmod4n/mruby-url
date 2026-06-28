/*
** src/compat/threads.h — pthreads-backed C11 <threads.h> shim.
**
** Some toolchains ship no C11 <threads.h> (most notably Apple's libc/clang, and
** C99-only toolchains), so mrb_url.c's
**   #include <threads.h>
** fails to compile there. This file provides the exact subset of the C11
** threads interface that mruby-url uses, mapped 1:1 onto POSIX pthreads.
**
** mrbgem.rake puts it on the include path only when the compiler's real header
** search has no <threads.h> (detected via spec.cc.search_header), so toolchains
** that do ship one keep using it. It is POSIX (pthreads), hence the non-Windows
** build branch. The names, types and signatures below match C11 exactly, so
** mrb_url.c needs no changes.
*/
#ifndef MRB_URL_COMPAT_THREADS_H
#define MRB_URL_COMPAT_THREADS_H

#include <pthread.h>

/* --- one-time initialization: once_flag / call_once --- */
typedef pthread_once_t once_flag;
#define ONCE_FLAG_INIT PTHREAD_ONCE_INIT

static inline void
call_once(once_flag *flag, void (*func)(void))
{
  pthread_once(flag, func);
}

/* --- mutexes: mtx_t / mtx_init / mtx_lock / mtx_unlock / mtx_destroy --- */
enum {
  mtx_plain     = 0,
  mtx_recursive = 1,
  mtx_timed     = 2
};

enum {
  thrd_success = 0,
  thrd_error   = 1,
  thrd_busy    = 2,
  thrd_nomem   = 3,
  thrd_timedout = 4
};

typedef pthread_mutex_t mtx_t;

static inline int
mtx_init(mtx_t *mtx, int type)
{
  (void)type; /* only mtx_plain is used here */
  return pthread_mutex_init(mtx, NULL) == 0 ? thrd_success : thrd_error;
}

static inline int
mtx_lock(mtx_t *mtx)
{
  return pthread_mutex_lock(mtx) == 0 ? thrd_success : thrd_error;
}

static inline int
mtx_unlock(mtx_t *mtx)
{
  return pthread_mutex_unlock(mtx) == 0 ? thrd_success : thrd_error;
}

static inline void
mtx_destroy(mtx_t *mtx)
{
  pthread_mutex_destroy(mtx);
}

/* --- thread-specific storage: tss_t / tss_create / tss_get / tss_set ---
 * Maps C11 thread-local storage onto a POSIX thread-specific key. The key's
 * destructor (tss_dtor_t) runs at thread exit for every thread that set a
 * non-NULL value — which is exactly how curl_url's per-thread CURLSH is torn
 * down. pthread runs the destructor up to PTHREAD_DESTRUCTOR_ITERATIONS times
 * while the slot keeps being re-set; we only ever set it once per thread, so a
 * single pass suffices. tss_delete is unused by mrb_url.c and omitted. */
typedef pthread_key_t tss_t;
typedef void (*tss_dtor_t)(void *);

static inline int
tss_create(tss_t *key, tss_dtor_t dtor)
{
  return pthread_key_create(key, dtor) == 0 ? thrd_success : thrd_error;
}

static inline void *
tss_get(tss_t key)
{
  return pthread_getspecific(key);
}

static inline int
tss_set(tss_t key, void *val)
{
  return pthread_setspecific(key, val) == 0 ? thrd_success : thrd_error;
}

#endif /* MRB_URL_COMPAT_THREADS_H */
