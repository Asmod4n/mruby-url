/*
** mrb_url.c - libcurl FFI primitives for mruby-url
**
** This file is an FFI-thin binding only (see CLAUDE.md). Every C-defined
** method lives in the flat URL::Libcurl namespace and is a single libcurl
** call plus primitive marshalling. There is no dispatch, no option-mapping
** policy, no control flow, no per-transfer state and no parsing here: all of
** that lives in Ruby (mrblib/). The only irreducible C glue is the handful of
** libcurl callbacks, kept minimal:
**
**   - write / header / read callbacks on an Easy: thin trampolines that read a
**     block off the Easy's ivars (@on_data/@on_header/@on_read), copy bytes,
**     and invoke Ruby under mrb_protect_error.
**   - socket / timer callbacks on a Multi: thin trampolines too — they read a
**     block off the Multi's ivars (@on_socket / @on_timer) and invoke Ruby under
**     mrb_protect_error, returning -1 (CURLM_ABORTED_BY_CALLBACK) on a raise so
**     nothing longjmps through libcurl.
**
** CDATA handle types:
**   URL::Libcurl::Easy   wraps CURL*   (GC -> curl_easy_cleanup)
**   URL::Libcurl::Multi  wraps CURLM*  (GC -> curl_multi_cleanup)
*/

#include <mruby.h>
#include <mruby/data.h>
#include <mruby/string.h>
#include <mruby/array.h>
#include <mruby/hash.h>
#include <mruby/variable.h>
#include <mruby/class.h>
#include <mruby/error.h>
#include <mruby/presym.h>
#include <mruby/numeric.h>
#include <mruby/num_helpers.h>
#include <mruby/branch_pred.h>

#include <curl/curl.h>
/* After curl: on Windows curl pulls in winsock2.h, which defines struct timeval
 * and _WINSOCK2API_. mruby/chrono.h only defines its own fallback timeval when
 * winsock hasn't been included yet, so including it here avoids a C2011
 * 'timeval' redefinition under MSVC. */
#include <mruby/chrono.h>
#include <stddef.h>
#include <stdlib.h>
#include <string.h>
#include <threads.h>

/* libcurl grew the WebSocket framing API (curl_ws_send / curl_ws_recv) and the
 * CURLWS_* flags in 7.86.0. When the embedded libcurl is older the two
 * primitives below compile to a single NotImplementedError stub and the flag
 * constants publish as 0, so loading the gem never fails — only an actual ws://
 * call does, with a clear message. */
#if defined(LIBCURL_VERSION_NUM) && LIBCURL_VERSION_NUM >= 0x075600
#  define MURL_HAVE_WEBSOCKETS 1
#  define MURL_WS_FLAG(name) CURLWS_##name
#else
#  define MURL_WS_FLAG(name) 0
#endif

/* =========================================================================
 * URL::Libcurl::Easy  (CDATA = murl_easy_t, wraps CURL*)
 *
 * The CDATA object is the Easy itself; its ivars (@on_data / @on_header /
 * @on_read) carry the user blocks the callbacks invoke. WRITEDATA / READDATA /
 * PRIVATE all point at this struct so the callbacks can recover (mrb, self).
 * ========================================================================= */

typedef struct murl_easy_t {
  mrb_state*         mrb;
  mrb_value          self;
  CURL*              curl;
  struct curl_slist* req_headers;
  struct curl_slist* mail_rcpt;
  struct curl_slist* quote;
} murl_easy_t;

static void
murl_easy_free(mrb_state* mrb, void* p)
{
  if (unlikely(!p)) return;
  murl_easy_t* e = (murl_easy_t*)p;
  if (e->curl)        curl_easy_cleanup(e->curl);
  if (e->req_headers) curl_slist_free_all(e->req_headers);
  if (e->mail_rcpt)   curl_slist_free_all(e->mail_rcpt);
  if (e->quote)       curl_slist_free_all(e->quote);
  mrb_free(mrb, e);
}

static const struct mrb_data_type murl_easy_type = {
  "URL::Libcurl::Easy", murl_easy_free
};

static murl_easy_t*
murl_easy_get(mrb_state* mrb, mrb_value self)
{
  murl_easy_t* e = (murl_easy_t*)mrb_data_check_get_ptr(mrb, self, &murl_easy_type);
  if (unlikely(!e || !e->curl)) mrb_raise(mrb, E_RUNTIME_ERROR, "URL::Libcurl::Easy not open");
  return e;
}

/* =========================================================================
 * URL::Libcurl::Mime / ::Part  (multipart/form-data via curl_mime_*)
 *
 * The mime tree is opaque libcurl state, so it has to be built through C calls
 * — but each is a thin pass-through; which parts / names / files to add is
 * decided in Ruby.
 *
 * The Mime CDATA owns curl_mime_free (which also frees its parts, so a Part
 * CDATA is non-owning). Lifetime is rooted from C, invisibly to Ruby: mime_new
 * stashes the Mime on its easy under a HIDDEN ivar — a symbol with no leading
 * '@' (MRB_SYM, not MRB_IVSYM). The GC still traces it (so the mime can't be
 * freed while the easy posts it via the bare CURLOPT_MIMEPOST pointer), but
 * instance_variable_get/set/remove all require a '@', so Ruby code can neither
 * read, replace, nor delete it — no way to induce a use-after-free from Ruby.
 * ========================================================================= */

static void
murl_mime_free(mrb_state* mrb, void* p)
{
  (void)mrb;
  if (p) curl_mime_free((curl_mime*)p);
}

static const struct mrb_data_type murl_mime_type = {
  "URL::Libcurl::Mime", murl_mime_free
};

static const struct mrb_data_type murl_part_type = {
  "URL::Libcurl::Part", NULL   /* freed by its owning curl_mime, never alone */
};

static curl_mime*
murl_mime_get(mrb_state* mrb, mrb_value v)
{
  curl_mime* m = (curl_mime*)mrb_data_check_get_ptr(mrb, v, &murl_mime_type);
  if (unlikely(!m)) mrb_raise(mrb, E_RUNTIME_ERROR, "URL::Libcurl::Mime not open");
  return m;
}

static curl_mimepart*
murl_part_get(mrb_state* mrb, mrb_value v)
{
  curl_mimepart* p = (curl_mimepart*)mrb_data_check_get_ptr(mrb, v, &murl_part_type);
  if (unlikely(!p)) mrb_raise(mrb, E_RUNTIME_ERROR, "URL::Libcurl::Part not open");
  return p;
}

/* mime_new(easy) -> Mime */
static mrb_value
murl_lc_mime_new(mrb_state* mrb, mrb_value mod)
{
  mrb_value easy_obj;
  mrb_get_args(mrb, "o", &easy_obj);
  murl_easy_t* e = murl_easy_get(mrb, easy_obj);

  curl_mime* m = curl_mime_init(e->curl);
  if (unlikely(!m)) mrb_raise(mrb, E_RUNTIME_ERROR, "curl_mime_init failed");

  struct RClass* lc  = mrb_class_ptr(mod);
  struct RClass* cls = mrb_class_get_under_id(mrb, lc, MRB_SYM(Mime));
  struct RData*  d   = mrb_data_object_alloc(mrb, cls, m, &murl_mime_type);
  mrb_value self = mrb_obj_value(d);
  /* Root the mime on its easy under a HIDDEN ivar (no leading '@'): GC-traced,
   * so it outlives the transfer libcurl posts it on, but invisible and
   * immutable from Ruby — instance_variable_* can't touch a non-'@' name. One
   * slot per easy; a second mime_new replaces it and the old mime is freed. */
  mrb_iv_set(mrb, easy_obj, MRB_SYM(mime), self);
  return self;
}

/* mime_addpart(mime) -> Part */
static mrb_value
murl_lc_mime_addpart(mrb_state* mrb, mrb_value mod)
{
  mrb_value mime_obj;
  mrb_get_args(mrb, "o", &mime_obj);
  curl_mime* m = murl_mime_get(mrb, mime_obj);

  curl_mimepart* p = curl_mime_addpart(m);
  if (unlikely(!p)) mrb_raise(mrb, E_RUNTIME_ERROR, "curl_mime_addpart failed");

  struct RClass* lc  = mrb_class_ptr(mod);
  struct RClass* cls = mrb_class_get_under_id(mrb, lc, MRB_SYM(Part));
  struct RData*  d   = mrb_data_object_alloc(mrb, cls, p, &murl_part_type);
  mrb_value self = mrb_obj_value(d);
  mrb_iv_set(mrb, self, MRB_SYM(mime), mime_obj);   /* root the owning mime */
  return self;
}

static void
murl_mime_check(mrb_state* mrb, CURLcode rc, const char* what)
{
  if (unlikely(rc != CURLE_OK))
    mrb_raisef(mrb, E_RUNTIME_ERROR, "%s: %s", what, curl_easy_strerror(rc));
}

/* mime_name(part, str) -> part */
static mrb_value
murl_lc_mime_name(mrb_state* mrb, mrb_value mod)
{
  (void)mod;
  mrb_value part_obj, name;
  mrb_get_args(mrb, "oS", &part_obj, &name);
  murl_mime_check(mrb, curl_mime_name(murl_part_get(mrb, part_obj),
                                      mrb_string_cstr(mrb, name)), "curl_mime_name");
  return part_obj;
}

/* mime_data(part, bytes) -> part  (curl copies the bytes; binary-safe) */
static mrb_value
murl_lc_mime_data(mrb_state* mrb, mrb_value mod)
{
  (void)mod;
  mrb_value part_obj, data;
  mrb_get_args(mrb, "oS", &part_obj, &data);
  murl_mime_check(mrb, curl_mime_data(murl_part_get(mrb, part_obj),
                                      RSTRING_PTR(data), (size_t)RSTRING_LEN(data)),
                  "curl_mime_data");
  return part_obj;
}

/* mime_filedata(part, path) -> part  (libcurl streams the file from disk) */
static mrb_value
murl_lc_mime_filedata(mrb_state* mrb, mrb_value mod)
{
  (void)mod;
  mrb_value part_obj, path;
  mrb_get_args(mrb, "oS", &part_obj, &path);
  murl_mime_check(mrb, curl_mime_filedata(murl_part_get(mrb, part_obj),
                                          mrb_string_cstr(mrb, path)), "curl_mime_filedata");
  return part_obj;
}

/* mime_type(part, str) -> part */
static mrb_value
murl_lc_mime_type(mrb_state* mrb, mrb_value mod)
{
  (void)mod;
  mrb_value part_obj, type;
  mrb_get_args(mrb, "oS", &part_obj, &type);
  murl_mime_check(mrb, curl_mime_type(murl_part_get(mrb, part_obj),
                                      mrb_string_cstr(mrb, type)), "curl_mime_type");
  return part_obj;
}

/* mime_filename(part, str) -> part */
static mrb_value
murl_lc_mime_filename(mrb_state* mrb, mrb_value mod)
{
  (void)mod;
  mrb_value part_obj, name;
  mrb_get_args(mrb, "oS", &part_obj, &name);
  murl_mime_check(mrb, curl_mime_filename(murl_part_get(mrb, part_obj),
                                          mrb_string_cstr(mrb, name)), "curl_mime_filename");
  return part_obj;
}

/* =========================================================================
 * URL::Libcurl::Multi  (CDATA = murl_multi_t, wraps CURLM*)
 *
 * murl_socket_cb / murl_timer_cb are thin trampolines to Ruby blocks stored on
 * the Multi (@on_socket / @on_timer), invoked under mrb_protect_error so a raise
 * becomes a -1 return (CURLM_ABORTED_BY_CALLBACK) instead of a longjmp through
 * libcurl.
 * ========================================================================= */

typedef struct murl_multi_t {
  mrb_state* mrb;
  mrb_value  self;
  CURLM*     multi;
} murl_multi_t;

static void
murl_multi_free(mrb_state* mrb, void* p)
{
  if (unlikely(!p)) return;
  murl_multi_t* m = (murl_multi_t*)p;
  if (m->multi) curl_multi_cleanup(m->multi);
  mrb_free(mrb, m);
}

static const struct mrb_data_type murl_multi_type = {
  "URL::Libcurl::Multi", murl_multi_free
};

static murl_multi_t*
murl_multi_get(mrb_state* mrb, mrb_value self)
{
  murl_multi_t* m = (murl_multi_t*)mrb_data_check_get_ptr(mrb, self, &murl_multi_type);
  if (unlikely(!m || !m->multi)) mrb_raise(mrb, E_RUNTIME_ERROR, "URL::Libcurl::Multi not open");
  return m;
}

/* =========================================================================
 * URL::Libcurl::Share (CDATA = murl_share_t, wraps CURLSH*)
 *
 * One per VM, created in gem_init and published as URL::Libcurl::SHARE. Every
 * Easy from murl_lc_easy_init attaches via CURLOPT_SHARE, so every session in
 * this VM uses the same connection cache and TLS session-ticket cache. A
 * request fired from inside a callback (which runs on a throwaway session
 * because the shared multi is busy) reuses the live TCP connection / TLS
 * session-ticket from the shared session instead of doing a full handshake.
 *
 * Single-threaded mruby: no lock callbacks are set. curl_share.c uses
 * `if(share->lockfunc)` and skips the call when unset — unset is the cheap
 * documented no-op. No-op stubs would add an indirect call per cache hit.
 *
 * LOCK_DATA enabled:
 *   CONNECT     — TCP keep-alive + HTTP/2/3 connection cache reuse
 *   SSL_SESSION — TLS session-ticket cache (resumption)
 * Skipped: DNS/PSL (auto-shared at multi level), COOKIE/HSTS (libcurl docs say
 * "not supported to share across threads", and we set them per-easy anyway).
 * ========================================================================= */

typedef struct murl_share_t {
  mrb_state* mrb;
  CURLSH*    share;
} murl_share_t;

static void
murl_share_free(mrb_state* mrb, void* p)
{
  if (unlikely(!p)) return;
  murl_share_t* s = (murl_share_t*)p;
  /* When this GC sweep runs, gem_final's three-pass cleanup
   * (disarm -> cleanup_curl -> cleanup_share) has already nulled s->share, so
   * the guard below makes this a no-op. The guard also covers the unusual
   * order — direct GC sweep without gem_final — and the path where the share
   * was never opened (curl_share_init returned NULL in gem_init): in both
   * cases curl_share_cleanup would otherwise be called on NULL. If somehow an
   * easy still references the share, curl_share_cleanup returns
   * CURLSHE_IN_USE (does not crash) and the share is left intact. */
  if (s->share) curl_share_cleanup(s->share);
  mrb_free(mrb, s);
}

static const struct mrb_data_type murl_share_type = {
  "URL::Libcurl::Share", murl_share_free
};

/* Per-VM share lookup. Returns NULL if missing/torn-down so easy_init proceeds
 * without CURLOPT_SHARE rather than failing. */
static CURLSH*
murl_share_lookup(mrb_state* mrb, struct RClass* lc)
{
  mrb_sym sym = MRB_SYM(SHARE);
  if (!mrb_const_defined_at(mrb, mrb_obj_value(lc), sym)) return NULL;
  mrb_value v = mrb_const_get(mrb, mrb_obj_value(lc), sym);
  murl_share_t* s = (murl_share_t*)mrb_data_check_get_ptr(mrb, v, &murl_share_type);
  return (s && s->share) ? s->share : NULL;
}

/* =========================================================================
 * Error checks (single libcurl strerror call on failure)
 * ========================================================================= */

static void
murl_easy_check(mrb_state* mrb, CURLcode rc)
{
  if (unlikely(mrb->exc != NULL)) mrb_exc_raise(mrb, mrb_obj_value(mrb->exc));
  if (likely(rc == CURLE_OK)) return;
  mrb_raisef(mrb, E_RUNTIME_ERROR, "curl_easy error: %s", curl_easy_strerror(rc));
}

static void
murl_multi_check(mrb_state* mrb, CURLMcode rc)
{
  if (unlikely(mrb->exc != NULL)) mrb_exc_raise(mrb, mrb_obj_value(mrb->exc));
  if (likely(rc == CURLM_OK)) return;
  mrb_raisef(mrb, E_RUNTIME_ERROR, "curl_multi error: %s", curl_multi_strerror(rc));
}

/* =========================================================================
 * write / header callbacks: copy bytes IN to a String, yield the block.
 * ========================================================================= */

typedef struct cb_str_args {
  mrb_value   cb;
  const char* ptr;
  size_t      len;
} cb_str_args;

static mrb_value
call_with_str_body(mrb_state* mrb, void* data)
{
  cb_str_args* a = (cb_str_args*)data;
  mrb_value s = mrb_str_new(mrb, a->ptr, a->len);
  return mrb_yield(mrb, a->cb, s);
}

static size_t
murl_dispatch_str_cb(murl_easy_t* e, mrb_sym ivsym, const char* ptr, size_t total)
{
  mrb_state* mrb = e->mrb;
  mrb_value  cb  = mrb_iv_get(mrb, e->self, ivsym);
  if (!mrb_proc_p(cb)) return total;

  int ai = mrb_gc_arena_save(mrb);
  cb_str_args a = { cb, ptr, total };
  mrb_bool err = FALSE;
  mrb_value ret = mrb_protect_error(mrb, call_with_str_body, &a, &err);
  mrb_gc_arena_restore(mrb, ai);

  if (unlikely(err)) {
    if (mrb->exc == NULL) {
      mrb->exc = mrb_obj_ptr(ret);
    }
    return 0;
  }
  return total;
}

static size_t
murl_write_cb(char* ptr, size_t size, size_t nmemb, void* userdata)
{
  murl_easy_t* e = (murl_easy_t*)userdata;
  size_t total = size * nmemb;
  if (unlikely(total == 0)) return 0;
  return murl_dispatch_str_cb(e, MRB_IVSYM(on_data), ptr, total);
}

static size_t
murl_header_cb(char* ptr, size_t size, size_t nmemb, void* userdata)
{
  murl_easy_t* e = (murl_easy_t*)userdata;
  size_t total = size * nmemb;
  if (unlikely(total == 0)) return 0;
  return murl_dispatch_str_cb(e, MRB_IVSYM(on_header), ptr, total);
}

/* read callback: ask the @on_read block for up to `max` bytes, copy the
 * returned String OUT with n = min(len, max). On a stashed exception return
 * CURL_READFUNC_ABORT. */
typedef struct cb_read_args {
  mrb_value cb;
  size_t    max;
} cb_read_args;

static mrb_value
call_read_body(mrb_state* mrb, void* data)
{
  cb_read_args* a = (cb_read_args*)data;
  return mrb_yield(mrb, a->cb, mrb_convert_size_t(mrb, a->max));
}

static size_t
murl_read_cb(char* buffer, size_t size, size_t nitems, void* userdata)
{
  murl_easy_t* e = (murl_easy_t*)userdata;
  mrb_state* mrb = e->mrb;
  size_t max = size * nitems;
  if (unlikely(max == 0)) return 0;

  mrb_value cb = mrb_iv_get(mrb, e->self, MRB_IVSYM(on_read));
  if (!mrb_proc_p(cb)) return 0;  /* nothing to send */

  int ai = mrb_gc_arena_save(mrb);
  cb_read_args a = { cb, max };
  mrb_bool err = FALSE;
  mrb_value ret = mrb_protect_error(mrb, call_read_body, &a, &err);

  if (unlikely(err)) {
    mrb_gc_arena_restore(mrb, ai);
    if (mrb->exc == NULL) {
      mrb->exc = mrb_obj_ptr(ret);
    }
    return CURL_READFUNC_ABORT;
  }

  size_t n = 0;
  if (mrb_string_p(ret)) {
    size_t len = (size_t)RSTRING_LEN(ret);
    n = len < max ? len : max;          /* clamp the copy */
    if (n) memcpy(buffer, RSTRING_PTR(ret), n);
  }
  mrb_gc_arena_restore(mrb, ai);
  return n;
}

/* =========================================================================
 * socket / timer callbacks (run inside curl_multi_socket_action): thin
 * trampolines to the Multi's @on_socket / @on_timer Ruby blocks, invoked under
 * mrb_protect_error. A raise is stashed and turned into a -1 return
 * (CURLM_ABORTED_BY_CALLBACK), so nothing longjmps through libcurl.
 * ========================================================================= */

typedef struct cb_socket_args {
  mrb_value     cb;
  curl_socket_t fd;
  mrb_sym       what;
} cb_socket_args;

static mrb_value
call_socket_body(mrb_state* mrb, void* data)
{
  cb_socket_args* a = (cb_socket_args*)data;
  mrb_value argv[2] = { mrb_int_value(mrb, a->fd), mrb_symbol_value(a->what) };
  return mrb_yield_argv(mrb, a->cb, 2, argv);
}

static int
murl_socket_cb(CURL* easy, curl_socket_t fd, int what, void* userp, void* socketp)
{
  (void)easy;
  (void)socketp;
  murl_multi_t* m   = (murl_multi_t*)userp;
  mrb_state*    mrb = m->mrb;
  mrb_value     cb  = mrb_iv_get(mrb, m->self, MRB_IVSYM(on_socket));
  if (!mrb_proc_p(cb)) return 0;

  mrb_sym wsym;
  switch (what) {
  case CURL_POLL_IN:     wsym = MRB_SYM(in);     break;
  case CURL_POLL_OUT:    wsym = MRB_SYM(out);    break;
  case CURL_POLL_INOUT:  wsym = MRB_SYM(inout);  break;
  case CURL_POLL_REMOVE: wsym = MRB_SYM(remove); break;
  default: return 0;
  }

  int ai = mrb_gc_arena_save(mrb);
  cb_socket_args a = { cb, fd, wsym };
  mrb_bool err = FALSE;
  mrb_value ret = mrb_protect_error(mrb, call_socket_body, &a, &err);
  mrb_gc_arena_restore(mrb, ai);

  if (unlikely(err)) {
    if (mrb->exc == NULL) {
      mrb->exc = mrb_obj_ptr(ret);
    }
    return -1;
  }
  return 0;
}

typedef struct cb_timer_args {
  mrb_value cb;
  long      ms;
} cb_timer_args;

static mrb_value
call_timer_body(mrb_state* mrb, void* data)
{
  cb_timer_args* a = (cb_timer_args*)data;
  return mrb_yield(mrb, a->cb, mrb_convert_long(mrb, a->ms));
}

static int
murl_timer_cb(CURLM* multi, long timeout_ms, void* userp)
{
  (void)multi;
  murl_multi_t* m   = (murl_multi_t*)userp;
  mrb_state*    mrb = m->mrb;
  mrb_value     cb  = mrb_iv_get(mrb, m->self, MRB_IVSYM(on_timer));
  if (!mrb_proc_p(cb)) return 0;

  int ai = mrb_gc_arena_save(mrb);
  cb_timer_args a = { cb, timeout_ms };
  mrb_bool err = FALSE;
  mrb_value ret = mrb_protect_error(mrb, call_timer_body, &a, &err);
  mrb_gc_arena_restore(mrb, ai);

  if (unlikely(err)) {
    if (mrb->exc == NULL) {
      mrb->exc = mrb_obj_ptr(ret);
    }
    return -1;
  }
  return 0;
}

/* =========================================================================
 * easy_init -> Easy
 * ========================================================================= */

static mrb_value
murl_lc_easy_init(mrb_state* mrb, mrb_value mod)
{
  struct RClass* lc  = mrb_class_ptr(mod);
  struct RClass* cls = mrb_class_get_under_id(mrb, lc, MRB_SYM(Easy));

  murl_easy_t* e;
  struct RData* d;
  Data_Make_Struct(mrb, cls, murl_easy_t, &murl_easy_type, e, d);
  mrb_value self    = mrb_obj_value(d);
  e->mrb            = mrb;
  e->self           = self;
  e->curl           = NULL;
  e->req_headers    = NULL;
  e->mail_rcpt      = NULL;
  e->quote          = NULL;

  CURL* h = curl_easy_init();
  if (unlikely(!h)) mrb_raise(mrb, E_RUNTIME_ERROR, "curl_easy_init failed");
  e->curl = h;

  curl_easy_setopt(h, CURLOPT_PRIVATE,        e);
  curl_easy_setopt(h, CURLOPT_WRITEFUNCTION,  murl_write_cb);
  curl_easy_setopt(h, CURLOPT_WRITEDATA,      e);
  curl_easy_setopt(h, CURLOPT_HEADERFUNCTION, murl_header_cb);
  curl_easy_setopt(h, CURLOPT_HEADERDATA,     e);
  curl_easy_setopt(h, CURLOPT_READFUNCTION,   murl_read_cb);
  curl_easy_setopt(h, CURLOPT_READDATA,       e);
  curl_easy_setopt(h, CURLOPT_NOSIGNAL,       1L);

  /* Attach to the per-VM share so this easy uses the shared connection cache
   * and TLS session-ticket cache. Detach is automatic on curl_easy_cleanup. */
  CURLSH* sh = murl_share_lookup(mrb, lc);
  if (sh) curl_easy_setopt(h, CURLOPT_SHARE, sh);

  return self;
}

/* =========================================================================
 * easy_setopt(easy, sym, val) -> easy   (flat sym -> CURLOPT_* pass-through)
 * ========================================================================= */

static mrb_value
murl_lc_easy_setopt(mrb_state* mrb, mrb_value mod)
{
  (void)mod;
  mrb_value easy_obj, val;
  mrb_sym   opt;
  mrb_get_args(mrb, "ono", &easy_obj, &opt, &val);

  murl_easy_t* e = murl_easy_get(mrb, easy_obj);
  CURL* h = e->curl;

  CURLcode rc = CURLE_OK;

  if      (opt == MRB_SYM(url))                rc = curl_easy_setopt(h, CURLOPT_URL, mrb_string_cstr(mrb, val));
  else if (opt == MRB_SYM(custom_request))     rc = curl_easy_setopt(h, CURLOPT_CUSTOMREQUEST, mrb_string_cstr(mrb, val));
  else if (opt == MRB_SYM(user_agent))         rc = curl_easy_setopt(h, CURLOPT_USERAGENT, mrb_string_cstr(mrb, val));
  else if (opt == MRB_SYM(cainfo))             rc = curl_easy_setopt(h, CURLOPT_CAINFO, mrb_string_cstr(mrb, val));
  else if (opt == MRB_SYM(accept_encoding))    rc = curl_easy_setopt(h, CURLOPT_ACCEPT_ENCODING, mrb_string_cstr(mrb, val));
  else if (opt == MRB_SYM(userpwd))            rc = curl_easy_setopt(h, CURLOPT_USERPWD, mrb_string_cstr(mrb, val));
  else if (opt == MRB_SYM(proxy))              rc = curl_easy_setopt(h, CURLOPT_PROXY, mrb_string_cstr(mrb, val));
  else if (opt == MRB_SYM(cookiefile))         rc = curl_easy_setopt(h, CURLOPT_COOKIEFILE, mrb_string_cstr(mrb, val));
  else if (opt == MRB_SYM(cookiejar))          rc = curl_easy_setopt(h, CURLOPT_COOKIEJAR, mrb_string_cstr(mrb, val));
  else if (opt == MRB_SYM(follow_location))    rc = curl_easy_setopt(h, CURLOPT_FOLLOWLOCATION, (long)mrb_bool(val));
  else if (opt == MRB_SYM(verbose))            rc = curl_easy_setopt(h, CURLOPT_VERBOSE, (long)mrb_bool(val));
  else if (opt == MRB_SYM(connect_only))       rc = curl_easy_setopt(h, CURLOPT_CONNECT_ONLY, (long)mrb_as_int(mrb, val));
  else if (opt == MRB_SYM(timeout) || opt == MRB_SYM(connect_timeout)) {
    /* The one timeout API: val is a duration (Float seconds, as produced by
     * mruby-chrono's 30.s / 500.ms / 2.min). libcurl's finest timeout
     * granularity is the millisecond, so convert to long ms and use the _MS
     * options — no precision lost versus the whole-second CURLOPT_TIMEOUT.
     * mruby-chrono does the unit math, the type check (TypeError if val isn't
     * numeric) and the range check; NEAREST absorbs Float representation noise
     * so 0.1s lands on exactly 100ms, not 101. Marshalling a primitive across
     * the boundary with the dedicated converter — no policy in C. */
    long ms;
    mrb_chrono_convert(mrb, val, MRB_CHRONO_OUT_LONG, MRB_CHRONO_DUR_MILLISECONDS,
                       MRB_CHRONO_NEAREST, &ms, sizeof ms);
    rc = curl_easy_setopt(h, opt == MRB_SYM(timeout) ? CURLOPT_TIMEOUT_MS
                                                     : CURLOPT_CONNECTTIMEOUT_MS, ms);
  }
  else if (opt == MRB_SYM(ssl_verify_peer))    rc = curl_easy_setopt(h, CURLOPT_SSL_VERIFYPEER, (long)mrb_bool(val));
  else if (opt == MRB_SYM(ssl_verify_host))    rc = curl_easy_setopt(h, CURLOPT_SSL_VERIFYHOST, mrb_bool(val) ? 2L : 0L);
  else if (opt == MRB_SYM(max_redirs))         rc = curl_easy_setopt(h, CURLOPT_MAXREDIRS, (long)mrb_as_int(mrb, val));
  else if (opt == MRB_SYM(nobody))             rc = curl_easy_setopt(h, CURLOPT_NOBODY, (long)mrb_bool(val));
  else if (opt == MRB_SYM(upload))             rc = curl_easy_setopt(h, CURLOPT_UPLOAD, (long)mrb_bool(val));
  else if (opt == MRB_SYM(mail_from))          rc = curl_easy_setopt(h, CURLOPT_MAIL_FROM, mrb_string_cstr(mrb, val));
  else if (opt == MRB_SYM(netrc))              rc = curl_easy_setopt(h, CURLOPT_NETRC, (long)mrb_as_int(mrb, val));
  else if (opt == MRB_SYM(netrc_file))         rc = curl_easy_setopt(h, CURLOPT_NETRC_FILE, mrb_string_cstr(mrb, val));
  else if (opt == MRB_SYM(dirlistonly))        rc = curl_easy_setopt(h, CURLOPT_DIRLISTONLY, (long)mrb_bool(val));
  else if (opt == MRB_SYM(ftp_create_dirs))    rc = curl_easy_setopt(h, CURLOPT_FTP_CREATE_MISSING_DIRS, (long)mrb_bool(val));
  else if (opt == MRB_SYM(range))              rc = curl_easy_setopt(h, CURLOPT_RANGE, mrb_string_cstr(mrb, val));
  else if (opt == MRB_SYM(infilesize))         rc = curl_easy_setopt(h, CURLOPT_INFILESIZE_LARGE, (curl_off_t)mrb_as_int(mrb, val));
  else if (opt == MRB_SYM(ssh_knownhosts))     rc = curl_easy_setopt(h, CURLOPT_SSH_KNOWNHOSTS, mrb_string_cstr(mrb, val));
  else if (opt == MRB_SYM(ssh_private_keyfile)) rc = curl_easy_setopt(h, CURLOPT_SSH_PRIVATE_KEYFILE, mrb_string_cstr(mrb, val));
  else if (opt == MRB_SYM(ssh_public_keyfile)) rc = curl_easy_setopt(h, CURLOPT_SSH_PUBLIC_KEYFILE, mrb_string_cstr(mrb, val));
  else if (opt == MRB_SYM(use_ssl))            rc = curl_easy_setopt(h, CURLOPT_USE_SSL, (long)mrb_as_int(mrb, val));
  else if (opt == MRB_SYM(rtsp_request))       rc = curl_easy_setopt(h, CURLOPT_RTSP_REQUEST, (long)mrb_as_int(mrb, val));
  else if (opt == MRB_SYM(rtsp_stream_uri))    rc = curl_easy_setopt(h, CURLOPT_RTSP_STREAM_URI, mrb_string_cstr(mrb, val));
  else if (opt == MRB_SYM(rtsp_transport))     rc = curl_easy_setopt(h, CURLOPT_RTSP_TRANSPORT, mrb_string_cstr(mrb, val));
  /* --- client TLS ------------------------------------------------------- */
  else if (opt == MRB_SYM(sslcert))            rc = curl_easy_setopt(h, CURLOPT_SSLCERT, mrb_string_cstr(mrb, val));
  else if (opt == MRB_SYM(sslkey))             rc = curl_easy_setopt(h, CURLOPT_SSLKEY, mrb_string_cstr(mrb, val));
  else if (opt == MRB_SYM(keypasswd))          rc = curl_easy_setopt(h, CURLOPT_KEYPASSWD, mrb_string_cstr(mrb, val));
  else if (opt == MRB_SYM(capath))             rc = curl_easy_setopt(h, CURLOPT_CAPATH, mrb_string_cstr(mrb, val));
  else if (opt == MRB_SYM(pinnedpublickey))    rc = curl_easy_setopt(h, CURLOPT_PINNEDPUBLICKEY, mrb_string_cstr(mrb, val));
  else if (opt == MRB_SYM(ssl_cipher_list))    rc = curl_easy_setopt(h, CURLOPT_SSL_CIPHER_LIST, mrb_string_cstr(mrb, val));
  else if (opt == MRB_SYM(sslversion))         rc = curl_easy_setopt(h, CURLOPT_SSLVERSION, (long)mrb_as_int(mrb, val));
  /* --- HTTP version / cookies / redirect auth --------------------------- */
  else if (opt == MRB_SYM(http_version))       rc = curl_easy_setopt(h, CURLOPT_HTTP_VERSION, (long)mrb_as_int(mrb, val));
  else if (opt == MRB_SYM(cookie))             rc = curl_easy_setopt(h, CURLOPT_COOKIE, mrb_string_cstr(mrb, val));
  else if (opt == MRB_SYM(unrestricted_auth))  rc = curl_easy_setopt(h, CURLOPT_UNRESTRICTED_AUTH, (long)mrb_bool(val));
  else if (opt == MRB_SYM(postredir))          rc = curl_easy_setopt(h, CURLOPT_POSTREDIR, (long)mrb_as_int(mrb, val));
  /* --- proxy ------------------------------------------------------------ */
  else if (opt == MRB_SYM(proxyuserpwd))       rc = curl_easy_setopt(h, CURLOPT_PROXYUSERPWD, mrb_string_cstr(mrb, val));
  else if (opt == MRB_SYM(proxytype))          rc = curl_easy_setopt(h, CURLOPT_PROXYTYPE, (long)mrb_as_int(mrb, val));
  else if (opt == MRB_SYM(httpproxytunnel))    rc = curl_easy_setopt(h, CURLOPT_HTTPPROXYTUNNEL, (long)mrb_bool(val));
  else if (opt == MRB_SYM(noproxy))            rc = curl_easy_setopt(h, CURLOPT_NOPROXY, mrb_string_cstr(mrb, val));
  /* --- name resolution -------------------------------------------------- */
  else if (opt == MRB_SYM(interface))          rc = curl_easy_setopt(h, CURLOPT_INTERFACE, mrb_string_cstr(mrb, val));
  else if (opt == MRB_SYM(dns_servers))        rc = curl_easy_setopt(h, CURLOPT_DNS_SERVERS, mrb_string_cstr(mrb, val));
  else if (opt == MRB_SYM(doh_url))            rc = curl_easy_setopt(h, CURLOPT_DOH_URL, mrb_string_cstr(mrb, val));
  /* --- transfer rate limiting ------------------------------------------- */
  else if (opt == MRB_SYM(max_send_speed))     rc = curl_easy_setopt(h, CURLOPT_MAX_SEND_SPEED_LARGE, (curl_off_t)mrb_as_int(mrb, val));
  else if (opt == MRB_SYM(max_recv_speed))     rc = curl_easy_setopt(h, CURLOPT_MAX_RECV_SPEED_LARGE, (curl_off_t)mrb_as_int(mrb, val));
  /* --- TCP keepalive ---------------------------------------------------- */
  else if (opt == MRB_SYM(tcp_keepalive))      rc = curl_easy_setopt(h, CURLOPT_TCP_KEEPALIVE, (long)mrb_bool(val));
  else if (opt == MRB_SYM(tcp_keepidle))       rc = curl_easy_setopt(h, CURLOPT_TCP_KEEPIDLE, (long)mrb_as_int(mrb, val));
  else if (opt == MRB_SYM(tcp_keepintvl))      rc = curl_easy_setopt(h, CURLOPT_TCP_KEEPINTVL, (long)mrb_as_int(mrb, val));
  /* --- unix domain socket (Docker / HTTP-over-unix) --------------------- */
  else if (opt == MRB_SYM(unix_socket_path))   rc = curl_easy_setopt(h, CURLOPT_UNIX_SOCKET_PATH, mrb_string_cstr(mrb, val));
  /* --- multipart/form-data: val is a URL::Libcurl::Mime built in Ruby --- */
  else if (opt == MRB_SYM(mimepost))           rc = curl_easy_setopt(h, CURLOPT_MIMEPOST, murl_mime_get(mrb, val));
  else if (opt == MRB_SYM(post_fields)) {
    mrb_value s = mrb_str_to_str(mrb, val);
    curl_easy_setopt(h, CURLOPT_POSTFIELDSIZE_LARGE, (curl_off_t)RSTRING_LEN(s));
    rc = curl_easy_setopt(h, CURLOPT_COPYPOSTFIELDS, RSTRING_PTR(s));
  }
  else if (opt == MRB_SYM(httpheader)) {
    /* Accept a Ruby Array of "Key: Value" strings; build the slist here and
     * free any previous one. The string building stays in Ruby. */
    mrb_value arr = mrb_ensure_array_type(mrb, val);
    if (e->req_headers) {
      curl_slist_free_all(e->req_headers);
      e->req_headers = NULL;
    }
    mrb_int n = RARRAY_LEN(arr);
    for (mrb_int i = 0; i < n; i++) {
      mrb_value line = mrb_ary_ref(mrb, arr, i);
      struct curl_slist* next =
        curl_slist_append(e->req_headers, mrb_string_cstr(mrb, line));
      if (unlikely(!next)) mrb_raise(mrb, E_RUNTIME_ERROR, "curl_slist_append failed");
      e->req_headers = next;
    }
    rc = curl_easy_setopt(h, CURLOPT_HTTPHEADER, e->req_headers);
  }
  else if (opt == MRB_SYM(mail_rcpt)) {
    /* Accept a Ruby Array of recipient strings; build the slist here and free
     * any previous one. The decision of which recipients stays in Ruby. */
    mrb_value arr = mrb_ensure_array_type(mrb, val);
    if (e->mail_rcpt) {
      curl_slist_free_all(e->mail_rcpt);
      e->mail_rcpt = NULL;
    }
    mrb_int n = RARRAY_LEN(arr);
    for (mrb_int i = 0; i < n; i++) {
      mrb_value addr = mrb_ary_ref(mrb, arr, i);
      struct curl_slist* next =
        curl_slist_append(e->mail_rcpt, mrb_string_cstr(mrb, addr));
      if (unlikely(!next)) mrb_raise(mrb, E_RUNTIME_ERROR, "curl_slist_append failed");
      e->mail_rcpt = next;
    }
    rc = curl_easy_setopt(h, CURLOPT_MAIL_RCPT, e->mail_rcpt);
  }
  else if (opt == MRB_SYM(quote)) {
    /* Accept a Ruby Array of raw protocol commands (FTP/SFTP: "DELE x",
     * "MKD d", "RENAME a b", …); build the slist here and free any previous
     * one. Which commands to send is decided in Ruby. */
    mrb_value arr = mrb_ensure_array_type(mrb, val);
    if (e->quote) {
      curl_slist_free_all(e->quote);
      e->quote = NULL;
    }
    mrb_int n = RARRAY_LEN(arr);
    for (mrb_int i = 0; i < n; i++) {
      mrb_value cmd = mrb_ary_ref(mrb, arr, i);
      struct curl_slist* next =
        curl_slist_append(e->quote, mrb_string_cstr(mrb, cmd));
      if (unlikely(!next)) mrb_raise(mrb, E_RUNTIME_ERROR, "curl_slist_append failed");
      e->quote = next;
    }
    rc = curl_easy_setopt(h, CURLOPT_QUOTE, e->quote);
  }
  else {
    mrb_raisef(mrb, E_ARGUMENT_ERROR, "unsupported option: :%n", opt);
  }

  murl_easy_check(mrb, rc);
  return easy_obj;
}

/* =========================================================================
 * easy_getinfo(easy, sym) -> value   (flat sym -> CURLINFO_*)
 * ========================================================================= */

static mrb_value
murl_lc_easy_getinfo(mrb_state* mrb, mrb_value mod)
{
  (void)mod;
  mrb_value easy_obj;
  mrb_sym   info;
  mrb_get_args(mrb, "on", &easy_obj, &info);

  murl_easy_t* e = murl_easy_get(mrb, easy_obj);
  CURL* h = e->curl;

  if (info == MRB_SYM(response_code)) {
    long code = 0;
    murl_easy_check(mrb, curl_easy_getinfo(h, CURLINFO_RESPONSE_CODE, &code));
    return mrb_convert_long(mrb, code);
  }
  else if (info == MRB_SYM(effective_url)) {
    const char* url = NULL;
    murl_easy_check(mrb, curl_easy_getinfo(h, CURLINFO_EFFECTIVE_URL, &url));
    return url ? mrb_str_new_cstr(mrb, url) : mrb_nil_value();
  }
  else if (info == MRB_SYM(total_time)) {
    curl_off_t us = 0;
    murl_easy_check(mrb, curl_easy_getinfo(h, CURLINFO_TOTAL_TIME_T, &us));
    return mrb_float_value(mrb, (mrb_float)us / 1e6);
  }
  else if (info == MRB_SYM(content_type)) {
    const char* ct = NULL;
    murl_easy_check(mrb, curl_easy_getinfo(h, CURLINFO_CONTENT_TYPE, &ct));
    return ct ? mrb_str_new_cstr(mrb, ct) : mrb_nil_value();
  }
  else if (info == MRB_SYM(activesocket)) {
    curl_socket_t sock = CURL_SOCKET_BAD;
    murl_easy_check(mrb, curl_easy_getinfo(h, CURLINFO_ACTIVESOCKET, &sock));
    if (sock == CURL_SOCKET_BAD) return mrb_nil_value();
    return mrb_int_value(mrb, (mrb_int)sock);
  }

  mrb_raisef(mrb, E_ARGUMENT_ERROR, "unsupported info: :%n", info);
  return mrb_nil_value();
}

/* =========================================================================
 * easy_strerror(int) -> str
 * ========================================================================= */

static mrb_value
murl_lc_easy_strerror(mrb_state* mrb, mrb_value mod)
{
  (void)mod;
  mrb_int code;
  mrb_get_args(mrb, "i", &code);
  const char* s = curl_easy_strerror((CURLcode)code);
  return s ? mrb_str_new_cstr(mrb, s) : mrb_nil_value();
}

/* =========================================================================
 * easy_perform(easy) -> CURLcode int
 *
 * Blocking single-transfer drive. Used by the WebSocket connect path: with
 * CONNECT_ONLY=2 set, curl_easy_perform runs the upgrade handshake and returns,
 * leaving the connection (and its active socket) on the easy handle so the ws
 * framing primitives below can use it. Returns the CURLcode as a value (0 ==
 * CURLE_OK) so Ruby decides what a failure means — never raises on a transfer
 * error; a callback-stashed exception still propagates.
 * ========================================================================= */

static mrb_value
murl_lc_easy_perform(mrb_state* mrb, mrb_value mod)
{
  (void)mod;
  mrb_value easy_obj;
  mrb_get_args(mrb, "o", &easy_obj);
  murl_easy_t* e = murl_easy_get(mrb, easy_obj);

  CURLcode rc = curl_easy_perform(e->curl);
  if (unlikely(mrb->exc != NULL)) mrb_exc_raise(mrb, mrb_obj_value(mrb->exc));
  return mrb_convert_int(mrb, rc);
}

/* =========================================================================
 * WebSocket framing primitives (curl_ws_recv / curl_ws_send).
 *
 * Thin marshalling only: copy bytes across the boundary and hand libcurl's
 * frame flags back as a plain int. All message-level policy — fragment
 * reassembly, text/binary/ping/pong/close dispatch, the send loop — lives in
 * Ruby (URL::WebSocket). These run on a CONNECT_ONLY=2 Easy after the upgrade
 * handshake has completed; the Ruby side selects on the active socket between
 * calls, so CURLE_AGAIN is marshalled to nil rather than raised.
 * ========================================================================= */

#ifdef MURL_HAVE_WEBSOCKETS

/* easy_ws_recv(easy, buflen) -> [String, flags_int, bytesleft_int] | nil
 *   nil means CURLE_AGAIN (nothing readable yet); the caller waits on the fd. */
static mrb_value
murl_lc_easy_ws_recv(mrb_state* mrb, mrb_value mod)
{
  (void)mod;
  mrb_value easy_obj;
  mrb_int   buflen;
  mrb_get_args(mrb, "oi", &easy_obj, &buflen);
  if (unlikely(buflen <= 0)) mrb_raise(mrb, E_ARGUMENT_ERROR, "buflen must be positive");

  murl_easy_t* e = murl_easy_get(mrb, easy_obj);

  mrb_value buf = mrb_str_new(mrb, NULL, (mrb_int)buflen);
  size_t recv = 0;
  const struct curl_ws_frame* meta = NULL;
  CURLcode rc = curl_ws_recv(e->curl, RSTRING_PTR(buf), (size_t)buflen, &recv, &meta);

  if (rc == CURLE_AGAIN) return mrb_nil_value();
  murl_easy_check(mrb, rc);

  mrb_str_resize(mrb, buf, (mrb_int)recv);
  int        flags     = meta ? meta->flags     : 0;
  curl_off_t bytesleft = meta ? meta->bytesleft : 0;

  mrb_value out = mrb_ary_new_capa(mrb, 3);
  mrb_ary_push(mrb, out, buf);
  mrb_ary_push(mrb, out, mrb_int_value(mrb, flags));
  mrb_ary_push(mrb, out, mrb_int_value(mrb, (mrb_int)bytesleft));
  return out;
}

/* easy_ws_send(easy, str, flags_int, fragsize=0) -> sent_count | nil
 *   nil means CURLE_AGAIN (the socket isn't writable yet). */
static mrb_value
murl_lc_easy_ws_send(mrb_state* mrb, mrb_value mod)
{
  (void)mod;
  mrb_value easy_obj, data;
  mrb_int   flags;
  mrb_int   fragsize = 0;
  mrb_get_args(mrb, "oSi|i", &easy_obj, &data, &flags, &fragsize);

  murl_easy_t* e = murl_easy_get(mrb, easy_obj);

  size_t sent = 0;
  CURLcode rc = curl_ws_send(e->curl, RSTRING_PTR(data), (size_t)RSTRING_LEN(data),
                             &sent, (curl_off_t)fragsize, (unsigned int)flags);
  if (rc == CURLE_AGAIN) return mrb_nil_value();
  murl_easy_check(mrb, rc);
  return mrb_convert_size_t(mrb, sent);
}

#else  /* libcurl built without WebSocket support */

static mrb_value
murl_lc_ws_unsupported(mrb_state* mrb, mrb_value mod)
{
  (void)mod;
  mrb_raise(mrb, E_NOTIMP_ERROR, "embedded libcurl built without WebSocket support");
  return mrb_nil_value();
}

#endif

/* =========================================================================
 * multi_init -> Multi
 * ========================================================================= */

static mrb_value
murl_lc_multi_init(mrb_state* mrb, mrb_value mod)
{
  struct RClass* lc  = mrb_class_ptr(mod);
  struct RClass* cls = mrb_class_get_under_id(mrb, lc, MRB_SYM(Multi));

  murl_multi_t* m;
  struct RData* d;
  Data_Make_Struct(mrb, cls, murl_multi_t, &murl_multi_type, m, d);
  mrb_value self          = mrb_obj_value(d);
  m->mrb                  = mrb;
  m->self                 = self;
  m->multi                = NULL;

  CURLM* h = curl_multi_init();
  if (unlikely(!h)) mrb_raise(mrb, E_RUNTIME_ERROR, "curl_multi_init failed");
  m->multi = h;

  curl_multi_setopt(h, CURLMOPT_SOCKETFUNCTION, murl_socket_cb);
  curl_multi_setopt(h, CURLMOPT_SOCKETDATA,     m);
  curl_multi_setopt(h, CURLMOPT_TIMERFUNCTION,  murl_timer_cb);
  curl_multi_setopt(h, CURLMOPT_TIMERDATA,      m);

  return self;
}

/* =========================================================================
 * multi_setopt(multi, sym, val) -> multi   (flat sym -> CURLMOPT_*)
 * ========================================================================= */

static mrb_value
murl_lc_multi_setopt(mrb_state* mrb, mrb_value mod)
{
  (void)mod;
  mrb_value multi_obj, val;
  mrb_sym   opt;
  mrb_get_args(mrb, "ono", &multi_obj, &opt, &val);

  murl_multi_t* m = murl_multi_get(mrb, multi_obj);
  CURLM* h = m->multi;

  CURLMcode rc = CURLM_OK;

  if      (opt == MRB_SYM(pipelining))             rc = curl_multi_setopt(h, CURLMOPT_PIPELINING, (long)mrb_as_int(mrb, val));
  else if (opt == MRB_SYM(maxconnects))            rc = curl_multi_setopt(h, CURLMOPT_MAXCONNECTS, (long)mrb_as_int(mrb, val));
  else if (opt == MRB_SYM(max_host_connections))   rc = curl_multi_setopt(h, CURLMOPT_MAX_HOST_CONNECTIONS, (long)mrb_as_int(mrb, val));
  else if (opt == MRB_SYM(max_total_connections))  rc = curl_multi_setopt(h, CURLMOPT_MAX_TOTAL_CONNECTIONS, (long)mrb_as_int(mrb, val));
  else if (opt == MRB_SYM(max_concurrent_streams)) rc = curl_multi_setopt(h, CURLMOPT_MAX_CONCURRENT_STREAMS, (long)mrb_as_int(mrb, val));
  else {
    mrb_raisef(mrb, E_ARGUMENT_ERROR, "unsupported option: :%n", opt);
  }

  murl_multi_check(mrb, rc);
  return multi_obj;
}

/* =========================================================================
 * multi_add(multi, easy) / multi_remove(multi, easy)
 * ========================================================================= */

static mrb_value
murl_lc_multi_add(mrb_state* mrb, mrb_value mod)
{
  (void)mod;
  mrb_value multi_obj, easy_obj;
  mrb_get_args(mrb, "oo", &multi_obj, &easy_obj);

  murl_multi_t* m = murl_multi_get(mrb, multi_obj);
  murl_easy_t*  e = murl_easy_get(mrb, easy_obj);

  murl_multi_check(mrb, curl_multi_add_handle(m->multi, e->curl));

  /* Root the easy on the multi while curl_multi references its CURL*, under a
   * HIDDEN ivar (MRB_SYM 'easies', no leading '@'): the GC traces it so the
   * easy can't be cleaned up mid-transfer, but instance_variable_* can't reach
   * a non-'@' name, so Ruby can't drop the root and induce a use-after-free.
   * The Ruby-side session bookkeeping is then just lookup, not a safety root. */
  mrb_value easies = mrb_iv_get(mrb, multi_obj, MRB_SYM(easies));
  if (!mrb_hash_p(easies)) {
    easies = mrb_hash_new(mrb);
    mrb_iv_set(mrb, multi_obj, MRB_SYM(easies), easies);
  }
  mrb_hash_set(mrb, easies, easy_obj, mrb_true_value());
  return multi_obj;
}

static mrb_value
murl_lc_multi_remove(mrb_state* mrb, mrb_value mod)
{
  (void)mod;
  mrb_value multi_obj, easy_obj;
  mrb_get_args(mrb, "oo", &multi_obj, &easy_obj);

  murl_multi_t* m = murl_multi_get(mrb, multi_obj);
  murl_easy_t*  e = murl_easy_get(mrb, easy_obj);

  murl_multi_check(mrb, curl_multi_remove_handle(m->multi, e->curl));

  /* Drop the hidden GC root added in multi_add — the easy is no longer in the
   * multi, so it may be collected (and curl_easy_cleanup'd) safely. */
  mrb_value easies = mrb_iv_get(mrb, multi_obj, MRB_SYM(easies));
  if (mrb_hash_p(easies)) mrb_hash_delete_key(mrb, easies, easy_obj);
  return multi_obj;
}

/* =========================================================================
 * multi_socket_action(multi, fd=SOCKET_TIMEOUT, ev=nil) -> running
 *   ev is nil / :in / :out / :inout / :err -> bitmask.
 * ========================================================================= */

static mrb_value
murl_lc_multi_socket_action(mrb_state* mrb, mrb_value mod)
{
  (void)mod;
  mrb_value multi_obj;
  mrb_int   fd     = (mrb_int)CURL_SOCKET_TIMEOUT;
  mrb_value ev_obj = mrb_nil_value();
  mrb_get_args(mrb, "o|io", &multi_obj, &fd, &ev_obj);

  murl_multi_t* m = murl_multi_get(mrb, multi_obj);

  int ev_bitmask;
  if (mrb_nil_p(ev_obj)) {
    ev_bitmask = 0;
  } else {
    mrb_sym ev_sym = mrb_obj_to_sym(mrb, ev_obj);
    if      (ev_sym == MRB_SYM(in))    ev_bitmask = CURL_CSELECT_IN;
    else if (ev_sym == MRB_SYM(out))   ev_bitmask = CURL_CSELECT_OUT;
    else if (ev_sym == MRB_SYM(inout)) ev_bitmask = CURL_CSELECT_IN | CURL_CSELECT_OUT;
    else if (ev_sym == MRB_SYM(err))   ev_bitmask = CURL_CSELECT_ERR;
    else { mrb_raisef(mrb, E_ARGUMENT_ERROR, "unknown event: :%n", ev_sym); return mrb_nil_value(); }
  }

  int running = 0;
  CURLMcode rc =
    curl_multi_socket_action(m->multi, (curl_socket_t)fd, ev_bitmask, &running);

  murl_multi_check(mrb, rc);
  return mrb_convert_int(mrb, running);
}

/* =========================================================================
 * multi_info_read(multi) -> [easy, result_int] | nil
 *   Return ONE CURLMSG_DONE message's Ruby Easy + code per call; nil when
 *   drained.
 * ========================================================================= */

static mrb_value
murl_lc_multi_info_read(mrb_state* mrb, mrb_value mod)
{
  (void)mod;
  mrb_value multi_obj;
  mrb_get_args(mrb, "o", &multi_obj);

  murl_multi_t* m = murl_multi_get(mrb, multi_obj);

  int remaining = 0;
  const CURLMsg* msg;
  while ((msg = curl_multi_info_read(m->multi, &remaining)) != NULL) {
    if (msg->msg != CURLMSG_DONE) continue;

    /* Out of memory is the one CURLcode we never marshal back as a value:
     * building the wrapper in Ruby might itself allocate. Mirror mruby's own
     * allocator (mrb_realloc) — flag the VM out-of-memory and raise the
     * preallocated NoMemoryError (mrb->nomem_err) directly, so OOM never
     * reaches Ruby as a plain code. */
    if (unlikely(msg->data.result == CURLE_OUT_OF_MEMORY)) {
      mrb->gc.out_of_memory = TRUE;
      mrb_exc_raise(mrb, mrb_obj_value(mrb->nomem_err));
    }

    murl_easy_t* e = NULL;
    curl_easy_getinfo(msg->easy_handle, CURLINFO_PRIVATE, &e);
    if (unlikely(!e)) continue;

    mrb_value pair = mrb_ary_new_capa(mrb, 2);
    mrb_ary_push(mrb, pair, e->self);
    mrb_ary_push(mrb, pair, mrb_convert_int(mrb, msg->data.result));
    return pair;
  }
  return mrb_nil_value();
}

/* =========================================================================
 * multi_strerror(int) -> str
 * ========================================================================= */

static mrb_value
murl_lc_multi_strerror(mrb_state* mrb, mrb_value mod)
{
  (void)mod;
  mrb_int code;
  mrb_get_args(mrb, "i", &code);
  const char* s = curl_multi_strerror((CURLMcode)code);
  return s ? mrb_str_new_cstr(mrb, s) : mrb_nil_value();
}

/* =========================================================================
 * Gem entry points
 * ========================================================================= */

/* libcurl's global init/cleanup are process-global, not per-mrb_state, and are
 * not safe to churn. curl_global_init brings up the TLS backend and (on
 * Windows) Winsock, which must come up once before any other thread runs and be
 * torn down once after every handle is gone. Tying them naively to gem_init /
 * gem_final would re-run them for every VM: a race when VMs are created on
 * multiple threads, and worse, one VM's gem_final could pull the TLS/Winsock
 * layer out from under a transfer still live in another VM.
 *
 * So we refcount. A C11 call_once builds the mutex exactly once (mtx_t has no
 * static initializer), and under that mutex gem_init runs curl_global_init only
 * on the 0->1 transition and gem_final runs curl_global_cleanup only on the
 * 1->0 transition. The mutex serialises those two calls across concurrently
 * created mrb_states; the count keeps the global layer up for as long as any VM
 * is using it, then tears it down once the last one is gone. Per-mrb_state
 * handle teardown still happens in gem_final below. */
static once_flag g_once = ONCE_FLAG_INIT;
static mtx_t     g_lock;              /* mtx_t has NO static initializer in C11 */
static unsigned  g_refs = 0;

static void init_lock(void) { mtx_init(&g_lock, mtx_plain); }

void
mrb_mruby_url_gem_init(mrb_state* mrb)
{
  call_once(&g_once, init_lock);
  mtx_lock(&g_lock);
  if (g_refs++ == 0) curl_global_init(CURL_GLOBAL_DEFAULT);
  mtx_unlock(&g_lock);

  struct RClass* url_cls = mrb_define_class_id(mrb, MRB_SYM(URL), mrb->object_class);

  struct RClass* lc = mrb_define_module_under_id(mrb, url_cls, MRB_SYM(Libcurl));

  mrb_define_module_function_id(mrb, lc, MRB_SYM(easy_init),     murl_lc_easy_init,     MRB_ARGS_NONE());
  mrb_define_module_function_id(mrb, lc, MRB_SYM(easy_setopt),   murl_lc_easy_setopt,   MRB_ARGS_REQ(3));
  mrb_define_module_function_id(mrb, lc, MRB_SYM(easy_getinfo),  murl_lc_easy_getinfo,  MRB_ARGS_REQ(2));
  mrb_define_module_function_id(mrb, lc, MRB_SYM(easy_strerror), murl_lc_easy_strerror, MRB_ARGS_REQ(1));
  mrb_define_module_function_id(mrb, lc, MRB_SYM(easy_perform),  murl_lc_easy_perform,  MRB_ARGS_REQ(1));

#ifdef MURL_HAVE_WEBSOCKETS
  mrb_define_module_function_id(mrb, lc, MRB_SYM(easy_ws_recv), murl_lc_easy_ws_recv, MRB_ARGS_REQ(2));
  mrb_define_module_function_id(mrb, lc, MRB_SYM(easy_ws_send), murl_lc_easy_ws_send, MRB_ARGS_ARG(3, 1));
#else
  mrb_define_module_function_id(mrb, lc, MRB_SYM(easy_ws_recv), murl_lc_ws_unsupported, MRB_ARGS_ANY());
  mrb_define_module_function_id(mrb, lc, MRB_SYM(easy_ws_send), murl_lc_ws_unsupported, MRB_ARGS_ANY());
#endif

  /* WebSocket frame flags (CURLWS_*), published so the Ruby URL::WebSocket can
   * map its :text/:binary/:ping/:pong/:close symbols to the bitmask and back.
   * Each is 0 when the embedded libcurl predates the WebSocket API. */
  mrb_define_const_id(mrb, lc, MRB_SYM(WS_TEXT),   mrb_int_value(mrb, MURL_WS_FLAG(TEXT)));
  mrb_define_const_id(mrb, lc, MRB_SYM(WS_BINARY), mrb_int_value(mrb, MURL_WS_FLAG(BINARY)));
  mrb_define_const_id(mrb, lc, MRB_SYM(WS_CONT),   mrb_int_value(mrb, MURL_WS_FLAG(CONT)));
  mrb_define_const_id(mrb, lc, MRB_SYM(WS_CLOSE),  mrb_int_value(mrb, MURL_WS_FLAG(CLOSE)));
  mrb_define_const_id(mrb, lc, MRB_SYM(WS_PING),   mrb_int_value(mrb, MURL_WS_FLAG(PING)));
  mrb_define_const_id(mrb, lc, MRB_SYM(WS_PONG),   mrb_int_value(mrb, MURL_WS_FLAG(PONG)));
  mrb_define_const_id(mrb, lc, MRB_SYM(WS_OFFSET), mrb_int_value(mrb, MURL_WS_FLAG(OFFSET)));

  mrb_define_module_function_id(mrb, lc, MRB_SYM(multi_init),          murl_lc_multi_init,          MRB_ARGS_NONE());
  mrb_define_module_function_id(mrb, lc, MRB_SYM(multi_setopt),        murl_lc_multi_setopt,        MRB_ARGS_REQ(3));
  mrb_define_module_function_id(mrb, lc, MRB_SYM(multi_add),           murl_lc_multi_add,           MRB_ARGS_REQ(2));
  mrb_define_module_function_id(mrb, lc, MRB_SYM(multi_remove),        murl_lc_multi_remove,        MRB_ARGS_REQ(2));
  mrb_define_module_function_id(mrb, lc, MRB_SYM(multi_socket_action), murl_lc_multi_socket_action, MRB_ARGS_ARG(1, 2));
  mrb_define_module_function_id(mrb, lc, MRB_SYM(multi_info_read),     murl_lc_multi_info_read,     MRB_ARGS_REQ(1));
  mrb_define_module_function_id(mrb, lc, MRB_SYM(multi_strerror),      murl_lc_multi_strerror,      MRB_ARGS_REQ(1));

  mrb_define_const_id(mrb, lc, MRB_SYM(SOCKET_TIMEOUT), mrb_convert_int(mrb, CURL_SOCKET_TIMEOUT));

  /* Publish the compiled-in protocol list as URL::Libcurl::PROTOCOLS, a frozen
   * Array of lowercased Strings. Pure marshalling of curl_version_info()'s
   * NULL-terminated ->protocols array; the dispatch that consumes it is Ruby. */
  {
    curl_version_info_data* vi = curl_version_info(CURLVERSION_NOW);
    mrb_value protos = mrb_ary_new(mrb);
    if (vi && vi->protocols) {
      for (const char* const* p = vi->protocols; *p != NULL; p++) {
        mrb_value s = mrb_str_new_cstr(mrb, *p);
        char* buf = RSTRING_PTR(s);
        mrb_int len = RSTRING_LEN(s);
        for (mrb_int i = 0; i < len; i++) {
          if (buf[i] >= 'A' && buf[i] <= 'Z') buf[i] = (char)(buf[i] - 'A' + 'a');
        }
        mrb_ary_push(mrb, protos, mrb_obj_freeze(mrb, s));
      }
    }
    mrb_define_const_id(mrb, lc, MRB_SYM(PROTOCOLS), mrb_obj_freeze(mrb, protos));
  }

  struct RClass* easy_cls =
    mrb_define_class_under_id(mrb, lc, MRB_SYM(Easy), mrb->object_class);
  MRB_SET_INSTANCE_TT(easy_cls, MRB_TT_CDATA);
  mrb_undef_method_id(mrb, easy_cls, MRB_SYM(initialize));

  struct RClass* multi_cls =
    mrb_define_class_under_id(mrb, lc, MRB_SYM(Multi), mrb->object_class);
  MRB_SET_INSTANCE_TT(multi_cls, MRB_TT_CDATA);
  mrb_undef_method_id(mrb, multi_cls, MRB_SYM(initialize));

  struct RClass* share_cls =
    mrb_define_class_under_id(mrb, lc, MRB_SYM(Share), mrb->object_class);
  MRB_SET_INSTANCE_TT(share_cls, MRB_TT_CDATA);
  mrb_undef_method_id(mrb, share_cls, MRB_SYM(initialize));

  /* multipart/form-data handles: curl_mime (the tree) and curl_mimepart. */
  struct RClass* mime_cls =
    mrb_define_class_under_id(mrb, lc, MRB_SYM(Mime), mrb->object_class);
  MRB_SET_INSTANCE_TT(mime_cls, MRB_TT_CDATA);
  mrb_undef_method_id(mrb, mime_cls, MRB_SYM(initialize));

  struct RClass* part_cls =
    mrb_define_class_under_id(mrb, lc, MRB_SYM(Part), mrb->object_class);
  MRB_SET_INSTANCE_TT(part_cls, MRB_TT_CDATA);
  mrb_undef_method_id(mrb, part_cls, MRB_SYM(initialize));

  mrb_define_module_function_id(mrb, lc, MRB_SYM(mime_new),      murl_lc_mime_new,      MRB_ARGS_REQ(1));
  mrb_define_module_function_id(mrb, lc, MRB_SYM(mime_addpart),  murl_lc_mime_addpart,  MRB_ARGS_REQ(1));
  mrb_define_module_function_id(mrb, lc, MRB_SYM(mime_name),     murl_lc_mime_name,     MRB_ARGS_REQ(2));
  mrb_define_module_function_id(mrb, lc, MRB_SYM(mime_data),     murl_lc_mime_data,     MRB_ARGS_REQ(2));
  mrb_define_module_function_id(mrb, lc, MRB_SYM(mime_filedata), murl_lc_mime_filedata, MRB_ARGS_REQ(2));
  mrb_define_module_function_id(mrb, lc, MRB_SYM(mime_type),     murl_lc_mime_type,     MRB_ARGS_REQ(2));
  mrb_define_module_function_id(mrb, lc, MRB_SYM(mime_filename), murl_lc_mime_filename, MRB_ARGS_REQ(2));

  /* One Share per VM, published as URL::Libcurl::SHARE so easy_init can attach
   * to it. CONNECT + SSL_SESSION are the safe-and-useful caches to share
   * single-threaded; lock callbacks intentionally unset (curl guards with
   * `if(share->lockfunc)`). The two setopt return codes are checked because a
   * CURLSHE_NOMEM there would otherwise silently degrade the share to
   * unconfigured — every easy would attach and never reuse anything. */
  {
    murl_share_t* s;
    struct RData* sd;
    Data_Make_Struct(mrb, share_cls, murl_share_t, &murl_share_type, s, sd);
    s->mrb   = mrb;
    s->share = curl_share_init();
    if (unlikely(!s->share)) mrb_raise(mrb, E_RUNTIME_ERROR, "curl_share_init failed");
    CURLSHcode src;
    src = curl_share_setopt(s->share, CURLSHOPT_SHARE, CURL_LOCK_DATA_CONNECT);
    if (unlikely(src != CURLSHE_OK))
      mrb_raisef(mrb, E_RUNTIME_ERROR, "curl_share_setopt(CONNECT): %s", curl_share_strerror(src));
    src = curl_share_setopt(s->share, CURLSHOPT_SHARE, CURL_LOCK_DATA_SSL_SESSION);
    if (unlikely(src != CURLSHE_OK))
      mrb_raisef(mrb, E_RUNTIME_ERROR, "curl_share_setopt(SSL_SESSION): %s", curl_share_strerror(src));
    mrb_define_const_id(mrb, lc, MRB_SYM(SHARE), mrb_obj_value(sd));
  }
}

/* =========================================================================
 * Per-state cleanup — two-pass disarm then free.
 *
 * On interpreter teardown, first disarm every live handle's callbacks (so a
 * curl cleanup that drives teardown never re-enters mruby), then run the curl
 * cleanups and clear the CDATA pointers so the GC sweep's free is a no-op.
 * ========================================================================= */

static int
murl_disarm_callbacks(mrb_state* mrb, struct RBasic* obj, void* data)
{
  (void)data;
  if (mrb_object_dead_p(mrb, obj)) return MRB_EACH_OBJ_OK;
  switch (obj->tt) { case MRB_TT_ENV: case MRB_TT_ICLASS: return MRB_EACH_OBJ_OK; default: break; }
  if (!obj->c || obj->tt != MRB_TT_CDATA) return MRB_EACH_OBJ_OK;
  struct RData* d = (struct RData*)obj;
  if (!d->data) return MRB_EACH_OBJ_OK;

  if (d->type == &murl_multi_type) {
    murl_multi_t* m = (murl_multi_t*)d->data;
    if (m->multi) {
      curl_multi_setopt(m->multi, CURLMOPT_SOCKETFUNCTION, NULL);
      curl_multi_setopt(m->multi, CURLMOPT_SOCKETDATA,     NULL);
      curl_multi_setopt(m->multi, CURLMOPT_TIMERFUNCTION,  NULL);
      curl_multi_setopt(m->multi, CURLMOPT_TIMERDATA,      NULL);
    }
  } else if (d->type == &murl_easy_type) {
    murl_easy_t* e = (murl_easy_t*)d->data;
    if (e->curl) {
      curl_easy_setopt(e->curl, CURLOPT_WRITEFUNCTION,  NULL);
      curl_easy_setopt(e->curl, CURLOPT_WRITEDATA,      NULL);
      curl_easy_setopt(e->curl, CURLOPT_HEADERFUNCTION, NULL);
      curl_easy_setopt(e->curl, CURLOPT_HEADERDATA,     NULL);
      curl_easy_setopt(e->curl, CURLOPT_READFUNCTION,   NULL);
      curl_easy_setopt(e->curl, CURLOPT_READDATA,       NULL);
      curl_easy_setopt(e->curl, CURLOPT_PRIVATE,        NULL);
    }
  }
  return MRB_EACH_OBJ_OK;
}

static int
murl_cleanup_curl(mrb_state* mrb, struct RBasic* obj, void* data)
{
  (void)data;
  if (mrb_object_dead_p(mrb, obj)) return MRB_EACH_OBJ_OK;
  switch (obj->tt) { case MRB_TT_ENV: case MRB_TT_ICLASS: return MRB_EACH_OBJ_OK; default: break; }
  if (!obj->c || obj->tt != MRB_TT_CDATA) return MRB_EACH_OBJ_OK;
  struct RData* d = (struct RData*)obj;
  if (!d->data) return MRB_EACH_OBJ_OK;

  if (d->type == &murl_multi_type) {
    murl_multi_t* m = (murl_multi_t*)d->data;
    if (m->multi) { curl_multi_cleanup(m->multi); m->multi = NULL; }
  } else if (d->type == &murl_easy_type) {
    murl_easy_t* e = (murl_easy_t*)d->data;
    if (e->curl) { curl_easy_cleanup(e->curl); e->curl = NULL; }
  }
  return MRB_EACH_OBJ_OK;
}

/* Third pass: clean every Share now that every easy/multi is gone. Each
 * curl_easy_cleanup above has detached its easy from the share
 * (Curl_share_easy_unlink, ref_count--), so curl_share_cleanup here succeeds
 * instead of returning CURLSHE_IN_USE. */
static int
murl_cleanup_share(mrb_state* mrb, struct RBasic* obj, void* data)
{
  (void)data;
  if (mrb_object_dead_p(mrb, obj)) return MRB_EACH_OBJ_OK;
  switch (obj->tt) { case MRB_TT_ENV: case MRB_TT_ICLASS: return MRB_EACH_OBJ_OK; default: break; }
  if (!obj->c || obj->tt != MRB_TT_CDATA) return MRB_EACH_OBJ_OK;
  struct RData* d = (struct RData*)obj;
  if (!d->data) return MRB_EACH_OBJ_OK;
  if (d->type != &murl_share_type) return MRB_EACH_OBJ_OK;
  murl_share_t* s = (murl_share_t*)d->data;
  if (s->share) { curl_share_cleanup(s->share); s->share = NULL; }
  return MRB_EACH_OBJ_OK;
}

void
mrb_mruby_url_gem_final(mrb_state* mrb)
{
  mrb_objspace_each_objects(mrb, murl_disarm_callbacks, NULL);
  mrb_objspace_each_objects(mrb, murl_cleanup_curl,     NULL);
  mrb_objspace_each_objects(mrb, murl_cleanup_share,    NULL);

  mtx_lock(&g_lock);
  if (--g_refs == 0) curl_global_cleanup();
  mtx_unlock(&g_lock);
}
