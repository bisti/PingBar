import XCTest
@testable import PingBarCore

final class PingParserTests: XCTestCase {
    func testParsesLatencyFromPacketLine() {
        let output = """
        64 bytes from 1.1.1.1: icmp_seq=0 ttl=57 time=12.345 ms
        """

        XCTAssertEqual(PingParser.latencyMilliseconds(from: output), 12.345)
    }

    func testParsesLatencyFromLessThanPacketLine() {
        let output = """
        64 bytes from 1.1.1.1: icmp_seq=0 ttl=57 time<1 ms
        """

        XCTAssertEqual(PingParser.latencyMilliseconds(from: output), 1)
    }

    func testParsesLatencyFromRoundTripSummary() {
        let output = """
        round-trip min/avg/max/stddev = 9.100/10.200/11.300/0.400 ms
        """

        XCTAssertEqual(PingParser.latencyMilliseconds(from: output), 10.2)
    }

    func testRejectsOptionLikeHost() {
        XCTAssertNil(PingParser.sanitizedHost(from: "-c 100"))
    }

    func testAcceptsDomainHost() {
        XCTAssertEqual(PingParser.sanitizedHost(from: " cloudflare.com "), "cloudflare.com")
    }
}
