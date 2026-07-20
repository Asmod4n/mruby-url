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
**   - opensocket callback on an Easy: a thin trampoline that reads
**     @on_open_socket off the Easy, hands it the resolved sockaddr as raw
**     bytes, and either creates the socket (truthy) or refuses it with
**     CURL_SOCKET_BAD (falsy/unset/exception) — libcurl never opens a
**     connection to an address this callback didn't approve.
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
#include <mruby/string_is_utf8.h>

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
#ifndef _WIN32
#include <dlfcn.h>
#include <sys/socket.h>
#endif

/* libcurl grew the WebSocket framing API (curl_ws_send / curl_ws_recv, struct
 * curl_ws_frame, CURLWS_*) in 7.86.0. Whether it is actually THERE is a
 * question about the libcurl we end up linked against at runtime, not about
 * the curl.h we happened to compile this file against — those can differ
 * (e.g. a build stage with newer -dev headers than a slimmer runtime image),
 * and libcurl's own ABI policy only promises safety upgrading, not
 * downgrading (see https://curl.se/libcurl/abi.html). So this gem never
 * infers availability from a header version macro: murl_globals_init (below)
 * resolves curl_ws_recv/curl_ws_send by name from whatever is actually loaded,
 * once, at startup, and every call site checks that result — never a
 * compile-time guess.
 *
 * This block ONLY exists so the two functions below still compile against an
 * old curl.h that doesn't declare any of this — when curl.h is new enough it
 * already defines CURLINC_WEBSOCKETS_H, so nothing here is redeclared. */
#ifndef CURLINC_WEBSOCKETS_H
struct curl_ws_frame {
  int        age;
  int        flags;
  curl_off_t offset;
  curl_off_t bytesleft;
  size_t     len;
};
#define CURLWS_TEXT   (1 << 0)
#define CURLWS_BINARY (1 << 1)
#define CURLWS_CONT   (1 << 2)
#define CURLWS_CLOSE  (1 << 3)
#define CURLWS_PING   (1 << 4)
#define CURLWS_OFFSET (1 << 5)
#define CURLWS_PONG   (1 << 6)
#endif

typedef CURLcode (*murl_ws_recv_fn)(CURL*, void*, size_t, size_t*,
                                    const struct curl_ws_frame**);
typedef CURLcode (*murl_ws_send_fn)(CURL*, const void*, size_t, size_t*,
                                    curl_off_t, unsigned int);

/* curl_mime_init/free/addpart/name/filename/type/data/filedata and
 * CURLOPT_MIMEPOST were added in 7.56.0, replacing the older curl_formadd/
 * curl_formfree API (deprecated by curl itself, and not used here — same
 * "gracefully unavailable rather than reimplement against a deprecated API"
 * choice as WebSockets above, resolved the same way: by name, at runtime,
 * in murl_globals_init, never assumed from a header version.
 *
 * curl_mime/curl_mimepart themselves are opaque struct typedefs declared
 * directly in curl.h (no separate header with its own include guard the way
 * websockets.h has one), so an old curl.h simply won't have them at all —
 * this fallback exists so the rest of the file (which already spells out
 * both pointer types throughout, not just in the code below) still
 * compiles. */
#if LIBCURL_VERSION_NUM < 0x073800
typedef struct curl_mime      curl_mime;
typedef struct curl_mimepart  curl_mimepart;
#endif

typedef curl_mime*    (*murl_mime_init_fn)(CURL*);
typedef void           (*murl_mime_free_fn)(curl_mime*);
typedef curl_mimepart* (*murl_mime_addpart_fn)(curl_mime*);
typedef CURLcode        (*murl_mime_name_fn)(curl_mimepart*, const char*);
typedef CURLcode        (*murl_mime_filename_fn)(curl_mimepart*, const char*);
typedef CURLcode        (*murl_mime_type_fn)(curl_mimepart*, const char*);
typedef CURLcode        (*murl_mime_data_fn)(curl_mimepart*, const char*, size_t);
typedef CURLcode        (*murl_mime_filedata_fn)(curl_mimepart*, const char*);

/* Resolved once, process-wide, in murl_globals_init (below the Easy/Mime
 * sections that use them — the mrbgem callback trampolines and mime
 * functions are defined early in the file, so these declarations have to be
 * here, near their types, not down by the call_once machinery they're
 * filled in by). All 8 or none: mime_new checks every one of these before
 * building a Mime, so nothing downstream (addpart, the field setters) ever
 * runs with a partially-resolved set. */
static murl_mime_init_fn     g_mime_init     = NULL;
static murl_mime_free_fn     g_mime_free     = NULL;
static murl_mime_addpart_fn  g_mime_addpart  = NULL;
static murl_mime_name_fn     g_mime_name     = NULL;
static murl_mime_filename_fn g_mime_filename = NULL;
static murl_mime_type_fn     g_mime_type     = NULL;
static murl_mime_data_fn     g_mime_data     = NULL;
static murl_mime_filedata_fn g_mime_filedata = NULL;

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
  if (p) g_mime_free((curl_mime*)p);
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
  /* All 8 resolve together or not at all (murl_globals_init) — checking
   * g_mime_init here is enough to guarantee every g_mime_* used downstream
   * (addpart, the field setters, and this Mime's eventual g_mime_free) is
   * also non-NULL, since none of those are reachable without a Mime that
   * only this function can create. */
  if (unlikely(!g_mime_init))
    mrb_raise(mrb, E_NOTIMP_ERROR, "the loaded libcurl has no multipart/mime support (needs 7.56.0+)");

  mrb_value easy_obj;
  mrb_get_args(mrb, "o", &easy_obj);
  murl_easy_t* e = murl_easy_get(mrb, easy_obj);

  curl_mime* m = g_mime_init(e->curl);
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

  curl_mimepart* p = g_mime_addpart(m);
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
  murl_mime_check(mrb, g_mime_name(murl_part_get(mrb, part_obj),
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
  murl_mime_check(mrb, g_mime_data(murl_part_get(mrb, part_obj),
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
  murl_mime_check(mrb, g_mime_filedata(murl_part_get(mrb, part_obj),
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
  murl_mime_check(mrb, g_mime_type(murl_part_get(mrb, part_obj),
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
  murl_mime_check(mrb, g_mime_filename(murl_part_get(mrb, part_obj),
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
 * Per-OS-thread connection/TLS share (CURLSH in thread-local storage)
 *
 * One CURLSH per OS thread, created lazily on the first easy_init that runs on
 * the thread and held in C11 thread-specific storage (tss_t). Every easy made
 * on the thread attaches via CURLOPT_SHARE, so every session — and every
 * mrb_state that runs on this OS thread — reuses the one connection cache and
 * TLS session-ticket cache. Users can spawn several mrb_state on a single OS
 * thread; binding the share to the thread instead of the VM lets those VMs
 * share one warm pool, while a request fired from inside a callback (running on
 * a throwaway session because the shared multi is busy) still reuses the live
 * connection / TLS ticket.
 *
 * Still no lock callbacks: a thread-local CURLSH is only ever touched by its
 * owning OS thread, which runs one VM at a time, so access is serialised by
 * construction. curl_share.c uses `if(share->lockfunc)` and skips locking when
 * unset — the cheap documented no-op.
 *
 * REQUIRED of the caller: a VM and the easy/multi handles created on it must
 * stay on the OS thread that created them. An mrb_state may not be driven from
 * a different OS thread than the one its share was created on — that would touch
 * an unsynchronised CURLSH from two threads (there are no lock callbacks) and is
 * undefined. (This is the same single-owning-thread rule mruby itself imposes on
 * an mrb_state.) Likewise libcurl is not fork-safe: do not fork() after a
 * transfer has run and then use libcurl in the child; the inherited share/easies
 * reference the parent's sockets. Neither is enforced in C.
 *
 * Lifetime. curl_global_init must outlive every holder, of which there are two
 * kinds: live VMs (gem_init/gem_final) and live thread-shares. g_refs counts
 * both; the global layer comes up on the first holder and tears down after the
 * last. A thread's share is drained in gem_final when its LAST VM closes (by
 * then every easy on the thread is curl_easy_cleanup'd and detached, so
 * curl_share_cleanup succeeds and g_refs reaches its 1->0 transition
 * deterministically — no atexit, which is unsafe from a dlclose'able module, and
 * no reliance on the main thread's tss destructor, which POSIX/C11 do not run at
 * exit()/return-from-main). The tss destructor is the fallback for a thread that
 * exits WITHOUT finalizing its VM: it gets CURLSHE_IN_USE (an easy still
 * attached), so the share is left and its global ref is NOT released — keeping
 * the global layer up rather than tearing it down under a live handle (the share
 * leaks, the same tolerance as a leaked easy).
 *
 * LOCK_DATA enabled: CONNECT (keep-alive + HTTP/2/3 pool) and SSL_SESSION (TLS
 * resumption). Skipped: DNS/PSL (auto-shared at multi level), COOKIE/HSTS (set
 * per-easy; libcurl docs say not shareable across threads).
 *
 * No <threads.h> on some toolchains (Apple's, C99-only): src/compat/threads.h
 * shims the tss, mtx and call_once subset onto POSIX; how it is included is
 * unchanged.
 * ========================================================================= */

static once_flag g_once = ONCE_FLAG_INIT;
static mtx_t     g_lock;              /* mtx_t has NO static initializer in C11 */
static unsigned  g_refs = 0;          /* live holders: VMs + thread-shares */
static tss_t     g_share_key;         /* thread-local CURLSH* */
static int       g_share_key_ok = 0;  /* tss_create succeeded */

/* Resolved once, process-wide, in murl_globals_init below — NULL when the
 * loaded libcurl doesn't actually have the WebSocket API. Never assumed from
 * a header version; see the comment on the declarations near the top of the
 * file. */
static murl_ws_recv_fn g_ws_recv = NULL;
static murl_ws_send_fn g_ws_send = NULL;

/* VMs currently alive on THIS OS thread. gem_init bumps it, gem_final drops it,
 * and the thread's share is drained when it falls to zero — so the share lives
 * exactly as long as some VM on the thread can use it, and its teardown is
 * deterministic (no atexit, which is unsafe from a dlclose'able module, and no
 * dependence on the main thread's tss destructor, which POSIX/C11 do not run at
 * exit()/return-from-main). _Thread_local is a C11 keyword, available without
 * <threads.h>. */
static _Thread_local unsigned t_vm_count = 0;

static void murl_share_dtor(void* p);  /* fwd: tss destructor, defined below */

#ifndef MURL_CURL_STATIC
/* "ws" (case-insensitive, exactly 2 chars) — matches how curl_version_info's
 * ->protocols array names the WebSocket protocol. Hand-rolled instead of
 * strcasecmp so this file pulls in no extra header for two characters. Only
 * the dlsym path (below) calls this — guarded the same way that path is,
 * not by platform, since that's the actual reason it exists. */
static int
murl_is_ws_protocol(const char* p)
{
  return (p[0] == 'w' || p[0] == 'W') && (p[1] == 's' || p[1] == 'S') && p[2] == '\0';
}
#endif

/* call_once target: build the mutex (mtx_t has no static initializer), the
 * tss key, and resolve the WebSocket and mime functions from whatever
 * libcurl this process actually has loaded. If tss_create fails the gem
 * still works — easies just run shareless.
 *
 * On non-Windows, "actually has loaded" is asked two ways, not one:
 *   1. curl_version_info()'s ->protocols list is the gate — the same signal
 *      URL::PROTOS is built from, so it already accounts for both curl's
 *      version AND any build-time feature toggle (a distro could ship a
 *      recent-enough curl with WebSockets explicitly compiled out via
 *      CURL_DISABLE_WEBSOCKETS despite a version number that would suggest
 *      otherwise — version_num alone can't see that, ->protocols can).
 *   2. dlsym(RTLD_DEFAULT, ...) is how the actual callable pointer is
 *      obtained — a name lookup against whatever is loaded, not a build-time
 *      link dependency, so this compiles and links the same regardless of
 *      what curl.h or libcurl the build machine happened to have.
 * g_ws_recv/g_ws_send are left NULL unless BOTH agree: the library claims WS
 * support AND the symbol actually resolves. Neither check alone is trusted.
 *
 * curl_version_info needs no libcurl call to have run first (curl_global_init
 * is brought up separately, by the first murl_global_ref caller) and, being
 * called from inside call_once, runs on exactly one thread ever, so there is
 * nothing here to race.
 *
 * MURL_CURL_STATIC (mrbgem.rake, set only where the build actually vendors
 * and statically links curl — Windows today) means there is nothing to ask:
 * curl_ws_recv/curl_ws_send are this translation unit's own linked-in
 * symbols, unconditionally present, since that build always forces
 * WebSockets on (see mrbgem.rake) — assigning their address directly is a
 * fact that build guarantees, not a version guess. This is keyed on the
 * actual linking mode rather than the platform: a statically-linked
 * curl_ws_recv would never be dlsym(RTLD_DEFAULT, ...)-visible either (it
 * was never a shared library's own exported dynamic symbol), so the
 * dlsym path below is only ever correct against a genuinely dynamic libcurl
 * — which is what MURL_CURL_STATIC being undefined actually promises. */
static void
murl_globals_init(void)
{
  mtx_init(&g_lock, mtx_plain);
  g_share_key_ok = (tss_create(&g_share_key, murl_share_dtor) == thrd_success);

#ifdef MURL_CURL_STATIC
  g_ws_recv = curl_ws_recv;
  g_ws_send = curl_ws_send;
  g_mime_init     = curl_mime_init;
  g_mime_free     = curl_mime_free;
  g_mime_addpart  = curl_mime_addpart;
  g_mime_name     = curl_mime_name;
  g_mime_filename = curl_mime_filename;
  g_mime_type     = curl_mime_type;
  g_mime_data     = curl_mime_data;
  g_mime_filedata = curl_mime_filedata;
#else
  curl_version_info_data* vi = curl_version_info(CURLVERSION_NOW);
  int lib_claims_ws = 0;
  if (vi && vi->protocols) {
    for (const char* const* p = vi->protocols; *p != NULL; p++) {
      if (murl_is_ws_protocol(*p)) { lib_claims_ws = 1; break; }
    }
  }
  if (lib_claims_ws) {
    g_ws_recv = (murl_ws_recv_fn)dlsym(RTLD_DEFAULT, "curl_ws_recv");
    g_ws_send = (murl_ws_send_fn)dlsym(RTLD_DEFAULT, "curl_ws_send");
  }

  /* Mime has no protocols-list equivalent to gate on (it isn't a scheme),
   * so the version curl_version_info() itself reports is the best available
   * pre-check — still paired with dlsym as the actual resolution mechanism,
   * same "neither signal alone is trusted" rule as WS above. */
  if (vi && vi->version_num >= 0x073800) {
    g_mime_init     = (murl_mime_init_fn)dlsym(RTLD_DEFAULT, "curl_mime_init");
    g_mime_free     = (murl_mime_free_fn)dlsym(RTLD_DEFAULT, "curl_mime_free");
    g_mime_addpart  = (murl_mime_addpart_fn)dlsym(RTLD_DEFAULT, "curl_mime_addpart");
    g_mime_name     = (murl_mime_name_fn)dlsym(RTLD_DEFAULT, "curl_mime_name");
    g_mime_filename = (murl_mime_filename_fn)dlsym(RTLD_DEFAULT, "curl_mime_filename");
    g_mime_type     = (murl_mime_type_fn)dlsym(RTLD_DEFAULT, "curl_mime_type");
    g_mime_data     = (murl_mime_data_fn)dlsym(RTLD_DEFAULT, "curl_mime_data");
    g_mime_filedata = (murl_mime_filedata_fn)dlsym(RTLD_DEFAULT, "curl_mime_filedata");
  }
#endif
}

/* Bring curl_global_init up on the first holder and tear it down after the
 * last. Both VM init/final and thread-share create/destroy go through here,
 * serialised by the one mutex. Returns 0 if curl_global_init failed (the layer
 * is left DOWN and the count is NOT bumped, so no later cleanup is armed against
 * an unsuccessful init and no curl call is issued atop a dead library); 1
 * otherwise. */
static int
murl_global_ref(void)
{
  int ok = 1;
  mtx_lock(&g_lock);
  if (g_refs == 0) {
    if (curl_global_init(CURL_GLOBAL_DEFAULT) != CURLE_OK) ok = 0;
  }
  if (ok) g_refs++;
  mtx_unlock(&g_lock);
  return ok;
}

static void
murl_global_unref(void)
{
  mtx_lock(&g_lock);
  if (--g_refs == 0) curl_global_cleanup();
  mtx_unlock(&g_lock);
}

/* Destroy a thread's CURLSH and release the global ref it held. Runs from
 * murl_thread_share_drain (gem_final, the thread's last VM) and as the tss
 * destructor at thread exit (the fallback). The global ref is released ONLY when
 * curl_share_cleanup actually freed the share:
 * on CURLSHE_IN_USE (an easy still attached — reachable only if a VM was driven
 * from a different OS thread than the one that created its share, which is
 * unsupported) the CURLSH is left allocated, so keeping its global ref ensures
 * curl_global_cleanup can never run while a live share exists. The share is then
 * leaked, exactly as a leaked easy would be. */
static void
murl_share_dtor(void* p)
{
  CURLSH* sh = (CURLSH*)p;
  if (unlikely(!sh)) return;
  if (curl_share_cleanup(sh) == CURLSHE_OK) murl_global_unref();
}

/* Drain the calling thread's share now (clearing the tss slot so the destructor
 * later no-ops). Called from gem_final when the thread's last VM closes — by
 * then every easy on the thread has been curl_easy_cleanup'd and detached, so
 * curl_share_cleanup succeeds. */
static void
murl_thread_share_drain(void)
{
  CURLSH* sh = g_share_key_ok ? (CURLSH*)tss_get(g_share_key) : NULL;
  if (!sh) return;
  tss_set(g_share_key, NULL);
  murl_share_dtor(sh);
}

/* The calling OS thread's CURLSH, created on first use. Returns NULL (so
 * easy_init proceeds shareless) when TLS is unavailable or curl_share_init
 * fails. Always called with the global layer already up: an easy is only
 * created from within a live VM that holds a gem_init ref. */
static CURLSH*
murl_thread_share(void)
{
  if (unlikely(!g_share_key_ok)) return NULL;
  CURLSH* sh = (CURLSH*)tss_get(g_share_key);
  if (sh) return sh;

  sh = curl_share_init();
  if (unlikely(!sh)) return NULL;
  /* CONNECT + SSL_SESSION are the safe, useful single-thread caches; lock
   * callbacks intentionally unset. A setopt failure degrades to an unconfigured
   * share (attaches but reuses nothing) — acceptable, not fatal. */
  curl_share_setopt(sh, CURLSHOPT_SHARE, CURL_LOCK_DATA_CONNECT);
  curl_share_setopt(sh, CURLSHOPT_SHARE, CURL_LOCK_DATA_SSL_SESSION);

  if (unlikely(tss_set(g_share_key, sh) != thrd_success)) {
    curl_share_cleanup(sh);
    return NULL;
  }
  /* Keep the global layer up until this share is drained (gem_final on the
   * thread's last VM, or the tss destructor at thread exit). The ref cannot fail
   * here — the calling VM already holds one. */
  if (unlikely(!murl_global_ref())) {
    tss_set(g_share_key, NULL);
    curl_share_cleanup(sh);
    return NULL;
  }
  return sh;
}

/* =========================================================================
 * Error checks (single libcurl strerror call on failure)
 *
 * On the fast (success) path, a callback-stashed exception (mrb->exc) is
 * deliberately NOT checked: mruby's own cfunc epilogue raises it the instant
 * the enclosing cfunc returns to Ruby, before any further Ruby code runs —
 * see vm.c's "cfunc epilogue" (OP_SEND) and mrb_funcall_with_block's
 * direct-cfunc path, both of which do `if (mrb->exc) ... raise`
 * unconditionally after any cfunc call.
 *
 * murl_multi_check's failure path still prefers an already-pending
 * mrb->exc over its own generic error text: if libcurl reports a
 * multi-level failure while a more specific exception from a Ruby callback
 * is stashed, that exception — not the generic strerror — is what the
 * caller should see. (The socket/timer trampolines themselves always
 * return 0 to libcurl; returning -1 there marks the whole multi dead —
 * see the trampoline block below.)
 * ========================================================================= */

static void
murl_easy_check(mrb_state* mrb, CURLcode rc)
{
  if (likely(rc == CURLE_OK)) return;
  mrb_raisef(mrb, E_RUNTIME_ERROR, "curl_easy error: %s", curl_easy_strerror(rc));
}

static void
murl_multi_check(mrb_state* mrb, CURLMcode rc)
{
  if (likely(rc == CURLM_OK)) return;
  if (unlikely(mrb->exc != NULL)) mrb_exc_raise(mrb, mrb_obj_value(mrb->exc));
  mrb_raisef(mrb, E_RUNTIME_ERROR, "curl_multi error: %s", curl_multi_strerror(rc));
}

/* =========================================================================
 * murl_protect: mrb_protect_error, but safe to call more than once while an
 * earlier callback's exception is already stashed in mrb->exc.
 *
 * A single curl_multi_socket_action pass can invoke several of our
 * trampolines in sequence (e.g. the write callback aborts a transfer, and
 * libcurl's own connection teardown immediately fires the socket callback
 * with CURL_POLL_REMOVE). Every trampoline stashes its callback's raise into
 * mrb->exc so it can be delivered once we're back in a pure-Ruby frame — but
 * invoking ANY Ruby-defined proc (mrb_yield -> mrb_run -> mrb_vm_exec, for
 * anything that isn't a cfunc) unconditionally resets mrb->exc at its own
 * entry. A later, perfectly innocent, non-raising callback would otherwise
 * silently erase an earlier callback's already-stashed exception this way.
 * Snapshotting mrb->exc before the call and restoring it after (unless
 * nothing was pending) keeps "the first exception in this drive wins" true
 * regardless of what else libcurl invokes afterward. Same signature and
 * return value as mrb_protect_error — `*err` is whether mrb->exc holds
 * anything once this returns (this callback's own raise, or an earlier
 * callback's restored one), and the return value is the body's result on
 * success or the (possibly earlier, first-wins) exception on failure.
 * Callers no longer need their own "if (mrb->exc == NULL) mrb->exc = ..."
 * — mrb->exc is already exactly what it should be when this returns. */
static mrb_value
murl_protect(mrb_state* mrb, mrb_protect_error_func* body, void* data, mrb_bool* err)
{
  struct RObject* pending = mrb->exc;
  mrb_bool raised = FALSE;
  mrb_value ret = mrb_protect_error(mrb, body, data, &raised);
  if (pending) {
    mrb->exc = pending;             /* first exception in this drive wins */
    ret = mrb_obj_value(pending);
    raised = TRUE;
  } else if (raised) {
    mrb->exc = mrb_obj_ptr(ret);
  }
  *err = raised;
  return ret;
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
  murl_protect(mrb, call_with_str_body, &a, &err);
  mrb_gc_arena_restore(mrb, ai);

  if (unlikely(err)) return 0;
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
  mrb_value ret = murl_protect(mrb, call_read_body, &a, &err);

  if (unlikely(err)) {
    mrb_gc_arena_restore(mrb, ai);
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

/* opensocket callback: let @on_open_socket veto a resolved connect address
 * before libcurl ever opens a socket to it (CURLOPT_OPENSOCKETFUNCTION,
 * option 163, curl 7.17.1 — always registered below, no version guard
 * needed anywhere this gem supports).
 *
 * No block set -> reproduce libcurl's own default exactly: a plain socket()
 * on the resolved family/socktype/protocol. Verified against
 * deps/curl/lib/cf-socket.c's socket_open(): that is the literal fallback
 * libcurl itself uses when no opensocket callback is installed, and every
 * other adjustment (SO_NOSIGPIPE, the CLOEXEC fallback, IPv6 scope_id) is
 * applied by libcurl to the returned fd afterward regardless of which path
 * produced it — nothing else for this callback to replicate.
 *
 * Block set -> yield the resolved sockaddr as raw bytes plus purpose, create
 * the socket only if the block returns truthy. An exception is stashed like
 * every other callback here and surfaces once control returns to Ruby; the
 * candidate address is refused (CURL_SOCKET_BAD) in the meantime rather than
 * risk connecting through a policy that half-failed. */
typedef struct cb_opensocket_args {
  mrb_value cb;
  mrb_value sockaddr;
  mrb_sym   purpose;
} cb_opensocket_args;

static mrb_value
call_opensocket_body(mrb_state* mrb, void* data)
{
  cb_opensocket_args* a = (cb_opensocket_args*)data;
  mrb_value argv[2] = { a->sockaddr, mrb_symbol_value(a->purpose) };
  return mrb_yield_argv(mrb, a->cb, 2, argv);
}

static curl_socket_t
murl_opensocket_cb(void* clientp, curlsocktype purpose, struct curl_sockaddr* address)
{
  murl_easy_t* e   = (murl_easy_t*)clientp;
  mrb_state*   mrb = e->mrb;
  mrb_value    cb  = mrb_iv_get(mrb, e->self, MRB_IVSYM(on_open_socket));
  if (!mrb_proc_p(cb))
    return socket(address->family, address->socktype, address->protocol);

  mrb_sym psym = (purpose == CURLSOCKTYPE_ACCEPT) ? MRB_SYM(accept) : MRB_SYM(connect);

  int ai = mrb_gc_arena_save(mrb);
  mrb_value sockaddr = mrb_str_new(mrb, (const char*)&address->addr, address->addrlen);
  cb_opensocket_args a = { cb, sockaddr, psym };
  mrb_bool err = FALSE;
  mrb_value ret = murl_protect(mrb, call_opensocket_body, &a, &err);

  curl_socket_t fd = CURL_SOCKET_BAD;
  if (!err && mrb_test(ret))
    fd = socket(address->family, address->socktype, address->protocol);

  mrb_gc_arena_restore(mrb, ai);
  return fd;
}

/* =========================================================================
 * socket / timer callbacks: thin trampolines to the Multi's @on_socket /
 * @on_timer Ruby blocks, invoked under mrb_protect_error so nothing ever
 * longjmps through libcurl. A raise is stashed (murl_protect, first
 * exception wins) and surfaces from the cfunc epilogue the moment the
 * enclosing perform/socket_action returns to Ruby.
 *
 * These MUST return 0 even when an exception is stashed. Returning -1 from
 * a multi-level callback makes libcurl set multi->dead = TRUE — the WHOLE
 * multi is permanently poisoned, not just one transfer. A dead multi stops
 * all internal timer processing, which wedges every protocol whose state
 * machine advances on libcurl's own timers (FTP/SMTP/IMAP/...) while plain
 * HTTP happens to keep working on socket readiness alone — a nearly
 * invisible way to break only *some* later transfers (observed as every
 * non-HTTP transfer on the session timing out after a streaming block
 * raised mid-transfer; teardown fires these callbacks while the exception
 * is still pending).
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
  murl_protect(mrb, call_socket_body, &a, &err);
  mrb_gc_arena_restore(mrb, ai);

  (void)err;   /* stashed; raises at the perform epilogue — never -1 here */
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
  /* libcurl's -1 means "delete the timer" — marshal it as nil so no magic
   * integer crosses the boundary; anything else is a duration, handed over
   * through mruby-chrono (Float seconds; 0 becomes 0.0 = "fire now"). */
  mrb_value arg = a->ms < 0
    ? mrb_nil_value()
    : mrb_chrono_from(mrb, mrb_convert_long(mrb, a->ms), MRB_CHRONO_DUR_MILLISECONDS);
  return mrb_yield(mrb, a->cb, arg);
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
  murl_protect(mrb, call_timer_body, &a, &err);
  mrb_gc_arena_restore(mrb, ai);

  (void)err;   /* stashed; raises at the perform epilogue — never -1 here */
  return 0;
}

/* =========================================================================
 * easy_init -> Easy
 * ========================================================================= */

/* Point this easy's write/header/read callbacks at e (so the C trampolines read
 * the callback blocks off e->self) and attach the per-thread share. Shared by
 * easy_init and the duphandle path; detach is automatic on curl_easy_cleanup. */
static void
murl_easy_wire(murl_easy_t* e)
{
  CURL* h = e->curl;
  curl_easy_setopt(h, CURLOPT_PRIVATE,        e);
  curl_easy_setopt(h, CURLOPT_WRITEFUNCTION,  murl_write_cb);
  curl_easy_setopt(h, CURLOPT_WRITEDATA,      e);
  curl_easy_setopt(h, CURLOPT_HEADERFUNCTION, murl_header_cb);
  curl_easy_setopt(h, CURLOPT_HEADERDATA,     e);
  curl_easy_setopt(h, CURLOPT_READFUNCTION,   murl_read_cb);
  curl_easy_setopt(h, CURLOPT_READDATA,       e);
  curl_easy_setopt(h, CURLOPT_OPENSOCKETFUNCTION, murl_opensocket_cb);
  curl_easy_setopt(h, CURLOPT_OPENSOCKETDATA,     e);
  curl_easy_setopt(h, CURLOPT_NOSIGNAL,       1L);

  CURLSH* sh = murl_thread_share();
  if (sh) curl_easy_setopt(h, CURLOPT_SHARE, sh);
}

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

  murl_easy_wire(e);

  return self;
}

/* =========================================================================
 * URL::Libcurl::Easy#initialize_copy  (dup / clone via curl_easy_duphandle)
 *
 * Ruby dup/clone shallow-copies the CDATA, leaving the copy with no usable
 * handle. Instead duplicate the underlying CURL* with curl_easy_duphandle, so a
 * dup/clone is an independent, working handle carrying the same options.
 *
 * curl_easy_duphandle's dupset does `dst->set = src->set` — a SHALLOW struct
 * copy — so the new handle (a) points WRITEDATA/HEADERDATA/READDATA/PRIVATE at
 * the SOURCE's murl_easy_t and (b) shares the source's caller-owned slists
 * (HTTPHEADER/QUOTE/MAIL_RCPT); it also does not copy the share. So murl_easy_wire
 * re-points the callbacks/share at the new struct, and the three slists are
 * deep-copied into copies the new handle owns (and this struct frees). The user
 * callback blocks are carried over so the clone behaves like the original; the
 * mimepost is deep-copied by libcurl itself, so the hidden mime root is not.
 * ========================================================================= */

/* Deep-copy a curl_slist; the result is owned by the caller. NULL for an
 * empty source; raises NoMemoryError (freeing the partial copy) on OOM. */
static struct curl_slist*
murl_slist_dup(mrb_state* mrb, const struct curl_slist* src)
{
  struct curl_slist* dst = NULL;
  for (const struct curl_slist* p = src; p; p = p->next) {
    struct curl_slist* n = curl_slist_append(dst, p->data);
    if (unlikely(!n)) {
      curl_slist_free_all(dst);
      mrb_exc_raise(mrb, mrb_obj_value(mrb->nomem_err));
    }
    dst = n;
  }
  return dst;
}

static mrb_value
murl_lc_easy_init_copy(mrb_state* mrb, mrb_value self)
{
  mrb_value orig;
  mrb_get_args(mrb, "o", &orig);

  murl_easy_t* src = (murl_easy_t*)mrb_data_get_ptr(mrb, orig, &murl_easy_type);
  if (unlikely(!src || !src->curl))
    mrb_raise(mrb, E_RUNTIME_ERROR, "URL::Libcurl::Easy not open");

  CURL* nh = curl_easy_duphandle(src->curl);
  if (unlikely(!nh)) mrb_raise(mrb, E_RUNTIME_ERROR, "curl_easy_duphandle failed");

  murl_easy_t* e = (murl_easy_t*)mrb_malloc(mrb, sizeof(*e));
  e->mrb         = mrb;
  e->self        = self;
  e->curl        = nh;
  e->req_headers = NULL;
  e->mail_rcpt   = NULL;
  e->quote       = NULL;
  /* Attach before the slist deep-copies below: if one raises (OOM), the GC sweep
   * of self still frees nh and any partial slist already stored here. */
  mrb_data_init(self, e, &murl_easy_type);

  murl_easy_wire(e);   /* callbacks -> e, plus this thread's share */

  /* Replace the slists the shallow set-copy left aliasing the source's
   * caller-owned lists with independent copies this handle owns. */
  if (src->req_headers) {
    e->req_headers = murl_slist_dup(mrb, src->req_headers);
    curl_easy_setopt(nh, CURLOPT_HTTPHEADER, e->req_headers);
  } else {
    curl_easy_setopt(nh, CURLOPT_HTTPHEADER, NULL);
  }
  if (src->mail_rcpt) {
    e->mail_rcpt = murl_slist_dup(mrb, src->mail_rcpt);
    curl_easy_setopt(nh, CURLOPT_MAIL_RCPT, e->mail_rcpt);
  } else {
    curl_easy_setopt(nh, CURLOPT_MAIL_RCPT, NULL);
  }
  if (src->quote) {
    e->quote = murl_slist_dup(mrb, src->quote);
    curl_easy_setopt(nh, CURLOPT_QUOTE, e->quote);
  } else {
    curl_easy_setopt(nh, CURLOPT_QUOTE, NULL);
  }

  /* Carry the user callback blocks so the clone behaves like the original. The
   * hidden mime root (MRB_SYM(mime)) is intentionally NOT copied — libcurl
   * duplicated the mimepost into the new handle, which owns its copy. */
  mrb_iv_set(mrb, self, MRB_IVSYM(on_data),        mrb_iv_get(mrb, orig, MRB_IVSYM(on_data)));
  mrb_iv_set(mrb, self, MRB_IVSYM(on_header),      mrb_iv_get(mrb, orig, MRB_IVSYM(on_header)));
  mrb_iv_set(mrb, self, MRB_IVSYM(on_read),        mrb_iv_get(mrb, orig, MRB_IVSYM(on_read)));
  mrb_iv_set(mrb, self, MRB_IVSYM(on_open_socket), mrb_iv_get(mrb, orig, MRB_IVSYM(on_open_socket)));

  return self;
}

/* initialize_copy for the CDATA handles libcurl cannot duplicate: Multi (there
 * is no curl_multi_duphandle) and Mime/Part (tied to the easy that built them).
 * A shallow dup/clone would share or orphan the C handle, so refuse it with a
 * clear error rather than hand back a broken or aliased copy. */
static mrb_value
murl_lc_no_dup(mrb_state* mrb, mrb_value self)
{
  mrb_raisef(mrb, E_NOTIMP_ERROR,
             "can't dup/clone %s: its libcurl handle cannot be duplicated",
             mrb_obj_classname(mrb, self));
  return self; /* unreachable */
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
#if LIBCURL_VERSION_NUM >= 0x072D00 /* 7.45.0 — enum member, #ifdef can't see it */
  else if (opt == MRB_SYM(pinnedpublickey))    rc = curl_easy_setopt(h, CURLOPT_PINNEDPUBLICKEY, mrb_string_cstr(mrb, val));
#endif
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
#if LIBCURL_VERSION_NUM >= 0x073E00 /* 7.62.0 — enum member, #ifdef can't see it */
  else if (opt == MRB_SYM(doh_url))            rc = curl_easy_setopt(h, CURLOPT_DOH_URL, mrb_string_cstr(mrb, val));
#endif
  /* --- transfer rate limiting ------------------------------------------- */
  else if (opt == MRB_SYM(max_send_speed))     rc = curl_easy_setopt(h, CURLOPT_MAX_SEND_SPEED_LARGE, (curl_off_t)mrb_as_int(mrb, val));
  else if (opt == MRB_SYM(max_recv_speed))     rc = curl_easy_setopt(h, CURLOPT_MAX_RECV_SPEED_LARGE, (curl_off_t)mrb_as_int(mrb, val));
  /* --- TCP keepalive ---------------------------------------------------- */
  else if (opt == MRB_SYM(tcp_keepalive))      rc = curl_easy_setopt(h, CURLOPT_TCP_KEEPALIVE, (long)mrb_bool(val));
  else if (opt == MRB_SYM(tcp_keepidle) || opt == MRB_SYM(tcp_keepintvl)) {
    /* Durations, same one-timeout API as :timeout above — but these two
     * CURLOPTs take whole seconds, so convert with DUR_SECONDS. mruby-chrono
     * owns the unit math and the type/range checks. */
    long secs;
    mrb_chrono_convert(mrb, val, MRB_CHRONO_OUT_LONG, MRB_CHRONO_DUR_SECONDS,
                       MRB_CHRONO_NEAREST, &secs, sizeof secs);
    rc = curl_easy_setopt(h, opt == MRB_SYM(tcp_keepidle) ? CURLOPT_TCP_KEEPIDLE
                                                          : CURLOPT_TCP_KEEPINTVL, secs);
  }
  /* --- unix domain socket (Docker / HTTP-over-unix) --------------------- */
#if LIBCURL_VERSION_NUM >= 0x072D00 /* 7.45.0 — enum member, #ifdef can't see it */
  else if (opt == MRB_SYM(unix_socket_path))   rc = curl_easy_setopt(h, CURLOPT_UNIX_SOCKET_PATH, mrb_string_cstr(mrb, val));
#endif
  /* --- multipart/form-data: val is a URL::Libcurl::Mime built in Ruby --- */
#if LIBCURL_VERSION_NUM >= 0x073800 /* 7.56.0 — enum member, #ifdef can't see it; the
                                      * curl_mime_* functions themselves are guarded
                                      * separately, at runtime, via g_mime_init (see
                                      * murl_lc_mime_new) — this only gates whether
                                      * CURLOPT_MIMEPOST itself compiles */
  else if (opt == MRB_SYM(mimepost))           rc = curl_easy_setopt(h, CURLOPT_MIMEPOST, murl_mime_get(mrb, val));
#endif
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
    /* curl reports microseconds; mruby-chrono turns them into the duration
     * (Float seconds) every other time value in the gem speaks.
     *
     * CURLINFO_TOTAL_TIME_T (off_t microseconds) needs 7.61.0 — but #total_time
     * is core path, read on every response, not an optional feature like the
     * WebSocket/mime primitives elsewhere in this file. So unlike those, an
     * old libcurl here does not get a version-gated raise or a silent nil:
     * CURLINFO_TOTAL_TIME (double seconds) has existed since curl's earliest
     * history and is a real, honest answer, just at double-precision instead
     * of microsecond-integer precision — an acceptable trade on a build this
     * old, not a degradation a caller has to special-case. */
#if LIBCURL_VERSION_NUM >= 0x073D00 /* 7.61.0 — enum member, #ifdef can't see it */
    curl_off_t us = 0;
    murl_easy_check(mrb, curl_easy_getinfo(h, CURLINFO_TOTAL_TIME_T, &us));
    return mrb_chrono_from(mrb, mrb_convert_int64(mrb, (int64_t)us),
                           MRB_CHRONO_DUR_MICROSECONDS);
#else
    double secs = 0;
    murl_easy_check(mrb, curl_easy_getinfo(h, CURLINFO_TOTAL_TIME, &secs));
    return mrb_chrono_from(mrb, mrb_convert_int64(mrb, (int64_t)(secs * 1000000.0)),
                           MRB_CHRONO_DUR_MICROSECONDS);
#endif
  }
  else if (info == MRB_SYM(content_type)) {
    const char* ct = NULL;
    murl_easy_check(mrb, curl_easy_getinfo(h, CURLINFO_CONTENT_TYPE, &ct));
    return ct ? mrb_str_new_cstr(mrb, ct) : mrb_nil_value();
  }
#if LIBCURL_VERSION_NUM >= 0x072D00 /* 7.45.0 — enum member, #ifdef can't see it.
                                      * Only websocket.rb calls :activesocket,
                                      * itself unreachable unless g_ws_recv/
                                      * g_ws_send resolved — real WebSocket support
                                      * (7.86.0+) implies this too, so an old-header
                                      * build falling through to "unsupported info"
                                      * below is never actually reached in practice. */
  else if (info == MRB_SYM(activesocket)) {
    curl_socket_t sock = CURL_SOCKET_BAD;
    murl_easy_check(mrb, curl_easy_getinfo(h, CURLINFO_ACTIVESOCKET, &sock));
    if (sock == CURL_SOCKET_BAD) return mrb_nil_value();
    return mrb_int_value(mrb, (mrb_int)sock);
  }
#endif
  else if (info == MRB_SYM(retry_after)) {
    /* CURLINFO_RETRY_AFTER is an *enum member* (CURLINFO_OFF_T + 57 inside
     * curl.h's CURLINFO enum), not a #define — the preprocessor has no
     * visibility into enum declarations at all, so #ifdef/#ifndef can never
     * detect it (unlike CURLWS_TEXT or the CURLINC_WEBSOCKETS_H include
     * guard above, which really are macros). A version check is the only
     * way to ask "did this header's text declare it" — legitimate here
     * specifically because that's a compile-time-only question with no
     * other answer, not an attempt to infer runtime behavior from it. The
     * *runtime* question — does the libcurl actually loaded support it — is
     * asked separately, of the library itself, below. */
#if LIBCURL_VERSION_NUM >= 0x074200
    /* nil on a *running* libcurl that predates this (it falls through
     * curl_easy_getinfo's own default case to CURLE_UNKNOWN_OPTION, see
     * lib/getinfo.c upstream, never a type-confused read) reads exactly like
     * nil on one that has it but the response carried no Retry-After
     * header. A duration built from the response's Retry-After header (curl
     * parses both the delta and HTTP-date forms, reporting whole seconds);
     * curl reports 0 when the header was absent, which we also surface as
     * nil. Pure marshalling, no policy. */
    curl_off_t secs = 0;
    CURLcode rc = curl_easy_getinfo(h, CURLINFO_RETRY_AFTER, &secs);
    if (rc == CURLE_UNKNOWN_OPTION) return mrb_nil_value();
    murl_easy_check(mrb, rc);
    if (secs <= 0) return mrb_nil_value();
    return mrb_chrono_from(mrb, mrb_convert_int64(mrb, (int64_t)secs),
                           MRB_CHRONO_DUR_SECONDS);
#else
    return mrb_nil_value();
#endif
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
 * error. A callback-stashed exception (mrb->exc, set by the write/header/read
 * trampolines) is left for mruby's own cfunc epilogue to raise the instant
 * this function returns to its Ruby caller — no explicit check needed here.
 * ========================================================================= */

static mrb_value
murl_lc_easy_perform(mrb_state* mrb, mrb_value mod)
{
  (void)mod;
  mrb_value easy_obj;
  mrb_get_args(mrb, "o", &easy_obj);
  murl_easy_t* e = murl_easy_get(mrb, easy_obj);

  CURLcode rc = curl_easy_perform(e->curl);
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

/* Raised by both primitives below when g_ws_recv/g_ws_send didn't resolve —
 * the libcurl actually loaded at runtime lacks the WebSocket API, established
 * once in murl_globals_init, never guessed from a header version. */
static void
murl_ws_check_available(mrb_state* mrb)
{
  if (unlikely(!g_ws_recv || !g_ws_send))
    mrb_raise(mrb, E_NOTIMP_ERROR, "the loaded libcurl has no WebSocket support (needs 7.86.0+)");
}

/* easy_ws_recv(easy, buflen) -> [String, flags_int, bytesleft_int] | nil
 *   nil means CURLE_AGAIN (nothing readable yet); the caller waits on the fd. */
static mrb_value
murl_lc_easy_ws_recv(mrb_state* mrb, mrb_value mod)
{
  (void)mod;
  murl_ws_check_available(mrb);

  mrb_value easy_obj;
  mrb_int   buflen;
  mrb_get_args(mrb, "oi", &easy_obj, &buflen);
  if (unlikely(buflen <= 0)) mrb_raise(mrb, E_ARGUMENT_ERROR, "buflen must be positive");

  murl_easy_t* e = murl_easy_get(mrb, easy_obj);

  mrb_value buf = mrb_str_new(mrb, NULL, (mrb_int)buflen);
  size_t recv = 0;
  const struct curl_ws_frame* meta = NULL;
  CURLcode rc = g_ws_recv(e->curl, RSTRING_PTR(buf), (size_t)buflen, &recv, &meta);

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

/* easy_ws_send(easy, str, flags_int, fragsize=0) -> [sent_count, flags_used] | nil
 *   nil means CURLE_AGAIN (the socket isn't writable yet).
 *
 * When flags carries no frame-type bit, the payload itself picks the type:
 * valid UTF-8 goes out as CURLWS_TEXT, anything else as CURLWS_BINARY — the
 * one distinction RFC 6455 §5.6 draws. mrb_str_is_utf8() is the same simdutf
 * call String#is_utf8? wraps, so this adds no logic a Ruby caller couldn't
 * run; it stays a stateless classification of the bytes already in hand.
 * The flags actually used are returned so a continuation loop (CURLWS_OFFSET)
 * can reuse the detected type instead of re-classifying a UTF-8 fragment that
 * may be split mid-character. */
static mrb_value
murl_lc_easy_ws_send(mrb_state* mrb, mrb_value mod)
{
  (void)mod;
  murl_ws_check_available(mrb);

  mrb_value easy_obj, data;
  mrb_int   flags;
  mrb_int   fragsize = 0;
  mrb_get_args(mrb, "oSi|i", &easy_obj, &data, &flags, &fragsize);

  murl_easy_t* e = murl_easy_get(mrb, easy_obj);

  if (!(flags & (CURLWS_TEXT | CURLWS_BINARY | CURLWS_PING | CURLWS_PONG | CURLWS_CLOSE)))
    flags |= mrb_str_is_utf8(data) ? CURLWS_TEXT : CURLWS_BINARY;

  size_t sent = 0;
  CURLcode rc = g_ws_send(e->curl, RSTRING_PTR(data), (size_t)RSTRING_LEN(data),
                          &sent, (curl_off_t)fragsize, (unsigned int)flags);
  if (rc == CURLE_AGAIN) return mrb_nil_value();
  murl_easy_check(mrb, rc);

  mrb_value out = mrb_ary_new_capa(mrb, 2);
  mrb_ary_push(mrb, out, mrb_convert_size_t(mrb, sent));
  mrb_ary_push(mrb, out, mrb_int_value(mrb, flags));
  return out;
}

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
#if LIBCURL_VERSION_NUM >= 0x071E00 /* 7.30.0 — enum members, #ifdef can't see them */
  else if (opt == MRB_SYM(max_host_connections))   rc = curl_multi_setopt(h, CURLMOPT_MAX_HOST_CONNECTIONS, (long)mrb_as_int(mrb, val));
  else if (opt == MRB_SYM(max_total_connections))  rc = curl_multi_setopt(h, CURLMOPT_MAX_TOTAL_CONNECTIONS, (long)mrb_as_int(mrb, val));
#endif
#if LIBCURL_VERSION_NUM >= 0x074300 /* 7.67.0 — enum member, #ifdef can't see it */
  else if (opt == MRB_SYM(max_concurrent_streams)) rc = curl_multi_setopt(h, CURLMOPT_MAX_CONCURRENT_STREAMS, (long)mrb_as_int(mrb, val));
#endif
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
 * not safe to churn (curl_global_init brings up the TLS backend and, on Windows,
 * Winsock; a VM's gem_final must not pull them out from under a transfer still
 * live in another VM). So the global layer is refcounted: call_once builds the
 * mutex and the tss key, then murl_global_ref/unref (above) bring curl_global_
 * init up on the first holder and tear it down after the last — holders being
 * both live VMs (here) and live per-thread shares. Per-mrb_state handle teardown
 * still happens in gem_final below. */
void
mrb_mruby_url_gem_init(mrb_state* mrb)
{
  call_once(&g_once, murl_globals_init);
  /* curl_global_init must succeed before any other libcurl call; if it failed
   * (e.g. the TLS backend or Winsock did not come up) libcurl is unusable, so
   * refuse to build the VM's bindings atop a dead library rather than proceed. */
  if (unlikely(!murl_global_ref()))
    mrb_raise(mrb, E_RUNTIME_ERROR, "curl_global_init failed");
  t_vm_count++;   /* this thread now has one more live VM */

  struct RClass* url_cls = mrb_define_class_id(mrb, MRB_SYM(URL), mrb->object_class);

  struct RClass* lc = mrb_define_module_under_id(mrb, url_cls, MRB_SYM(Libcurl));

  mrb_define_module_function_id(mrb, lc, MRB_SYM(easy_init),     murl_lc_easy_init,     MRB_ARGS_NONE());
  mrb_define_module_function_id(mrb, lc, MRB_SYM(easy_setopt),   murl_lc_easy_setopt,   MRB_ARGS_REQ(3));
  mrb_define_module_function_id(mrb, lc, MRB_SYM(easy_getinfo),  murl_lc_easy_getinfo,  MRB_ARGS_REQ(2));
  mrb_define_module_function_id(mrb, lc, MRB_SYM(easy_strerror), murl_lc_easy_strerror, MRB_ARGS_REQ(1));
  mrb_define_module_function_id(mrb, lc, MRB_SYM(easy_perform),  murl_lc_easy_perform,  MRB_ARGS_REQ(1));

  /* Always registered — murl_ws_check_available (inside each) is what
   * decides, at call time, whether g_ws_recv/g_ws_send actually resolved. No
   * build-time branch here: registration can't know what murl_globals_init
   * will find at process startup. */
  mrb_define_module_function_id(mrb, lc, MRB_SYM(easy_ws_recv), murl_lc_easy_ws_recv, MRB_ARGS_REQ(2));
  mrb_define_module_function_id(mrb, lc, MRB_SYM(easy_ws_send), murl_lc_easy_ws_send, MRB_ARGS_ARG(3, 1));

  /* WebSocket frame flags (CURLWS_*), published so the Ruby URL::WebSocket can
   * map its :text/:binary/:ping/:pong/:close symbols to the bitmask and back.
   * These are plain stable bit values (see the guarded fallback definitions
   * near the top of the file) — always published regardless of whether
   * g_ws_recv/g_ws_send actually resolved; a Ruby caller only ever hits the
   * NotImplementedError from actually trying to send/receive. */
  mrb_define_const_id(mrb, lc, MRB_SYM(WS_TEXT),   mrb_int_value(mrb, CURLWS_TEXT));
  mrb_define_const_id(mrb, lc, MRB_SYM(WS_BINARY), mrb_int_value(mrb, CURLWS_BINARY));
  mrb_define_const_id(mrb, lc, MRB_SYM(WS_CONT),   mrb_int_value(mrb, CURLWS_CONT));
  mrb_define_const_id(mrb, lc, MRB_SYM(WS_CLOSE),  mrb_int_value(mrb, CURLWS_CLOSE));
  mrb_define_const_id(mrb, lc, MRB_SYM(WS_PING),   mrb_int_value(mrb, CURLWS_PING));
  mrb_define_const_id(mrb, lc, MRB_SYM(WS_PONG),   mrb_int_value(mrb, CURLWS_PONG));
  mrb_define_const_id(mrb, lc, MRB_SYM(WS_OFFSET), mrb_int_value(mrb, CURLWS_OFFSET));

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
  /* dup/clone duplicates the underlying CURL* (curl_easy_duphandle) so the copy
   * is an independent, working handle rather than an empty CDATA. */
  mrb_define_method_id(mrb, easy_cls, MRB_SYM(initialize_copy), murl_lc_easy_init_copy, MRB_ARGS_REQ(1));

  struct RClass* multi_cls =
    mrb_define_class_under_id(mrb, lc, MRB_SYM(Multi), mrb->object_class);
  MRB_SET_INSTANCE_TT(multi_cls, MRB_TT_CDATA);
  mrb_undef_method_id(mrb, multi_cls, MRB_SYM(initialize));
  mrb_define_method_id(mrb, multi_cls, MRB_SYM(initialize_copy), murl_lc_no_dup, MRB_ARGS_REQ(1));

  /* multipart/form-data handles: curl_mime (the tree) and curl_mimepart. */
  struct RClass* mime_cls =
    mrb_define_class_under_id(mrb, lc, MRB_SYM(Mime), mrb->object_class);
  MRB_SET_INSTANCE_TT(mime_cls, MRB_TT_CDATA);
  mrb_undef_method_id(mrb, mime_cls, MRB_SYM(initialize));
  mrb_define_method_id(mrb, mime_cls, MRB_SYM(initialize_copy), murl_lc_no_dup, MRB_ARGS_REQ(1));

  struct RClass* part_cls =
    mrb_define_class_under_id(mrb, lc, MRB_SYM(Part), mrb->object_class);
  MRB_SET_INSTANCE_TT(part_cls, MRB_TT_CDATA);
  mrb_undef_method_id(mrb, part_cls, MRB_SYM(initialize));
  mrb_define_method_id(mrb, part_cls, MRB_SYM(initialize_copy), murl_lc_no_dup, MRB_ARGS_REQ(1));

  mrb_define_module_function_id(mrb, lc, MRB_SYM(mime_new),      murl_lc_mime_new,      MRB_ARGS_REQ(1));
  mrb_define_module_function_id(mrb, lc, MRB_SYM(mime_addpart),  murl_lc_mime_addpart,  MRB_ARGS_REQ(1));
  mrb_define_module_function_id(mrb, lc, MRB_SYM(mime_name),     murl_lc_mime_name,     MRB_ARGS_REQ(2));
  mrb_define_module_function_id(mrb, lc, MRB_SYM(mime_data),     murl_lc_mime_data,     MRB_ARGS_REQ(2));
  mrb_define_module_function_id(mrb, lc, MRB_SYM(mime_filedata), murl_lc_mime_filedata, MRB_ARGS_REQ(2));
  mrb_define_module_function_id(mrb, lc, MRB_SYM(mime_type),     murl_lc_mime_type,     MRB_ARGS_REQ(2));
  mrb_define_module_function_id(mrb, lc, MRB_SYM(mime_filename), murl_lc_mime_filename, MRB_ARGS_REQ(2));

  /* The connection/TLS share is per-OS-thread now (see murl_thread_share), not
   * per-VM, so nothing is created or published here — it springs up lazily on
   * the first easy made on each thread. */
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

/* This VM's easies/multis are gone after the two passes above (each
 * curl_easy_cleanup detached its easy from the thread share). The connection
 * share belongs to the OS thread, not this VM, so it is drained only when this
 * is the thread's LAST VM — at which point every VM on the thread has finalized
 * and no easy is still attached, so curl_share_cleanup succeeds and the global
 * layer reaches its 1->0 transition deterministically here, with no reliance on
 * atexit or on the main thread's tss destructor (which does not run at exit).
 * A thread that exits without finalizing its VM falls back to the tss
 * destructor (non-fatal CURLSHE_IN_USE, share left — like a leaked easy). */
void
mrb_mruby_url_gem_final(mrb_state* mrb)
{
  mrb_objspace_each_objects(mrb, murl_disarm_callbacks, NULL);
  mrb_objspace_each_objects(mrb, murl_cleanup_curl,     NULL);

  if (t_vm_count > 0 && --t_vm_count == 0) murl_thread_share_drain();

  murl_global_unref();   /* drop this VM's hold on the global layer */
}
