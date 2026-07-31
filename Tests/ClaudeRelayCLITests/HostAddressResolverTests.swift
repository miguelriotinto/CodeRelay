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
}
