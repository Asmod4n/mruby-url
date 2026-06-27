# build_config_visualcpp.rb
#
# Same as build_config.rb, but pins the toolchain to MSVC instead of letting
# mruby guess it. mruby's Toolchain.guess only picks :visualcpp when a Visual
# Studio environment is active (VSINSTALLDIR / VisualStudioVersion set) and
# otherwise falls back to :gcc — the wrong choice for this gem's Windows build,
# which vendors libcurl against Schannel with MSVC. Forcing :visualcpp makes the
# Windows build deterministic regardless of how the shell was launched.
#
# Use it by pointing MRUBY_CONFIG at this file, then run rake:
#
#     set MRUBY_CONFIG=build_config_visualcpp.rb   &&  rake        (cmd)
#     $env:MRUBY_CONFIG = 'build_config_visualcpp.rb'; rake        (pwsh)
#
# CI uses it for the Windows job so the build never depends on env detection.
MRuby::Build.new do |conf|
  conf.toolchain :visualcpp
  conf.enable_debug
  conf.cc.defines  << 'MRB_UTF8_STRING' << 'MRB_HIGH_PROFILE'
  conf.cxx.defines << 'MRB_UTF8_STRING' << 'MRB_HIGH_PROFILE'
  conf.enable_test
  conf.gembox 'default'
  conf.gem core: 'mruby-bin-mirb'
  conf.gem File.expand_path(File.dirname(__FILE__))
end
