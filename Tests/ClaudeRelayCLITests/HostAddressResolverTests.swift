import XCTest
@testable import ClaudeRelayCLI

final class HostAddressResolverTests: XCTestCase {

    private let bonjour = HostCandidate(host: "silverwing.local", kind: .bonjour)
    private let lan = HostCandidate(host: "192.168.1.42", kind: .lan)
    private let loopback = HostCandidate(host: "127.0.0.1", kind: .loopback)
    private let cgnat = HostCandidate(host: "100.101.102.103", kind: .cgnat)

    func testPrefersBonjourOverLAN() {
        XCTAssertEqual(HostAddressResolver.choose(from: [lan, bonjour]), bonjour)
    }

    func testFallsBackToLANWhenNoBonjourName() {
        XCTAssertEqual(HostAddressResolver.choose(from: [loopback, lan]), lan)
    }

    func testFallsBackToLoopbackAsLastResort() {
        XCTAssertEqual(HostAddressResolver.choose(from: [loopback]), loopback)
    }

    func testNeverSilentlyChoosesCGNAT() {
        // ATS has no CIDR allowlist, so plaintext ws:// to Tailscale CGNAT is
        // blocked by the platform. It must not be selected over a usable option.
        XCTAssertEqual(HostAddressResolver.choose(from: [cgnat, lan]), lan)
        XCTAssertEqual(HostAddressResolver.choose(from: [cgnat, bonjour]), bonjour)
    }

    func testReturnsNilWhenNoCandidates() {
        XCTAssertNil(HostAddressResolver.choose(from: []))
    }

    func testCGNATRequiresTLS() {
        XCTAssertTrue(HostAddressResolver.requiresTLS(cgnat))
    }

    func testLocalCandidatesDoNotRequireTLS() {
        XCTAssertFalse(HostAddressResolver.requiresTLS(bonjour))
        XCTAssertFalse(HostAddressResolver.requiresTLS(lan))
        XCTAssertFalse(HostAddressResolver.requiresTLS(loopback))
    }

    func testCGNATRangeIsClassifiedFromIPv4() {
        XCTAssertEqual(HostAddressProbe.kind(forIPv4: "100.101.102.103"), .cgnat)
        XCTAssertEqual(HostAddressProbe.kind(forIPv4: "100.64.0.1"), .cgnat)
        XCTAssertEqual(HostAddressProbe.kind(forIPv4: "100.127.255.254"), .cgnat)
        // 100.128.x is outside 100.64/10 and is a normal address.
        XCTAssertEqual(HostAddressProbe.kind(forIPv4: "100.128.0.1"), .publicHostname)
        XCTAssertEqual(HostAddressProbe.kind(forIPv4: "192.168.1.42"), .lan)
        XCTAssertEqual(HostAddressProbe.kind(forIPv4: "127.0.0.1"), .loopback)
    }

    func testPublicHostnameRequiresTLS() {
        let publicHost = HostCandidate(host: "relay.example.com", kind: .publicHostname)
        XCTAssertTrue(HostAddressResolver.requiresTLS(publicHost))
    }

    func testIPv6RequiresTLS() {
        let ipv6 = HostCandidate(host: "2001:db8::1", kind: .ipv6)
        XCTAssertTrue(HostAddressResolver.requiresTLS(ipv6))
    }

    func testPublicHostnameClassification() {
        XCTAssertEqual(HostAddressProbe.kind(forIPv4: "relay.example.com"), .publicHostname)
        XCTAssertEqual(HostAddressProbe.kind(forIPv4: "8.8.8.8"), .publicHostname)
        XCTAssertEqual(HostAddressProbe.kind(forIPv4: "1.2.3.4"), .publicHostname)
    }

    func testIPv6Classification() {
        XCTAssertEqual(HostAddressProbe.kind(forIPv4: "2001:db8::1"), .ipv6)
        XCTAssertEqual(HostAddressProbe.kind(forIPv4: "::1"), .ipv6)
        XCTAssertEqual(HostAddressProbe.kind(forIPv4: "fe80::1"), .ipv6)
    }

    func testBonjourClassification() {
        XCTAssertEqual(HostAddressProbe.kind(forIPv4: "silverwing.local"), .bonjour)
        XCTAssertEqual(HostAddressProbe.kind(forIPv4: "mymac.local"), .bonjour)
    }

    func testLocalhostClassification() {
        XCTAssertEqual(HostAddressProbe.kind(forIPv4: "localhost"), .loopback)
    }

    func testRFC1918Classification() {
        XCTAssertEqual(HostAddressProbe.kind(forIPv4: "10.0.0.1"), .lan)
        XCTAssertEqual(HostAddressProbe.kind(forIPv4: "172.16.0.1"), .lan)
        XCTAssertEqual(HostAddressProbe.kind(forIPv4: "172.31.255.254"), .lan)
        XCTAssertEqual(HostAddressProbe.kind(forIPv4: "192.168.0.1"), .lan)
        // 172.15 and 172.32 are outside the RFC1918 range.
        XCTAssertEqual(HostAddressProbe.kind(forIPv4: "172.15.0.1"), .publicHostname)
        XCTAssertEqual(HostAddressProbe.kind(forIPv4: "172.32.0.1"), .publicHostname)
    }

    func testTLSRequiringKindsNeverOutrankPlaintextSafe() {
        let candidates = [
            HostCandidate(host: "relay.example.com", kind: .publicHostname),
            HostCandidate(host: "2001:db8::1", kind: .ipv6),
            HostCandidate(host: "100.101.102.103", kind: .cgnat),
            HostCandidate(host: "192.168.1.42", kind: .lan)
        ]
        // .lan must win over all TLS-requiring kinds.
        XCTAssertEqual(HostAddressResolver.choose(from: candidates)?.kind, .lan)
    }

    func testAutoSelectionPriorityIsUnchanged() {
        // Existing priority: bonjour > lan > loopback > cgnat
        let all = [
            HostCandidate(host: "127.0.0.1", kind: .loopback),
            HostCandidate(host: "192.168.1.42", kind: .lan),
            HostCandidate(host: "silverwing.local", kind: .bonjour),
            HostCandidate(host: "100.101.102.103", kind: .cgnat)
        ]
        XCTAssertEqual(HostAddressResolver.choose(from: all)?.kind, .bonjour)

        let noBonjour = [
            HostCandidate(host: "127.0.0.1", kind: .loopback),
            HostCandidate(host: "192.168.1.42", kind: .lan),
            HostCandidate(host: "100.101.102.103", kind: .cgnat)
        ]
        XCTAssertEqual(HostAddressResolver.choose(from: noBonjour)?.kind, .lan)
    }
}
