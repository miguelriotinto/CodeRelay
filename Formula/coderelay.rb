class Coderelay < Formula
  desc "Remote terminal relay server and CLI over WebSocket"
  homepage "https://github.com/miguelriotinto/CodeRelay"
  url "https://github.com/miguelriotinto/CodeRelay/archive/refs/tags/v0.3.42.tar.gz"
  sha256 "61fabc51a0c40c88edead94e261b6b0a25a8812bd37e12bb33ee8150bba3e155"
  license "MIT"
  head "https://github.com/miguelriotinto/CodeRelay.git", branch: "main"

  bottle do
    root_url "https://github.com/miguelriotinto/CodeRelay/releases/download/v0.3.42"
    sha256 cellar: "/opt/homebrew/Cellar", arm64_golden_gate: "f94df1525bf711698ae445620db46bea398f3897250555c0709b2d185f5874ca"
  end

  depends_on xcode: ["15.0", :build]
  depends_on :macos

  def install
    system "swift", "build",
           "-c", "release",
           "--disable-sandbox",
           "-Xswiftc", "-cross-module-optimization",
           "--product", "claude-relay-server"
    # No cross-module optimization for the CLI: with the Xcode 27 toolchain it
    # drops ArgumentParser conformance descriptors and the link fails.
    system "swift", "build",
           "-c", "release",
           "--disable-sandbox",
           "--product", "claude-relay"
    bin.install ".build/release/claude-relay"
    bin.install ".build/release/claude-relay-server"
    # CodeRelayServer bundles agent-detection manifests (Resources/Agents)
    # loaded at runtime via `Bundle.module`, which resolves the bundle next to
    # the executable. Without this, the server fatal-errors on the first
    # agent-detection path (session create). See resource_bundle_accessor.swift.
    bin.install ".build/release/CodeRelay_CodeRelayServer.bundle"
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
        brew services start coderelay

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
