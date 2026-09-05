import Foundation

/// How a candidate host address was obtained, which determines whether the
/// apps can reach it over plaintext `ws://`.
enum HostCandidateKind: Equatable {
    /// Bonjour name from `scutil --get LocalHostName`, e.g. `silverwing.local`.
    /// Survives DHCP lease changes, and `.local` is inside the apps'
    /// `NSAllowsLocalNetworking` ATS allowlist.
    case bonjour
    /// RFC1918 or link-local literal from `ipconfig getifaddr en0`. Always
    /// resolves, but goes stale when the lease changes. Inside the apps'
    /// `NSAllowsLocalNetworking` ATS allowlist, so plaintext `ws://` works.
    case lan
    /// `127.0.0.1` — only useful for a Mac pairing to itself.
    case loopback
    /// Tailscale CGNAT (`100.64/10`). ATS has no CIDR allowlist, so plaintext
    /// `ws://` to it is blocked by Apple at the platform layer; it needs `wss://`.
    case cgnat
    /// Public hostname or public IPv4 — anything outside `.local`, loopback,
    /// RFC1918 and link-local. Requires TLS because ATS blocks plaintext to
    /// hosts outside the `NSAllowsLocalNetworking` allowlist.
    case publicHostname
    /// IPv6 address (literal or ULA). Requires TLS because ATS blocks plaintext
    /// to IPv6 addresses outside the local allowlist.
    case ipv6
}

struct HostCandidate: Equatable {
    let host: String
    let kind: HostCandidateKind
}

struct HostAddressResolver {

    /// True when the apps cannot reach this candidate over plaintext `ws://`.
    static func requiresTLS(_ candidate: HostCandidate) -> Bool {
        switch candidate.kind {
        case .cgnat, .publicHostname, .ipv6:
            return true
        case .bonjour, .lan, .loopback:
            return false
        }
    }

    /// Picks the address that goes into the pairing QR.
    ///
    /// Trade-off to weigh: `.bonjour` survives a DHCP lease change and is
    /// ATS-safe, but can fail to resolve on networks with mDNS filtering, where
    /// a `.lan` literal would have worked. `.cgnat` must never win over a
    /// usable local candidate because plaintext `ws://` to it cannot connect
    /// at all.
    ///
    /// Policy: strictly best-reachability-first. `.bonjour` wins because a
    /// stale DHCP literal is the failure we see in practice, while mDNS
    /// filtering is rare. `.cgnat` ranks last but is still returned when it is
    /// the only candidate — the caller checks `requiresTLS` and refuses to
    /// print a `ws://` code rather than reporting "no address found".
    static func choose(from candidates: [HostCandidate]) -> HostCandidate? {
        candidates.min { rank($0.kind) < rank($1.kind) }
    }

    /// Lower is better. A `switch` rather than an ordered array so adding a
    /// `HostCandidateKind` fails to compile until its rank is decided here.
    /// TLS-requiring kinds (.cgnat, .publicHostname, .ipv6) must never outrank
    /// plaintext-safe ones to avoid forcing TLS when a local option exists.
    private static func rank(_ kind: HostCandidateKind) -> Int {
        switch kind {
        case .bonjour:        return 0
        case .lan:            return 1
        case .loopback:       return 2
        case .cgnat:          return 3
        case .publicHostname: return 4
        case .ipv6:           return 5
        }
    }
}

/// Reads the machine's actual addresses. Separate from `HostAddressResolver`
/// so the selection policy stays pure and testable.
struct HostAddressProbe {
    #if os(Linux)
    static func candidates() -> [HostCandidate] {
        var out: [HostCandidate] = []

        // `<hostname>.local` is only a candidate when something answers mDNS
        // for it: Avahi's socket is the cheapest reliable sign the daemon is
        // up. A `.local` name nobody serves would rank first (§AD-9) and fail
        // where the DHCP literal below would have worked.
        if let name = localHostname(), avahiIsRunning() {
            out.append(HostCandidate(host: "\(name).local", kind: .bonjour))
        }

        for (_, ip) in orderedInterfaces(interfaceIPv4Addresses()) {
            out.append(HostCandidate(host: ip, kind: kind(forHost: ip)))
        }

        out.append(HostCandidate(host: "127.0.0.1", kind: .loopback))
        return out
    }

    /// The short host name, lowercased, as Avahi publishes it.
    static func localHostname() -> String? {
        var buffer = [CChar](repeating: 0, count: 256)
        guard gethostname(&buffer, buffer.count - 1) == 0 else { return nil }
        let full = String(cString: buffer).lowercased()
        let short = full.split(separator: ".").first.map(String.init) ?? full
        return short.isEmpty ? nil : short
    }

    static func avahiIsRunning() -> Bool {
        FileManager.default.fileExists(atPath: "/run/avahi-daemon/socket")
    }

    /// Every non-loopback IPv4 address, as `(interface, address)`, in kernel order.
    static func interfaceIPv4Addresses() -> [(name: String, address: String)] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }

        var out: [(name: String, address: String)] = []
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            guard let addr = entry.pointee.ifa_addr,
                  addr.pointee.sa_family == sa_family_t(AF_INET),
                  entry.pointee.ifa_flags & UInt32(IFF_LOOPBACK) == 0,
                  entry.pointee.ifa_flags & UInt32(IFF_UP) != 0
            else { continue }
            var text = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            let converted = addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { sin -> Bool in
                var inAddr = sin.pointee.sin_addr
                return inet_ntop(AF_INET, &inAddr, &text, socklen_t(INET_ADDRSTRLEN)) != nil
            }
            guard converted else { continue }
            out.append((name: String(cString: entry.pointee.ifa_name), address: String(cString: text)))
        }
        return out
    }

    /// Puts physical interfaces first and drops container/VM bridges, so that
    /// among equally-ranked `.lan` literals the one a phone can actually reach
    /// wins `HostAddressResolver.choose`. Tailscale is kept — it classifies as
    /// `.cgnat` and ranks itself — as is anything unrecognised.
    static func orderedInterfaces(
        _ interfaces: [(name: String, address: String)]
    ) -> [(name: String, address: String)] {
        let virtualPrefixes = ["docker", "br-", "veth", "virbr", "vmnet", "lxc", "lxd", "podman", "cni"]
        let physicalPrefixes = ["en", "eth", "wl"]
        let kept = interfaces.filter { iface in
            !virtualPrefixes.contains { iface.name.hasPrefix($0) }
        }
        let physical = kept.filter { iface in physicalPrefixes.contains { iface.name.hasPrefix($0) } }
        let rest = kept.filter { iface in !physicalPrefixes.contains { iface.name.hasPrefix($0) } }
        return physical + rest
    }
    #else
    static func candidates() -> [HostCandidate] {
        var out: [HostCandidate] = []

        if let name = shellOutput(["/usr/sbin/scutil", "--get", "LocalHostName"]),
           !name.isEmpty {
            out.append(HostCandidate(host: "\(name.lowercased()).local", kind: .bonjour))
        }

        for interface in ["en0", "en1"] {
            if let ip = shellOutput(["/usr/sbin/ipconfig", "getifaddr", interface]), !ip.isEmpty {
                out.append(HostCandidate(host: ip, kind: kind(forHost: ip)))
            }
        }

        out.append(HostCandidate(host: "127.0.0.1", kind: .loopback))
        return out
    }
    #endif

    /// Classifies a host address string. IPv4 octets classify based on prefix;
    /// IPv6 literals return `.ipv6`; `.local` Bonjour names return `.bonjour`;
    /// everything else is `.publicHostname`.
    static func kind(forHost ip: String) -> HostCandidateKind {
        // IPv6 literal detection: contains colon.
        if ip.contains(":") {
            return .ipv6
        }

        // Bonjour .local hostname.
        if ip.hasSuffix(".local") {
            return .bonjour
        }

        // IPv4 literal classification.
        let parts = ip.split(separator: ".").compactMap { Int($0) }
        if parts.count == 4 {
            // Tailscale CGNAT: 100.64/10
            if parts[0] == 100 && parts[1] >= 64 && parts[1] <= 127 { return .cgnat }
            // Loopback: 127.0.0.0/8
            if parts[0] == 127 { return .loopback }
            // RFC1918: 10/8, 172.16/12, 192.168/16
            if parts[0] == 10 { return .lan }
            if parts[0] == 172 && parts[1] >= 16 && parts[1] <= 31 { return .lan }
            if parts[0] == 192 && parts[1] == 168 { return .lan }
            // Link-local (169.254/16). Not RFC1918, but the apps'
            // NSAllowsLocalNetworking covers it, so it is plaintext-safe and
            // belongs in the same reachability bucket as a LAN literal.
            if parts[0] == 169 && parts[1] == 254 { return .lan }
            // Public IPv4.
            return .publicHostname
        }

        // Not an IPv4 literal — treat as hostname.
        if ip == "localhost" { return .loopback }
        return .publicHostname
    }

    #if !os(Linux)
    private static func shellOutput(_ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: arguments[0])
        process.arguments = Array(arguments.dropFirst())
        let pipe = Pipe()
        process.standardOutput = pipe
        // Deliberately discard stderr: `ipconfig getifaddr en1` fails routinely on
        // machines with no second interface. Letting that reach the terminal on
        // every `setup` would be noise.
        process.standardError = Pipe()
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    #endif
}
