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
}

struct HostCandidate: Equatable {
    let host: String
    let kind: HostCandidateKind
}

struct HostAddressResolver {

    /// True when the apps cannot reach this candidate over plaintext `ws://`.
    static func requiresTLS(_ candidate: HostCandidate) -> Bool {
        candidate.kind == .cgnat
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
    private static func rank(_ kind: HostCandidateKind) -> Int {
        switch kind {
        case .bonjour:  return 0
        case .lan:      return 1
        case .loopback: return 2
        case .cgnat:    return 3
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

    /// Tailscale hands out `100.64/10`; treat that range as CGNAT.
    static func kind(forIPv4 ip: String) -> HostCandidateKind {
        let parts = ip.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4 else { return .lan }
        if parts[0] == 100 && parts[1] >= 64 && parts[1] <= 127 { return .cgnat }
        if parts[0] == 127 { return .loopback }
        return .lan
    }

    private static func shellOutput(_ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: arguments[0])
        process.arguments = Array(arguments.dropFirst())
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
