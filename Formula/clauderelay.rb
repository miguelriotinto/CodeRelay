class Clauderelay < Formula
  desc "Remote terminal relay server and CLI over WebSocket"
  homepage "https://github.com/miguelriotinto/ClaudeRelay"
  url "https://github.com/miguelriotinto/ClaudeRelay/archive/refs/tags/v0.3.18.tar.gz"
  sha256 "04b0f16bec09e8133a8ed4b864330b851690162c423ef6faadcfd4c858f6c3ca"
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
    # ClaudeRelayServer bundles agent-detection manifests (Resources/Agents)
    # loaded at runtime via `Bundle.module`, which resolves the bundle next to
    # the executable. Without this, the server fatal-errors on the first
    # agent-detection path (session create). See resource_bundle_accessor.swift.
    bin.install ".build/release/ClaudeRelay_ClaudeRelayServer.bundle"
    # State hook script is located by `claude-relay hook install` via
    # HookInstallCommand.locateBundledScript(), which checks pkgshare among
    # other candidates.
    pkgshare.install "Scripts/hooks/claude-relay-state-hook.sh"
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
