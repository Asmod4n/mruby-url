/*
** src/mrb_url.c - libcurl bindings for mruby-url
**
** Scope:
**   - URL                  : the session (1:1 with libcurl's multi handle).
**                            Real event loops integrate by subclassing
**                            URL::EventLoop (mrblib) and handing an instance
**                            to URL#event_loop=.
**   - URL::Userdata        : private companion CDATA holding
**                            (mrb, session_self) for libcurl's SOCKETDATA /
**                            TIMERDATA.
**   - URL::Request         : private CDATA wrapping a CURL* plus per-
**                            request state. Not user-constructible
**                            (#initialize undef'd); created only by
**                            URL::Request._open. The high-level shorthand
**                            uses it internally; the class never surfaces
**                            via the public API.
**   - URL::Request::Userdata : companion CDATA for Request callbacks.
**
** Callback safety: every libcurl-to-Ruby trampoline runs the Ruby body under
** mrb_protect_error. The first exception is stashed on mrb->exc, the callback
** returns libcurl's abort code, and the exception is re-raised when control
** returns to Ruby via murl_session_check / murl_easy_check.
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
#include <mruby/io.h>
#include <mruby/num_helpers.h>
#include <mruby/branch_pred.h>

#include <curl/curl.h>

#include <stddef.h>

/* ==========================================================================
 *  URL::Request   - CDATA payload is CURL*
 * ========================================================================== */

static void
murl_req_handle_free(mrb_state *mrb, void *p)
{
  (void)mrb;
  if (likely(p)) curl_easy_cleanup((CURL*)p);
}

static const struct mrb_data_type murl_req_type = {
  "URL::Request", murl_req_handle_free
};

static CURL*
murl_req_get(mrb_state *mrb, mrb_value self)
{
  CURL *h = (CURL*)mrb_data_check_get_ptr(mrb, self, &murl_req_type);
  if (unlikely(!h)) mrb_raise(mrb, E_RUNTIME_ERROR, "URL::Request not open");
  return h;
}

static void
murl_easy_check(mrb_state *mrb, CURLcode rc)
{
  if (unlikely(mrb->exc != NULL)) mrb_exc_raise(mrb, mrb_obj_value(mrb->exc));
  if (likely(rc == CURLE_OK)) return;
  mrb_raisef(mrb, E_RUNTIME_ERROR, "curl_easy error: %s", curl_easy_strerror(rc));
}

/* ==========================================================================
 *  URL::Request::Userdata
 * ========================================================================== */

typedef struct murl_req_ud_t {
  mrb_state         *mrb;
  mrb_value          request;
  struct curl_slist *req_headers;
} murl_req_ud_t;

static void
murl_req_ud_free(mrb_state *mrb, void *p)
{
  if (unlikely(!p)) return;
  murl_req_ud_t *ud = (murl_req_ud_t*)p;
  if (ud->req_headers) curl_slist_free_all(ud->req_headers);
  mrb_free(mrb, ud);
}

static const struct mrb_data_type murl_req_ud_type = {
  "URL::Request::Userdata", murl_req_ud_free
};

static murl_req_ud_t*
murl_req_ud_of(mrb_state *mrb, mrb_value req)
{
  mrb_value v = mrb_iv_get(mrb, req, MRB_IVSYM(userdata));
  return (murl_req_ud_t*)mrb_data_check_get_ptr(mrb, v, &murl_req_ud_type);
}

/* --- protected write/header dispatcher --------------------------------- */

typedef struct cb_str_args {
  mrb_value   cb;
  const char *ptr;
  size_t      len;
} cb_str_args;

static mrb_value
call_with_str_body(mrb_state *mrb, void *data)
{
  cb_str_args *a = (cb_str_args*)data;
  mrb_value s = mrb_str_new(mrb, a->ptr, a->len);
  return mrb_yield(mrb, a->cb, s);
}

static size_t
murl_dispatch_str_cb(murl_req_ud_t *ud, mrb_sym ivsym,
                     const char *ptr, size_t total)
{
  mrb_state *mrb = ud->mrb;
  mrb_value  cb  = mrb_iv_get(mrb, ud->request, ivsym);
  if (mrb_nil_p(cb)) return total;

  mrb_int ai = mrb_gc_arena_save(mrb);
  cb_str_args a = { cb, ptr, total };
  mrb_bool err = FALSE;
  mrb_value ret = mrb_protect_error(mrb, call_with_str_body, &a, &err);
  mrb_gc_arena_restore(mrb, ai);

  if (unlikely(err)) {
    if (mrb->exc == NULL) mrb->exc = mrb_obj_ptr(ret);
    return 0;
  }
  return total;
}

static size_t
murl_write_cb(char *ptr, size_t size, size_t nmemb, void *userdata)
{
  murl_req_ud_t *ud = (murl_req_ud_t*)userdata;
  size_t total = size * nmemb;
  if (unlikely(total == 0)) return 0;
  return murl_dispatch_str_cb(ud, MRB_IVSYM(on_data), ptr, total);
}

static size_t
murl_header_cb(char *ptr, size_t size, size_t nmemb, void *userdata)
{
  murl_req_ud_t *ud = (murl_req_ud_t*)userdata;
  size_t total = size * nmemb;
  if (unlikely(total == 0)) return 0;
  return murl_dispatch_str_cb(ud, MRB_IVSYM(on_header), ptr, total);
}

/* --- URL::Request._open ------------------------------------------------ */

static mrb_value
murl_req_open(mrb_state *mrb, mrb_value cls)
{
  const char *url = NULL;
  mrb_get_args(mrb, "|z!", &url);

  CURL *h = curl_easy_init();
  if (unlikely(!h)) mrb_raise(mrb, E_RUNTIME_ERROR, "curl_easy_init failed");

  mrb_value self = mrb_obj_value(
    mrb_data_object_alloc(mrb, mrb_class_ptr(cls), h, &murl_req_type));

  struct RClass *ud_cls = mrb_class_get_under_id(mrb, mrb_class_ptr(cls), MRB_SYM(Userdata));
  murl_req_ud_t *ud;
  struct RData  *ud_d;
  Data_Make_Struct(mrb, ud_cls, murl_req_ud_t, &murl_req_ud_type, ud, ud_d);
  ud->mrb     = mrb;
  ud->request = self;
  mrb_iv_set(mrb, self, MRB_IVSYM(userdata), mrb_obj_value(ud_d));

  curl_easy_setopt(h, CURLOPT_PRIVATE,        ud);
  curl_easy_setopt(h, CURLOPT_WRITEFUNCTION,  murl_write_cb);
  curl_easy_setopt(h, CURLOPT_WRITEDATA,      ud);
  curl_easy_setopt(h, CURLOPT_HEADERFUNCTION, murl_header_cb);
  curl_easy_setopt(h, CURLOPT_HEADERDATA,     ud);
  curl_easy_setopt(h, CURLOPT_NOSIGNAL,       1L);

  if (url) murl_easy_check(mrb, curl_easy_setopt(h, CURLOPT_URL, url));
  return self;
}

/* --- URL::Request#setopt ----------------------------------------------- */

static mrb_value
murl_req_setopt(mrb_state *mrb, mrb_value self)
{
  CURL *h = murl_req_get(mrb, self);

  mrb_sym   opt;
  mrb_value val;
  mrb_get_args(mrb, "no", &opt, &val);

  CURLcode rc = CURLE_OK;

  if      (opt == MRB_SYM(url))                rc = curl_easy_setopt(h, CURLOPT_URL,               mrb_string_cstr(mrb, val));
  else if (opt == MRB_SYM(custom_request))     rc = curl_easy_setopt(h, CURLOPT_CUSTOMREQUEST,     mrb_string_cstr(mrb, val));
  else if (opt == MRB_SYM(user_agent))         rc = curl_easy_setopt(h, CURLOPT_USERAGENT,         mrb_string_cstr(mrb, val));
  else if (opt == MRB_SYM(cainfo))             rc = curl_easy_setopt(h, CURLOPT_CAINFO,            mrb_string_cstr(mrb, val));
  else if (opt == MRB_SYM(accept_encoding))    rc = curl_easy_setopt(h, CURLOPT_ACCEPT_ENCODING,   mrb_string_cstr(mrb, val));
  else if (opt == MRB_SYM(userpwd))            rc = curl_easy_setopt(h, CURLOPT_USERPWD,           mrb_string_cstr(mrb, val));
  else if (opt == MRB_SYM(proxy))              rc = curl_easy_setopt(h, CURLOPT_PROXY,             mrb_string_cstr(mrb, val));
  else if (opt == MRB_SYM(cookiefile))         rc = curl_easy_setopt(h, CURLOPT_COOKIEFILE,        mrb_string_cstr(mrb, val));
  else if (opt == MRB_SYM(cookiejar))          rc = curl_easy_setopt(h, CURLOPT_COOKIEJAR,         mrb_string_cstr(mrb, val));
  else if (opt == MRB_SYM(follow_location))    rc = curl_easy_setopt(h, CURLOPT_FOLLOWLOCATION,    (long)mrb_bool(val));
  else if (opt == MRB_SYM(verbose))            rc = curl_easy_setopt(h, CURLOPT_VERBOSE,           (long)mrb_bool(val));
  else if (opt == MRB_SYM(connect_only))       rc = curl_easy_setopt(h, CURLOPT_CONNECT_ONLY,      (long)mrb_as_int(mrb, val));
  else if (opt == MRB_SYM(timeout_ms))         rc = curl_easy_setopt(h, CURLOPT_TIMEOUT_MS,        (long)mrb_as_int(mrb, val));
  else if (opt == MRB_SYM(connect_timeout_ms)) rc = curl_easy_setopt(h, CURLOPT_CONNECTTIMEOUT_MS, (long)mrb_as_int(mrb, val));
  else if (opt == MRB_SYM(ssl_verify_peer))    rc = curl_easy_setopt(h, CURLOPT_SSL_VERIFYPEER,    (long)mrb_bool(val));
  else if (opt == MRB_SYM(ssl_verify_host))    rc = curl_easy_setopt(h, CURLOPT_SSL_VERIFYHOST,    mrb_bool(val) ? 2L : 0L);
  else if (opt == MRB_SYM(max_redirs))         rc = curl_easy_setopt(h, CURLOPT_MAXREDIRS,         (long)mrb_as_int(mrb, val));
  else if (opt == MRB_SYM(nobody))             rc = curl_easy_setopt(h, CURLOPT_NOBODY,            (long)mrb_bool(val));
  else if (opt == MRB_SYM(post_fields)) {
    mrb_value s = mrb_str_to_str(mrb, val);
    curl_easy_setopt(h, CURLOPT_POSTFIELDSIZE_LARGE, (curl_off_t)RSTRING_LEN(s));
    rc = curl_easy_setopt(h, CURLOPT_COPYPOSTFIELDS, RSTRING_PTR(s));
  }
  else {
    mrb_raisef(mrb, E_ARGUMENT_ERROR, "unsupported option: :%n", opt);
  }

  murl_easy_check(mrb, rc);
  return self;
}

/* --- URL::Request#headers = -------------------------------------------- */

static int
murl_headers_each(mrb_state *mrb, mrb_value key, mrb_value val, void *data)
{
  murl_req_ud_t *ud = (murl_req_ud_t*)data;

  mrb_value ks = mrb_symbol_p(key) ? mrb_sym_str(mrb, mrb_symbol(key))
                                   : mrb_obj_as_string(mrb, key);
  mrb_value vs = mrb_obj_as_string(mrb, val);

  mrb_value line = mrb_str_new_capa(mrb, RSTRING_LEN(ks) + RSTRING_LEN(vs) + 2);
  mrb_str_concat (mrb, line, ks);
  mrb_str_cat_lit(mrb, line, ": ");
  mrb_str_concat (mrb, line, vs);

  struct curl_slist *next = curl_slist_append(ud->req_headers, mrb_string_cstr(mrb, line));
  if (unlikely(!next)) mrb_raise(mrb, E_RUNTIME_ERROR, "curl_slist_append failed");
  ud->req_headers = next;
  return 0;
}

static mrb_value
murl_req_headers_set(mrb_state *mrb, mrb_value self)
{
  CURL *h = murl_req_get(mrb, self);
  murl_req_ud_t *ud = murl_req_ud_of(mrb, self);

  mrb_value hash;
  mrb_get_args(mrb, "H", &hash);

  if (ud->req_headers) {
    curl_slist_free_all(ud->req_headers);
    ud->req_headers = NULL;
  }
  mrb_hash_foreach(mrb, mrb_hash_ptr(hash), murl_headers_each, ud);

  murl_easy_check(mrb, curl_easy_setopt(h, CURLOPT_HTTPHEADER, ud->req_headers));
  return self;
}

/* --- URL::Request getinfo ---------------------------------------------- */

static mrb_value
murl_req_response_code(mrb_state *mrb, mrb_value self)
{
  CURL *h = murl_req_get(mrb, self);
  long code = 0;
  murl_easy_check(mrb, curl_easy_getinfo(h, CURLINFO_RESPONSE_CODE, &code));
  return mrb_int_value(mrb, (mrb_int)code);
}

static mrb_value
murl_req_effective_url(mrb_state *mrb, mrb_value self)
{
  CURL *h = murl_req_get(mrb, self);
  const char *url = NULL;
  murl_easy_check(mrb, curl_easy_getinfo(h, CURLINFO_EFFECTIVE_URL, &url));
  return url ? mrb_str_new_cstr(mrb, url) : mrb_nil_value();
}

static mrb_value
murl_req_total_time(mrb_state *mrb, mrb_value self)
{
  CURL *h = murl_req_get(mrb, self);
  curl_off_t us = 0;
  murl_easy_check(mrb, curl_easy_getinfo(h, CURLINFO_TOTAL_TIME_T, &us));
  return mrb_float_value(mrb, (mrb_float)us / 1e6);
}

static mrb_value
murl_req_content_type(mrb_state *mrb, mrb_value self)
{
  CURL *h = murl_req_get(mrb, self);
  const char *ct = NULL;
  murl_easy_check(mrb, curl_easy_getinfo(h, CURLINFO_CONTENT_TYPE, &ct));
  return ct ? mrb_str_new_cstr(mrb, ct) : mrb_nil_value();
}

static mrb_value
murl_req_strerror_s(mrb_state *mrb, mrb_value self)
{
  (void)self;
  mrb_int code;
  mrb_get_args(mrb, "i", &code);
  const char *s = curl_easy_strerror((CURLcode)code);
  return s ? mrb_str_new_cstr(mrb, s) : mrb_nil_value();
}

/* ==========================================================================
 *  URL   - CDATA payload is CURLM*
 * ========================================================================== */

static void
murl_session_handle_free(mrb_state *mrb, void *p)
{
  (void)mrb;
  if (likely(p)) curl_multi_cleanup((CURLM*)p);
}

static const struct mrb_data_type murl_session_type = {
  "URL", murl_session_handle_free
};

static CURLM*
murl_session_get(mrb_state *mrb, mrb_value self)
{
  CURLM *h = (CURLM*)mrb_data_check_get_ptr(mrb, self, &murl_session_type);
  if (unlikely(!h)) mrb_raise(mrb, E_RUNTIME_ERROR, "URL session not open");
  return h;
}

static void
murl_session_check(mrb_state *mrb, CURLMcode rc)
{
  if (unlikely(mrb->exc != NULL)) mrb_exc_raise(mrb, mrb_obj_value(mrb->exc));
  if (likely(rc == CURLM_OK)) return;
  mrb_raisef(mrb, E_RUNTIME_ERROR, "curl_multi error: %s", curl_multi_strerror(rc));
}

/* ==========================================================================
 *  URL::Userdata
 * ========================================================================== */

typedef struct murl_session_ud_t {
  mrb_state *mrb;
  mrb_value  session;
} murl_session_ud_t;

static void
murl_session_ud_free(mrb_state *mrb, void *p)
{
  if (likely(p)) mrb_free(mrb, p);
}

static const struct mrb_data_type murl_session_ud_type = {
  "URL::Userdata", murl_session_ud_free
};

/* --- socket / timer trampolines ---------------------------------------- *
 *
 * Dispatch to the session's event_loop object as method calls:
 *   loop.on_socket(fd, what)
 *   loop.on_timer(ms)
 *
 * The event_loop is set via URL#event_loop= (mrblib). When unset, the
 * trampolines no-op so libcurl doesn't see callback failures while the
 * user is still wiring things up.
 */

typedef struct method_call_args {
  mrb_value receiver;
  mrb_sym   method;
  mrb_int   argc;
  mrb_value argv[2];
} method_call_args;

static mrb_value
method_call_body(mrb_state *mrb, void *data)
{
  method_call_args *a = (method_call_args*)data;
  return mrb_funcall_argv(mrb, a->receiver, a->method, a->argc, a->argv);
}

static int
murl_socket_cb(CURL *easy, curl_socket_t s, int what, void *userp, void *socketp)
{
  (void)easy; (void)socketp;
  murl_session_ud_t *ud = (murl_session_ud_t*)userp;
  mrb_state *mrb = ud->mrb;

  mrb_value loop = mrb_iv_get(mrb, ud->session, MRB_IVSYM(event_loop));
  if (mrb_nil_p(loop)) return 0;

  mrb_sym what_sym;
  switch (what) {
    case CURL_POLL_IN:     what_sym = MRB_SYM(in);     break;
    case CURL_POLL_OUT:    what_sym = MRB_SYM(out);    break;
    case CURL_POLL_INOUT:  what_sym = MRB_SYM(inout);  break;
    case CURL_POLL_REMOVE: what_sym = MRB_SYM(remove); break;
    default: return 0;
  }
  mrb_int ai = mrb_gc_arena_save(mrb);

  mrb_value io_object = mrb_funcall_id(mrb, mrb_obj_value(mrb_class_get_id(mrb, MRB_SYM(IO))), MRB_SYM(for_fd), 1, mrb_int_value(mrb, s));
  (void)mrb_io_fileno(mrb, io_object);
  ((struct mrb_io *)DATA_PTR(io_object))->close_fd = 0;
  method_call_args a;
  a.receiver = loop;
  a.method   = MRB_SYM(on_socket);
  a.argc     = 2;
  a.argv[0]  = io_object;
  a.argv[1]  = mrb_symbol_value(what_sym);

  mrb_bool err = FALSE;
  mrb_value ret = mrb_protect_error(mrb, method_call_body, &a, &err);
  mrb_gc_arena_restore(mrb, ai);

  if (unlikely(err)) {
    if (mrb->exc == NULL) mrb->exc = mrb_obj_ptr(ret);
    return -1;
  }
  return 0;
}

static int
murl_timer_cb(CURLM *multi, long timeout_ms, void *userp)
{
  (void)multi;
  murl_session_ud_t *ud = (murl_session_ud_t*)userp;
  mrb_state *mrb = ud->mrb;

  mrb_value loop = mrb_iv_get(mrb, ud->session, MRB_IVSYM(event_loop));
  if (mrb_nil_p(loop)) return 0;

  mrb_int ai = mrb_gc_arena_save(mrb);
  method_call_args a;
  a.receiver = loop;
  a.method   = MRB_SYM(on_timer);
  a.argc     = 1;
  a.argv[0]  = mrb_convert_long(mrb, timeout_ms);

  mrb_bool err = FALSE;
  mrb_value ret = mrb_protect_error(mrb, method_call_body, &a, &err);
  mrb_gc_arena_restore(mrb, ai);

  if (unlikely(err)) {
    if (mrb->exc == NULL) mrb->exc = mrb_obj_ptr(ret);
    return -1;
  }
  return 0;
}

/* --- URL.open ---------------------------------------------------------- */

static mrb_value
murl_session_open(mrb_state *mrb, mrb_value cls)
{
  CURLM *h = curl_multi_init();
  if (unlikely(!h)) mrb_raise(mrb, E_RUNTIME_ERROR, "curl_multi_init failed");

  mrb_value self = mrb_obj_value(
    mrb_data_object_alloc(mrb, mrb_class_ptr(cls), h, &murl_session_type));

  struct RClass *ud_cls = mrb_class_get_under_id(mrb, mrb_class_ptr(cls), MRB_SYM(Userdata));
  murl_session_ud_t *ud;
  struct RData      *ud_d;
  Data_Make_Struct(mrb, ud_cls, murl_session_ud_t, &murl_session_ud_type, ud, ud_d);
  ud->mrb     = mrb;
  ud->session = self;
  mrb_iv_set(mrb, self, MRB_IVSYM(userdata), mrb_obj_value(ud_d));

  curl_multi_setopt(h, CURLMOPT_SOCKETFUNCTION, murl_socket_cb);
  curl_multi_setopt(h, CURLMOPT_SOCKETDATA,     ud);
  curl_multi_setopt(h, CURLMOPT_TIMERFUNCTION,  murl_timer_cb);
  curl_multi_setopt(h, CURLMOPT_TIMERDATA,      ud);

  /* @handles keeps attached Request objects alive while libcurl owns them. */
  mrb_iv_set(mrb, self, MRB_IVSYM(handles), mrb_hash_new(mrb));
  return self;
}

/* --- URL#setopt -------------------------------------------------------- */

static mrb_value
murl_session_setopt(mrb_state *mrb, mrb_value self)
{
  CURLM *h = murl_session_get(mrb, self);

  mrb_sym   opt;
  mrb_value val;
  mrb_get_args(mrb, "no", &opt, &val);

  CURLMcode rc = CURLM_OK;

  if      (opt == MRB_SYM(pipelining))             rc = curl_multi_setopt(h, CURLMOPT_PIPELINING,             (long)mrb_as_int(mrb, val));
  else if (opt == MRB_SYM(maxconnects))            rc = curl_multi_setopt(h, CURLMOPT_MAXCONNECTS,            (long)mrb_as_int(mrb, val));
  else if (opt == MRB_SYM(max_host_connections))   rc = curl_multi_setopt(h, CURLMOPT_MAX_HOST_CONNECTIONS,   (long)mrb_as_int(mrb, val));
  else if (opt == MRB_SYM(max_total_connections))  rc = curl_multi_setopt(h, CURLMOPT_MAX_TOTAL_CONNECTIONS,  (long)mrb_as_int(mrb, val));
  else if (opt == MRB_SYM(max_concurrent_streams)) rc = curl_multi_setopt(h, CURLMOPT_MAX_CONCURRENT_STREAMS, (long)mrb_as_int(mrb, val));
  else {
    mrb_raisef(mrb, E_ARGUMENT_ERROR, "unsupported option: :%n", opt);
  }

  murl_session_check(mrb, rc);
  return self;
}

/* --- add / remove ------------------------------------------------------ */

static mrb_value
murl_session_add(mrb_state *mrb, mrb_value self)
{
  CURLM *m = murl_session_get(mrb, self);

  mrb_value req;
  mrb_get_args(mrb, "o", &req);

  CURL *e = (CURL*)mrb_data_check_get_ptr(mrb, req, &murl_req_type);
  if (unlikely(!e)) mrb_raise(mrb, E_TYPE_ERROR, "expected URL::Request");

  murl_session_check(mrb, curl_multi_add_handle(m, e));

  mrb_value handles = mrb_iv_get(mrb, self, MRB_IVSYM(handles));
  mrb_hash_set(mrb, handles, mrb_int_value(mrb, mrb_obj_id(req)), req);
  return self;
}

static mrb_value
murl_session_remove(mrb_state *mrb, mrb_value self)
{
  CURLM *m = murl_session_get(mrb, self);

  mrb_value req;
  mrb_get_args(mrb, "o", &req);

  CURL *e = (CURL*)mrb_data_check_get_ptr(mrb, req, &murl_req_type);
  if (unlikely(!e)) mrb_raise(mrb, E_TYPE_ERROR, "expected URL::Request");

  murl_session_check(mrb, curl_multi_remove_handle(m, e));

  mrb_value handles = mrb_iv_get(mrb, self, MRB_IVSYM(handles));
  mrb_hash_delete_key(mrb, handles, mrb_int_value(mrb, mrb_obj_id(req)));
  return self;
}

/* --- socket_action / info_read ----------------------------------------- */

static mrb_value
murl_session_socket_action(mrb_state *mrb, mrb_value self)
{
  CURLM *m = murl_session_get(mrb, self);

  mrb_value fd_obj = mrb_undef_value();
  mrb_int fd = (mrb_int)CURL_SOCKET_TIMEOUT;
  mrb_sym ev_sym = 0;
  mrb_get_args(mrb, "|on", &fd_obj, &ev_sym);

  if (!mrb_undef_p(fd_obj)) {
    fd = mrb_integer(mrb_type_convert(mrb, fd_obj, MRB_TT_INTEGER, MRB_SYM(fileno)));
  }

  int ev_bitmask;
  if      (ev_sym == 0)              ev_bitmask = 0;
  else if (ev_sym == MRB_SYM(in))    ev_bitmask = CURL_CSELECT_IN;
  else if (ev_sym == MRB_SYM(out))   ev_bitmask = CURL_CSELECT_OUT;
  else if (ev_sym == MRB_SYM(inout)) ev_bitmask = CURL_CSELECT_IN | CURL_CSELECT_OUT;
  else if (ev_sym == MRB_SYM(err))   ev_bitmask = CURL_CSELECT_ERR;
  else { mrb_raisef(mrb, E_ARGUMENT_ERROR, "unknown event: :%n", ev_sym); return self; }

  int running = 0;
  murl_session_check(mrb,
    curl_multi_socket_action(m, (curl_socket_t)fd, ev_bitmask, &running));
  return mrb_convert_int(mrb, running);
}

static mrb_value
murl_session_info_read(mrb_state *mrb, mrb_value self)
{
  CURLM *m = murl_session_get(mrb, self);

  mrb_value block = mrb_undef_value();
  mrb_get_args(mrb, "&", &block);

  mrb_bool has_block = mrb_proc_p(block);
  mrb_value arr = has_block ? mrb_nil_value() : mrb_ary_new(mrb);

  int remaining = 0;
  const CURLMsg *msg;
  while ((msg = curl_multi_info_read(m, &remaining)) != NULL) {
    if (msg->msg != CURLMSG_DONE) continue;

    murl_req_ud_t *ud = NULL;
    curl_easy_getinfo(msg->easy_handle, CURLINFO_PRIVATE, &ud);
    if (unlikely(!ud)) continue;

    mrb_int ai = mrb_gc_arena_save(mrb);
    mrb_value req_v = ud->request;
    mrb_value result = mrb_int_value(mrb, (mrb_int)msg->data.result);

    if (has_block) {
      mrb_value args[2];
      args[0] = req_v;
      args[1] = result;
      mrb_yield_argv(mrb, block, 2, args);
    } else {
      mrb_value pair = mrb_ary_new_capa(mrb, 2);
      mrb_ary_push(mrb, pair, req_v);
      mrb_ary_push(mrb, pair, result);
      mrb_ary_push(mrb, arr, pair);
    }
    mrb_gc_arena_restore(mrb, ai);
  }
  return has_block ? self : arr;
}

static mrb_value
murl_session_strerror_s(mrb_state *mrb, mrb_value self)
{
  (void)self;
  mrb_int code;
  mrb_get_args(mrb, "i", &code);
  const char *s = curl_multi_strerror((CURLMcode)code);
  return s ? mrb_str_new_cstr(mrb, s) : mrb_nil_value();
}

/* ==========================================================================
 *  Gem entry points
 * ========================================================================== */

void
mrb_mruby_url_gem_init(mrb_state *mrb)
{
  curl_global_init(CURL_GLOBAL_DEFAULT);

  /* URL --------------------------------------------------------------- */
  struct RClass *url_cls = mrb_define_class_id(mrb, MRB_SYM(URL), mrb->object_class);
  MRB_SET_INSTANCE_TT(url_cls, MRB_TT_CDATA);
  mrb_undef_method_id       (mrb, url_cls, MRB_SYM(initialize));
  mrb_define_class_method_id(mrb, url_cls, MRB_SYM(open),           murl_session_open,           MRB_ARGS_NONE());
  mrb_define_class_method_id(mrb, url_cls, MRB_SYM(strerror),       murl_session_strerror_s,     MRB_ARGS_REQ(1));
  mrb_define_method_id      (mrb, url_cls, MRB_SYM(setopt),         murl_session_setopt,         MRB_ARGS_REQ(2));
  mrb_define_method_id      (mrb, url_cls, MRB_SYM(add),            murl_session_add,            MRB_ARGS_REQ(1));
  mrb_define_method_id      (mrb, url_cls, MRB_SYM(remove),         murl_session_remove,         MRB_ARGS_REQ(1));
  mrb_define_method_id      (mrb, url_cls, MRB_SYM(socket_action),  murl_session_socket_action,  MRB_ARGS_OPT(2));
  mrb_define_method_id      (mrb, url_cls, MRB_SYM(info_read),      murl_session_info_read,      MRB_ARGS_BLOCK());
  mrb_define_const_id       (mrb, url_cls, MRB_SYM(SOCKET_TIMEOUT), mrb_convert_int(mrb, CURL_SOCKET_TIMEOUT));

  /* URL::Userdata - internal CDATA companion. */
  struct RClass *url_ud_cls = mrb_define_class_under_id(mrb, url_cls, MRB_SYM(Userdata), mrb->object_class);
  MRB_SET_INSTANCE_TT(url_ud_cls, MRB_TT_CDATA);
  mrb_undef_method_id(mrb, url_ud_cls, MRB_SYM(initialize));

  /* URL::Request ------------------------------------------------------ */
  struct RClass *req_cls = mrb_define_class_under_id(mrb, url_cls, MRB_SYM(Request), mrb->object_class);
  MRB_SET_INSTANCE_TT(req_cls, MRB_TT_CDATA);
  mrb_undef_method_id       (mrb, req_cls, MRB_SYM(initialize));
  mrb_define_class_method_id(mrb, req_cls, MRB_SYM(_open),          murl_req_open,             MRB_ARGS_OPT(1));
  mrb_define_class_method_id(mrb, req_cls, MRB_SYM(strerror),       murl_req_strerror_s,       MRB_ARGS_REQ(1));
  mrb_define_method_id      (mrb, req_cls, MRB_SYM(setopt),         murl_req_setopt,           MRB_ARGS_REQ(2));
  mrb_define_method_id      (mrb, req_cls, MRB_SYM_E(headers),      murl_req_headers_set,      MRB_ARGS_REQ(1));
  mrb_define_method_id      (mrb, req_cls, MRB_SYM(response_code),  murl_req_response_code,    MRB_ARGS_NONE());
  mrb_define_method_id      (mrb, req_cls, MRB_SYM(effective_url),  murl_req_effective_url,    MRB_ARGS_NONE());
  mrb_define_method_id      (mrb, req_cls, MRB_SYM(total_time),     murl_req_total_time,       MRB_ARGS_NONE());
  mrb_define_method_id      (mrb, req_cls, MRB_SYM(content_type),   murl_req_content_type,     MRB_ARGS_NONE());

  /* URL::Request::Userdata */
  struct RClass *req_ud_cls = mrb_define_class_under_id(mrb, req_cls, MRB_SYM(Userdata), mrb->object_class);
  MRB_SET_INSTANCE_TT(req_ud_cls, MRB_TT_CDATA);
  mrb_undef_method_id(mrb, req_ud_cls, MRB_SYM(initialize));
}

void
mrb_mruby_url_gem_final(mrb_state *mrb)
{
  (void)mrb;
  curl_global_cleanup();
}
