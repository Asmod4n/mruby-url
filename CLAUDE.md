# mruby-url — contributor directives

## C is an FFI-thin binding only

`src/` exists only to do what a generic FFI layer could do, and nothing more:

- call libcurl functions and marshal primitive arguments/results across the
  boundary (ints, bools, strings, `curl_off_t`, slists),
- register the callbacks libcurl requires (write / header / read, socket,
  timer),
- copy bytes between libcurl buffers and mruby values.

Everything else — dispatch, option/verb mapping, control flow, per-transfer
state, parsing, protocol behaviour, scheme handling — lives in Ruby
(`mrblib/`).

**Why:** hand-written C is the only place this gem can have memory-safety
bugs. Keeping C at FFI level keeps the fuzzable surface near zero; all the
logic a fuzzer could reach sits in memory-safe Ruby.

### Rules of thumb

- Add new behaviour in Ruby by default. Touch C only when libcurl's API can
  only be reached from C (e.g. a required callback function pointer) — and then
  add the *minimum* glue, with the logic in Ruby.
- C callbacks stay thin: store-only where possible (see the socket and timer
  callbacks, which just record into plain C and let Ruby act afterwards), or a
  single bounded `memcpy` (see the write callback). No business logic, no
  bookkeeping, no string parsing inside a callback.
- No data-structure management or option-dispatch logic in C. `setopt` stays a
  flat symbol→`CURLOPT_*` pass-through; the decisions about *which* options to
  set are made in Ruby.
- Prefer mruby's arg/type helpers (they type-check and reject bad input, e.g.
  embedded NULs) over hand-rolled pointer/length handling.
