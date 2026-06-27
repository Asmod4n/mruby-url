/*
** src/compat/threads.h — C11 <threads.h> shim for Apple platforms.
**
** Apple's libc/clang ship no C11 <threads.h>, so mrb_url.c's
**   #include <threads.h>
** fails to compile on macOS. This file provides the exact subset of the C11
** threads interface that mruby-url uses, mapped 1:1 onto POSIX pthreads (which
** macOS always has).
**
** It is placed on the include path ONLY for Apple targets (see mrbgem.rake), so
** Linux and the MinGW Windows build keep using the platform's real <threads.h>.
** The names, types and signatures below match C11 exactly, so mrb_url.c needs
** no changes.
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

#endif /* MRB_URL_COMPAT_THREADS_H */
