MRuby::Gem::Specification.new('mruby-url') do |spec|
  spec.license = 'MIT'
  spec.author  = 'Hendrik'
  spec.summary = 'URL / HTTP bindings using embedded libcurl'

  spec.add_dependency 'mruby-io',          core: 'mruby-io'
  spec.add_dependency 'mruby-error',       core: 'mruby-error'
  spec.add_dependency 'mruby-uri-parser'
  spec.add_dependency 'mruby-fast-json'
  spec.add_dependency 'mruby-c-ext-helpers'
  spec.add_dependency 'mruby-socket'
  spec.add_dependency 'mruby-string-ext'   # String#byteslice for Ruby-side upload chunking
  spec.add_test_dependency 'mruby-env'
  spec.add_test_dependency 'mruby-sleep'

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
        curl_inst  = "#{spec.build_dir}/curl-install"

        is_msvc = spec.build.toolchains.include?('visualcpp') ||
                  spec.build.cc.command =~ /(^|[\\\/])cl(\.exe)?$/i

        FileUtils.mkdir_p(curl_build)

        args = [
          "-S \"#{curl_src}\"",
          "-B \"#{curl_build}\"",
          "-DCMAKE_BUILD_TYPE=Release",
          "-DCMAKE_INSTALL_PREFIX=\"#{curl_inst}\"",
          "-DBUILD_SHARED_LIBS=OFF",
          "-DBUILD_CURL_EXE=OFF",
          "-DCURL_USE_LIBPSL=OFF"
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
    
        sh "cmake #{args.join(' ')}"
        sh "cmake --build \"#{curl_build}\" --config Release --target install"

        # Wire libcurl into the gem's compile + link.
        spec.cc.include_paths     << "#{curl_inst}/include"
        spec.cxx.include_paths    << "#{curl_inst}/include"
        spec.linker.library_paths << "#{curl_inst}/lib"
        spec.linker.libraries     << 'libcurl'
        spec.cc.defines           << 'CURL_STATICLIB'

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
    # on it. Look it up via pkg-config rather than vendoring.
    spec.search_package 'libcurl'

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
