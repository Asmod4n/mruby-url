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

  # Throwaway run-state dir: port files, captured payloads, logs. It lives under
  # the build's own scratch area (mruby/build/), so it never touches the
  # checked-in test/ tree and `rake (deep_)clean` sweeps it with the build. We
  # hand the path to the two consumers without any pointer/marker file: the MRI
  # fixture is our own child, so it gets the path as an ARGV; the mruby test
  # (test/url.rb) runs inside mrbtest (whose environ reads empty), so we export
  # the path here in ENV and the gem's mrbgem.rake — which runs under MRI, where
  # ENV works — forwards it into spec.test_args / the mrbtest TEST_ARGS constant.
  state_dir = File.join(__dir__, "mruby", "build", "url-test-run")
  port_file = File.join(state_dir, "server_port")
  FileUtils.rm_rf(state_dir)        # clean slate — never read a stale port
  FileUtils.mkdir_p(state_dir)
  ENV["MURL_TEST_STATE_DIR"] = state_dir

  # MRI->MRI spawn. No cmd.exe wrapper, no Winsock init weirdness. pgroup: true
  # makes the fixture a process-group leader, so its spawned daemons (sshd /
  # slapd / mosquitto) join that group and we can tear the whole group down
  # below — the daemons can never outlive the tests, even on SIGKILL.
  # Process-group signals are a POSIX thing; on Windows we fall back to killing
  # the single fixture pid (where no daemons get spawned anyway). The fixture
  # learns where to write via ARGV — it's our own child.
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
    # Run-state lives under mruby/build/; `rake (deep_)clean` sweeps it. Leaving
    # it in place between runs aids post-mortem on a failure — the next run
    # wipes it clean before starting.
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
