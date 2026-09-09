# Cross-compile for Windows with MinGW, and run the tests under Wine.
#
#     MRUBY_CONFIG=build_config_mingw.rb rake test
#
# This is the only config that builds deps/curl. spec.for_windows? is
# what decides (mruby's lib/mruby/gem.rb), and for a CrossBuild it asks
# one question: is host_target one of x86_64-w64-mingw32 or
# i686-w64-mingw32. A plain MRuby::Build never says yes on Linux - it
# looks for a drive letter - so build_config.rb takes the system libcurl
# through pkg-config and the vendored build goes untested.
#
# What it needs, beside a MinGW gcc and g++ and Wine: cmake, which builds
# curl, and drive z: mapped to the root filesystem, which is Wine's
# default. mruby's own build_config/cross-mingw-winetest.rb carries the
# longer setup notes.
#
# This config does not build yet, and what it finds is why it is here.
# It reaches the vendored curl - CMake configures and installs libcurl -
# and then stops on three things, none of them this file's:
#
#   1. The CMake call in mrbgem.rake names no CMAKE_SYSTEM_NAME and no
#      toolchain file, so curl builds for the machine and not for the
#      target. On this host that is silent, because the two are the same
#      compiler family; on a real cross build it would put a Linux
#      archive into a Windows binary.
#
#   2. mruby-c-ext-helpers and mruby-chrono read spec.for_windows? as
#      "MSVC" and hand /std:c++17 to gcc. The question they want to ask
#      is which compiler, not which platform - mrbgem.rake asks it
#      correctly, as is_msvc.
#
#   3. mrb_url.c includes C11 <threads.h>, and mingw-w64 11.0.1, which
#      is what Ubuntu 24.04 packages, does not carry it. C11 threads
#      reached mingw-w64 in version 12. So no MinGW on this distribution
#      can build this gem, whatever the flags say.
#
# Which means the Windows build has only ever been exercised with MSVC.
MRuby::CrossBuild.new('mingw') do |conf|
  conf.toolchain :gcc

  conf.host_target = 'x86_64-w64-mingw32'

  # -posix, and not the plain driver: mrb_url.c uses C11 <threads.h>,
  # which the win32 threading model of MinGW does not carry.
  conf.cc.command = "#{conf.host_target}-gcc-posix"
  # The C++ compiler as well, or the host g++ builds mruby's own
  # error-cxx.cxx and every gem that carries a .cpp.
  conf.cxx.command = "#{conf.host_target}-g++-posix"
  conf.linker.command = conf.cxx.command
  conf.archiver.command = "#{conf.host_target}-gcc-ar"
  conf.exts.executable = '.exe'

  # Static, so a test binary under Wine does not go looking for the
  # MinGW runtime DLLs.
  conf.cc.flags = ['-static']
  conf.linker.flags += ['-static']

  conf.cc.defines  << 'MRB_UTF8_STRING' << 'MRB_HIGH_PROFILE'
  conf.cxx.defines << 'MRB_UTF8_STRING' << 'MRB_HIGH_PROFILE'

  # A cross build detects no ports, so the Windows one is named here.
  # Without it every mrb_hal_* symbol the gems sit on is undefined at
  # link time.
  conf.ports :win

  conf.test_runner do |t|
    t.command = File.expand_path('mruby/build_config/helpers/wine_runner.rb', __dir__)
  end

  conf.gembox 'default'
  conf.enable_test
  conf.gem File.expand_path(File.dirname(__FILE__))
end
