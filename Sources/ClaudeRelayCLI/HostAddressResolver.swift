import Foundation

/// How a candidate host address was obtained, which determines whether the
/// apps can reach it over plaintext `ws://`.
enum HostCandidateKind: Equatable {
    /// Bonjour name from `scutil --get LocalHostName`, e.g. `silverwing.local`.
    /// Survives DHCP lease changes, and `.local` is inside the apps'
    /// `NSAllowsLocalNetworking` ATS allowlist.
    case bonjour
    /// RFC1918 literal from `ipconfig getifaddr en0`. Always resolves, but goes
    /// stale when the lease changes.
    case lan
    /// `127.0.0.1` — only useful for a Mac pairing to itself.
    case loopback
    /// Tailscale CGNAT (`100.64/10`). ATS has no CIDR allowlist, so plaintext
    /// `ws://` to it is blocked by Apple at the platform layer; it needs `wss://`.
    case cgnat
    /// Public hostname (anything that is not `.local`, loopback, or RFC1918).
    /// Requires TLS because ATS blocks plaintext to non-local hostnames.
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
    static func candidates() -> [HostCandidate] {
        var out: [HostCandidate] = []

        if let name = shellOutput(["/usr/sbin/scutil", "--get", "LocalHostName"]),
           !name.isEmpty {
            out.append(HostCandidate(host: "\(name.lowercased()).local", kind: .bonjour))
        }

        for interface in ["en0", "en1"] {
            if let ip = shellOutput(["/usr/sbin/ipconfig", "getifaddr", interface]), !ip.isEmpty {
                out.append(HostCandidate(host: ip, kind: kind(forIPv4: ip)))
            }
        }

        out.append(HostCandidate(host: "127.0.0.1", kind: .loopback))
        return out
    }

    /// Classifies a host address string. IPv4 octets classify based on prefix;
    /// IPv6 literals return `.ipv6`; `.local` Bonjour names return `.bonjour`;
    /// everything else is `.publicHostname`.
    static func kind(forIPv4 ip: String) -> HostCandidateKind {
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
            // Public IPv4.
            return .publicHostname
        }

        // Not an IPv4 literal — treat as hostname.
        if ip == "localhost" { return .loopback }
        return .publicHostname
    }

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
}
