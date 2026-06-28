require 'rake'
require 'fileutils'

MRUBY_CONFIG_PATH = File.expand_path(ENV["MRUBY_CONFIG"] || "build_config.rb")

file :mruby do
  unless File.directory?('mruby')
    sh "git clone --depth=1 https://github.com/mruby/mruby.git"
  end
end

desc "compile binary"
task :compile => :mruby do
  Dir.chdir("mruby") do
    ENV["MRUBY_CONFIG"] = MRUBY_CONFIG_PATH
    sh "rake all"
  end
end

desc "test"
task :test => :mruby do
  unless system(RbConfig.ruby, "-rwebrick", "-e", "", out: File::NULL, err: File::NULL)
    abort "test server needs webrick — run: gem install webrick"
  end
  server_script = File.expand_path("test/server.ruby", __dir__)

  # Build first. Loading the gem's mrbgem.rake creates the throwaway run-state
  # directory under the gem's build tree (swept by `rake clean`) and writes its
  # path to this pointer file. We read the pointer rather than recompute the
  # build layout, so the path stays owned by one place — the gem spec.
  pointer = File.join(__dir__, "mruby", ".url-test-state")
  Dir.chdir("mruby") do
    ENV["MRUBY_CONFIG"] = MRUBY_CONFIG_PATH
    sh "rake all"
  end
  raise "gem build did not create #{pointer}" unless File.exist?(pointer)
  state_dir = File.read(pointer).strip
  port_file = File.join(state_dir, "server_port")

  # Start from a clean slate so we never read a stale port from a previous run
  # (a protocol whose server doesn't come up leaves no port file, and its tests
  # skip). The dir itself stays put — `rake clean` removes it with the build.
  FileUtils.rm_rf(state_dir)
  FileUtils.mkdir_p(state_dir)

  # MRI->MRI spawn. No cmd.exe wrapper, no Winsock init weirdness. pgroup: true
  # makes the fixture a process-group leader, so its spawned daemons (sshd /
  # slapd / mosquitto) join that group and we can tear the whole group down
  # below — the daemons can never outlive the tests, even on SIGKILL.
  # Process-group signals are a POSIX thing; on Windows we fall back to killing
  # the single fixture pid (where no daemons get spawned anyway). The fixture
  # learns where to write via ARGV — it's our own child, no ENV needed.
  group_kill = (RbConfig::CONFIG['host_os'] !~ /mswin|mingw|cygwin/)
  server_pid =
    if group_kill
      spawn(RbConfig.ruby, server_script, state_dir, pgroup: true)
    else
      spawn(RbConfig.ruby, server_script, state_dir)
    end

  begin
    50.times do
      break if File.exist?(port_file)
      sleep 0.1
    end
    raise "test server didn't write #{port_file} within 5s" unless File.exist?(port_file)

    Dir.chdir("mruby") do
      ENV["MRUBY_CONFIG"] = MRUBY_CONFIG_PATH
      sh "rake test"
    end
  ensure
    # Kill the whole process group (negative pid) so every spawned daemon dies
    # with the fixture; fall back to the single pid where groups aren't usable.
    begin
      if group_kill
        Process.kill("TERM", -server_pid) rescue nil  # let at_exit reap first
        sleep 0.3
        Process.kill("KILL", -server_pid) rescue nil
      else
        Process.kill("KILL", server_pid)
      end
      Process.wait(server_pid)
    rescue
      # already gone
    end
    # Run-state lives under the gem build dir; `rake clean` sweeps it. Nothing
    # to remove here — leaving the logs around aids post-mortem on a failure.
  end
end

desc "cleanup"
task :clean do
  Dir.chdir("mruby") do
    ENV["MRUBY_CONFIG"] = MRUBY_CONFIG_PATH
    sh "rake deep_clean"
  end
end

task :default => :test
