MRuby::Gem::Specification.new('mruby-url') do |spec|
  spec.license = 'MIT'
  spec.author  = 'Hendrik'
  spec.summary = 'URL / HTTP bindings using embedded libcurl'

  spec.add_dependency 'mruby-io',          core: 'mruby-io'
  spec.add_dependency 'mruby-error',       core: 'mruby-error'
  spec.add_dependency 'mruby-uri-parser'
  spec.add_dependency 'mruby-fast-json'
  spec.add_dependency 'mruby-c-ext-helpers'
  spec.add_dependency 'mruby-chrono'       # duration literals (30.s/500.ms) + lossless seconds->ms in C
  spec.add_dependency 'mruby-socket'
  spec.add_dependency 'mruby-string-ext'   # String#byteslice for Ruby-side upload chunking
  spec.add_dependency 'mruby-string-is-utf8' # String#is_utf8? — WebSocket#send picks TEXT vs BINARY frames
  spec.add_dependency 'mruby-sleep'        # portable sleep(seconds) — see io_select_loop.rb's
                                            # nothing-to-watch-but-a-timer case (an all-empty
                                            # IO.select, the POSIX idiom for that, fails outright
                                            # on Windows; sleep() is the one primitive that's
                                            # actually portable there)
  spec.add_test_dependency 'mruby-env'

  # The test fixture's run-state dir is created and exported by the project
  # Rakefile (MURL_TEST_STATE_DIR). mrbtest's own environ reads empty, so the
  # mruby test (test/url.rb) can't read ENV directly — but this mrbgem.rake runs
  # under MRI rake, where ENV works, so we forward the path through spec.test_args.
  # mrbtest bakes it into the TEST_ARGS constant the test then reads. No files.
  if (state = ENV['MURL_TEST_STATE_DIR'])
    spec.test_args['state_dir'] = state
  end

  if spec.for_windows?
    cleaning = Rake.application.top_level_tasks.any? { |t| t =~ /\Aclean|deep_clean\z/ }
    # ------------------------------------------------------------------
    # Vendored libcurl
    #
    # Windows rarely has libcurl available system-wide, so we build it
    # from deps/curl with CMake and link statically against Schannel for
    # TLS (no OpenSSL dependency).
    #
    # No idempotency dance here — CMake's own configure cache and ninja /
    # MSBuild's dependency tracking make a no-op rebuild a sub-second
    # operation. Simpler to just run it.
    # ------------------------------------------------------------------
    unless cleaning
        require 'fileutils'

        curl_src   = "#{spec.dir}/deps/curl"
        curl_build = "#{spec.build_dir}/curl-build"
        # MURL_CURL_INSTALL points the install prefix somewhere stable (CI
        # caches it keyed on the deps/curl submodule commit); default stays
        # inside the build dir.
        curl_inst  = ENV['MURL_CURL_INSTALL'] || "#{spec.build_dir}/curl-install"

        is_msvc = spec.build.toolchains.include?('visualcpp') ||
                  spec.build.cc.command =~ /(^|[\\\/])cl(\.exe)?$/i

        # A populated install prefix (restored from cache) skips the CMake
        # build entirely — headers + static lib are all the gem consumes.
        prebuilt = Dir.exist?("#{curl_inst}/include/curl") &&
                   !Dir.glob("#{curl_inst}/lib/*curl*.lib").empty?

        FileUtils.mkdir_p(curl_build) unless prebuilt

        args = [
          "-S \"#{curl_src}\"",
          "-B \"#{curl_build}\"",
          "-DCMAKE_BUILD_TYPE=Release",
          "-DCMAKE_INSTALL_PREFIX=\"#{curl_inst}\"",
          "-DBUILD_SHARED_LIBS=OFF",
          "-DBUILD_CURL_EXE=OFF",
          "-DCURL_USE_LIBPSL=OFF",
          # WebSocket (ws://, and wss:// since Schannel gives us SSL below).
          # Default-OFF in current curl, but state it explicitly so the gem's
          # URL.websocket keeps working even if a future curl flips the default
          # or HTTP_ONLY-style logic creeps in. Force-disabled only under
          # CURL_DISABLE_HTTP / HTTP_ONLY, neither of which we set.
          "-DCURL_DISABLE_WEBSOCKETS=OFF"
        ]

        if is_msvc
          # Pick the matching CRT — the one ABI-critical flag on MSVC.
          # Case statement so /MDd maps to MultiThreadedDebugDLL rather than
          # MultiThreadedDLLDebug (which doesn't exist).
          cflags  = spec.build.cc.flags.flatten.join(' ')
          runtime = case cflags
                    when /\/MTd\b/ then 'MultiThreadedDebug'
                    when /\/MT\b/  then 'MultiThreaded'
                    when /\/MDd\b/ then 'MultiThreadedDebugDLL'
                    else                'MultiThreadedDLL'
                    end

          args << "-DCMAKE_MSVC_RUNTIME_LIBRARY=#{runtime}"
          args << "-DCMAKE_POLICY_DEFAULT_CMP0091=NEW"
          args << "-DCURL_USE_SCHANNEL=ON"
        end

        # Deliberately not forwarding mruby's full cflags into libcurl. The
        # CRT selection above is the only ABI-critical bit; the rest (warning
        # flags, defines like MRB_UTF8_STRING) would just produce noise or
        # contaminate curl's translation units with mruby-specific defines.
    
        unless prebuilt
          sh "cmake #{args.join(' ')}"
          sh "cmake --build \"#{curl_build}\" --config Release --target install"
        end

        # Wire libcurl into the gem's compile + link.
        spec.cc.include_paths     << "#{curl_inst}/include"
        spec.cxx.include_paths    << "#{curl_inst}/include"
        spec.linker.library_paths << "#{curl_inst}/lib"
        spec.linker.libraries     << 'libcurl'
        spec.cc.defines           << 'CURL_STATICLIB'
        # Ours, not curl's: read in mrb_url.c to pick how the WebSocket
        # functions are resolved. A statically-linked curl_ws_recv/send are
        # this translation unit's own linked-in symbols — direct linkage is
        # correct and dlsym(RTLD_DEFAULT, ...) would not find them anyway
        # (they were never a shared library's own exported dynamic symbols).
        # Set here because it's a fact about THIS build's linking mode
        # (-DBUILD_SHARED_LIBS=OFF above), not something to infer from being
        # on Windows — the two happen to coincide today only because this is
        # the one branch that vendors a static curl.
        spec.cc.defines           << 'MURL_CURL_STATIC'

        # mrb_url.c includes C11 <threads.h> (call_once). MSVC only exposes it
        # — and recognizes the _Noreturn it declares thrd_exit with — under
        # /std:c11; other Windows compilers take -std=c11. Without it the build
        # fails with C2054/C2085 on _Noreturn.
        spec.cc.flags << (is_msvc ? '/std:c11' : '-std=c11')

        spec.linker.libraries.concat %w[
          ws2_32 crypt32 wldap32 normaliz advapi32 iphlpapi secur32 bcrypt
        ]
      end
  else
    # Linux / macOS: libcurl is typically available via the system package
    # manager or Homebrew, and many other things on the box already depend
    # on it. Look it up via pkg-config first — cheap, and reuses whatever
    # TLS/http2/etc. the system build already has.
    # Unlike Windows, we never vendor-build curl here — not even as a
    # fallback. Doing that safely would also need OpenSSL's dev headers
    # (curl's own CMake build doesn't fail without a TLS backend, it just
    # silently produces a curl with HTTPS/WSS/FTPS/IMAPS/… all compiled out,
    # so it "succeeds" and then fails every TLS request at runtime instead of
    # failing here where the cause is obvious) plus cmake itself. Simpler and
    # safer to just say what's missing and stop.
    unless spec.search_package('libcurl')
      raise <<~MSG
        [mruby-url] system libcurl not found via pkg-config. Install its
        development package — not just the runtime library, curl.h has to be
        on the include path — and re-run:
          Debian/Ubuntu:  sudo apt install libcurl4-openssl-dev pkg-config
          Fedora/RHEL:    sudo dnf install libcurl-devel pkgconf-pkg-config
          Arch:           sudo pacman -S curl pkgconf
          macOS:          brew install curl pkg-config
        (macOS: curl is keg-only — also `export PKG_CONFIG_PATH="$(brew --prefix curl)/lib/pkgconfig"`)
      MSG
    end

    # C11 call_once (gem_init) lives in libpthread on glibc < 2.34; -pthread
    # pulls it in there and is a harmless no-op on modern glibc and macOS.
    spec.cc.flags     << '-pthread'
    spec.linker.flags << '-pthread'

    # Use C11 <threads.h> when the toolchain actually has it; otherwise (Apple
    # clang, or any C99-only toolchain) fall back to our pthreads-backed shim
    # in src/compat (a 1:1 subset of the C11 interface). search_header probes the
    # compiler's real header search path (gcc/clang run `cc -Wp,-v`), so this is
    # platform- and standard-independent rather than a hardcoded OS check. The
    # shim is POSIX (pthreads), which is why it lives in this non-Windows branch;
    # Windows always has <threads.h> via MSVC/MinGW and is handled above.
    unless spec.cc.search_header('threads.h')
      spec.cc.include_paths << "#{spec.dir}/src/compat"
    end
  end
end
