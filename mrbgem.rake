MRuby::Gem::Specification.new('mruby-url') do |spec|
  spec.license = 'Apache-2'
  spec.author = 'Hendrik Beskow'
  spec.summary = 'URL session for mruby — libcurl-backed HTTP client with a session API'

  # mruby-io          : IO.select + IO.for_fd + IO#autoclose= for the
  #                     internal IOSelectLoop.
  # mruby-error       : mrb_protect_error.
  # mruby-uri-parser  : ada-url-based URI.parse and URI.encode. Used for
  #                     URL normalization and params/form encoding.
  # mruby-fast-json   : simdjson-backed JSON.parse / JSON.dump / JSON.parse_lazy
  #                     + native_ext_type for typed deserialization.
  spec.add_dependency 'mruby-io',          core:   'mruby-io'
  spec.add_dependency 'mruby-error',       core:   'mruby-error'
  spec.add_dependency 'mruby-uri-parser'
  spec.add_dependency 'mruby-fast-json'
  spec.add_dependency 'mruby-c-ext-helpers'

  spec.search_package('libcurl')
end
