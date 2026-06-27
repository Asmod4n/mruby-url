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
  port_file     = File.expand_path("test/server_port", __dir__)
  server_script = File.expand_path("test/server.ruby",  __dir__)

  # Stale state from a previous run. server_port is written last by the fixture,
  # so clearing it here means the wait below only proceeds once the fresh run
  # has all servers up; clear the other port files too so we never read a dead
  # port (a protocol whose server didn't come up this run leaves no port file,
  # and its tests skip).
  %w[server_port smtp_port imap_port ws_port ftp_port dict_port gopher_port
     pop3_port telnet_port rtsp_port tftp_port sftp_port sftp_meta ldap_port
     mqtt_port ftps_port pop3s_port gophers_port ldaps_port mqtts_port file_url].each do |n|
    f = File.expand_path("test/#{n}", __dir__)
    File.unlink(f) if File.exist?(f)
  end

  # MRI->MRI spawn. No cmd.exe wrapper, no Winsock init weirdness.
  server_pid = spawn(RbConfig.ruby, server_script)

  begin
    50.times do
      break if File.exist?(port_file)
      sleep 0.1
    end
    raise "test server didn't write #{port_file} within 5s" unless File.exist?(port_file)

    Dir.chdir("mruby") do
      ENV["MRUBY_CONFIG"] = MRUBY_CONFIG_PATH
      sh "rake all test"
    end
  ensure
    begin
      Process.kill("KILL", server_pid)
      Process.wait(server_pid)
    rescue
      # already gone
    end
    %w[server_port smtp_port imap_port ws_port ftp_port dict_port gopher_port
       pop3_port telnet_port rtsp_port tftp_port sftp_port sftp_meta ldap_port
       mqtt_port ftps_port pop3s_port gophers_port ldaps_port mqtts_port
       file_url].each do |n|
      f = File.expand_path("test/#{n}", __dir__)
      File.unlink(f) if File.exist?(f)
    end
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
