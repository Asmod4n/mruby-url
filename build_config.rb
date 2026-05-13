MRuby::Build.new do |conf|
    toolchain :gcc

    conf.enable_debug
    conf.cc.defines  << 'MRB_UTF8_STRING' << 'MRB_HIGH_PROFILE'
    conf.cxx.defines << 'MRB_UTF8_STRING' << 'MRB_HIGH_PROFILE'
    conf.enable_test
    conf.gem core: 'mruby-bin-mirb'
    conf.gem File.expand_path(File.dirname(__FILE__))
end
