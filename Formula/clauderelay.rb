class Clauderelay < Formula
  desc "Remote terminal relay server and CLI over WebSocket"
  homepage "https://github.com/miguelriotinto/ClaudeRelay"
  url "https://github.com/miguelriotinto/ClaudeRelay/archive/refs/tags/v0.3.9.tar.gz"
  sha256 "2a8c2f40256c77aab5a48bcd64876d851d1921b184f5d7f5a71adc8990d3a0d4"
  license "MIT"
  head "https://github.com/miguelriotinto/ClaudeRelay.git", branch: "main"

  depends_on xcode: ["15.0", :build]
  depends_on :macos

  def install
    system "swift", "build",
           "-c", "release",
           "--disable-sandbox",
           "-Xswiftc", "-cross-module-optimization",
           "--product", "claude-relay-server"
    system "swift", "build",
           "-c", "release",
           "--disable-sandbox",
           "-Xswiftc", "-cross-module-optimization",
           "--product", "claude-relay"
    bin.install ".build/release/claude-relay"
    bin.install ".build/release/claude-relay-server"
  end

  service do
    run opt_bin/"claude-relay-server"
    keep_alive true
    restart_delay 5
    log_path var/"log/claude-relay/stdout.log"
    error_log_path var/"log/claude-relay/stderr.log"
    working_dir Dir.home
    environment_variables HOME: Dir.home, USER: ENV.fetch("USER", nil), PATH: std_service_path_env
  end

  def post_install
    (var/"claude-relay").mkpath
    (var/"log/claude-relay").mkpath
  end

  def caveats
    <<~EOS
      To start the relay server as a background service:
        brew services start clauderelay

      Create an auth token:
        claude-relay token create --label "my-device"

      Default ports:
        WebSocket: 9200
        Admin API: 9100

      Config stored at: ~/.claude-relay/config.json

      Folder Permissions:
        The service runs in your user context with access to your home directory.
        For access to protected folders (Documents, Desktop, Downloads):
          1. Open System Settings → Privacy & Security → Full Disk Access
          2. Add: #{opt_bin}/claude-relay-server
          3. Toggle it on
    EOS
  end

  test do
    assert_match "claude-relay", shell_output("#{bin}/claude-relay --help")
    assert_match version.to_s, shell_output("#{bin}/claude-relay --version")
  end
end
