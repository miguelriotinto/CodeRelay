#if os(Linux)
import XCTest
@testable import ClaudeRelayCLI

/// The Linux `HostAddressProbe`: interface ordering is pure; the readers are
/// checked against this host (`docs/linux-server-spec.md` AD-9).
final class HostAddressProbeLinuxTests: XCTestCase {

    private typealias Interface = (name: String, address: String)

    func testPhysicalInterfacesComeFirstAndBridgesAreDropped() {
        let ordered = HostAddressProbe.orderedInterfaces([
            (name: "docker0", address: "172.17.0.1"),
            (name: "tailscale0", address: "100.101.102.103"),
            (name: "wlp0s20f3", address: "192.168.10.136"),
            (name: "br-1a2b3c", address: "172.18.0.1"),
            (name: "veth9f2", address: "10.0.3.1"),
            (name: "enp3s0", address: "192.168.1.20"),
        ])
        XCTAssertEqual(ordered.map(\.name), ["wlp0s20f3", "enp3s0", "tailscale0"])
    }

    /// Given that ordering, `choose` picks the LAN literal over Tailscale's
    /// CGNAT address even though both were reported — the same policy the
    /// macOS probe gets by only ever asking about en0/en1.
    func testChoosePrefersTheLANLiteralOverTailscale() {
        let candidates = HostAddressProbe.orderedInterfaces([
            (name: "tailscale0", address: "100.101.102.103"),
            (name: "wlp0s20f3", address: "192.168.10.136"),
        ]).map { HostCandidate(host: $0.address, kind: HostAddressProbe.kind(forHost: $0.address)) }
        XCTAssertEqual(HostAddressResolver.choose(from: candidates)?.host, "192.168.10.136")
    }

    /// A self-assigned 169.254 address classifies as `.lan` (shared with macOS,
    /// because the apps' ATS allowlist covers it), so it ties with a routable
    /// RFC1918 literal on rank and order alone would decide. Nothing else on the
    /// network can reach a link-local address, so it must sort last.
    func testLinkLocalSortsBelowRoutableAddresses() {
        let ordered = HostAddressProbe.orderedInterfaces([
            (name: "enp3s0", address: "169.254.12.7"),
            (name: "wlp0s20f3", address: "192.168.10.136"),
        ])
        XCTAssertEqual(ordered.map(\.address), ["192.168.10.136", "169.254.12.7"])

        let candidates = ordered.map {
            HostCandidate(host: $0.address, kind: HostAddressProbe.kind(forHost: $0.address))
        }
        XCTAssertEqual(HostAddressResolver.choose(from: candidates)?.host, "192.168.10.136")
    }

    /// But it is still offered when it is all there is — the caller checks
    /// `requiresTLS` and prints a code; reporting "no address" would be worse.
    func testLinkLocalIsStillReturnedWhenItIsTheOnlyAddress() {
        let ordered = HostAddressProbe.orderedInterfaces([
            (name: "enp3s0", address: "169.254.12.7"),
        ])
        XCTAssertEqual(ordered.map(\.address), ["169.254.12.7"])
    }

    func testLocalHostnameIsShortAndLowercase() throws {
        let name = try XCTUnwrap(HostAddressProbe.localHostname())
        XCTAssertFalse(name.contains("."))
        XCTAssertEqual(name, name.lowercased())
    }

    func testInterfaceEnumerationExcludesLoopback() {
        let addresses = HostAddressProbe.interfaceIPv4Addresses()
        XCTAssertFalse(addresses.contains { $0.name == "lo" || $0.address.hasPrefix("127.") })
    }

    func testCandidatesAlwaysEndWithLoopback() {
        let candidates = HostAddressProbe.candidates()
        XCTAssertEqual(candidates.last, HostCandidate(host: "127.0.0.1", kind: .loopback))
        for candidate in candidates where candidate.kind == .bonjour {
            XCTAssertTrue(candidate.host.hasSuffix(".local"))
        }
    }
}
#endif
