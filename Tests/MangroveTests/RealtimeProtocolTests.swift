import XCTest
@testable import Mangrove

/// The save path depends on Overleaf's socket.io 0.9 framing, which cannot be
/// reached without a live account. These pin the pieces that must be exactly
/// right: the handshake reply, the packet encoding, and the folder id the join
/// response has to yield.
final class RealtimeProtocolTests: XCTestCase {

    // MARK: Handshake

    func testHandshakeReplyIsParsed() throws {
        let reply = "0AtgsUg6-rYJd1Wx62Lv:60:60:websocket,xhr-polling"
        let handshake = try XCTUnwrap(SocketHandshake.parse(reply))
        XCTAssertEqual(handshake.sid, "0AtgsUg6-rYJd1Wx62Lv")
        XCTAssertEqual(handshake.heartbeatInterval, 60)
        XCTAssertEqual(handshake.closeTimeout, 60)
        XCTAssertEqual(handshake.transports, ["websocket", "xhr-polling"])
    }

    func testHandshakeRejectsHTMLErrorPages() {
        XCTAssertNil(SocketHandshake.parse("<html><body>Error</body></html>"))
        XCTAssertNil(SocketHandshake.parse(""))
    }

    // MARK: Packet framing

    func testDecodesAnEventPacket() throws {
        let packet = try XCTUnwrap(
            SocketIO09.decode(#"5:::{"name":"joinProjectResponse","args":[{"a":1}]}"#)
        )
        XCTAssertEqual(packet.type, "event")
        XCTAssertEqual(packet.id, "")
        XCTAssertEqual(packet.endpoint, "")

        let event = try XCTUnwrap(SocketIO09.event(in: packet))
        XCTAssertEqual(event.name, "joinProjectResponse")
        XCTAssertEqual(event.args.count, 1)
    }

    func testDecodesConnectPacketWithNoData() throws {
        let packet = try XCTUnwrap(SocketIO09.decode("1::"))
        XCTAssertEqual(packet.type, "connect")
        XCTAssertEqual(packet.data, "")
    }

    func testDecodesDisconnectPacket() throws {
        let packet = try XCTUnwrap(SocketIO09.decode("0::"))
        XCTAssertEqual(packet.type, "disconnect")
    }

    func testRejectsGarbage() {
        XCTAssertNil(SocketIO09.decode("not-a-packet"))
        XCTAssertNil(SocketIO09.decode("99::"))
    }

    func testSplitsLengthPrefixedPayloads() {
        // The prefix is a character count, as in socket.io's own encoder.
        let payload = "\u{FFFD}3\u{FFFD}1::\u{FFFD}7\u{FFFD}2::test"
        XCTAssertEqual(SocketIO09.splitPayload(payload), ["1::", "2::test"])
    }

    func testSinglePacketPayloadPassesThrough() {
        let payload = #"5:::{"name":"x","args":[]}"#
        XCTAssertEqual(SocketIO09.splitPayload(payload), [payload])
    }

    // MARK: Join payload

    func testRootFolderIdComesFromJoinPayload() {
        let payload: [String: Any] = [
            "project": [
                "name": "Paper",
                "rootFolder": [
                    ["_id": "root123", "docs": [], "fileRefs": [], "folders": []],
                ],
            ] as [String: Any],
        ]
        XCTAssertEqual(ProjectTreeIds.rootFolderId(fromJoinPayload: payload), "root123")
    }

    func testRootFolderIdFallsBackToNestedFolder() {
        let payload: [String: Any] = [
            "project": [
                "rootFolder": [
                    ["documents": [], "folders": [["_id": "nested456", "folders": []]]],
                ],
            ] as [String: Any],
        ]
        XCTAssertEqual(ProjectTreeIds.rootFolderId(fromJoinPayload: payload), "nested456")
    }

    func testMissingFolderStructureIsReportedAsNil() {
        XCTAssertNil(ProjectTreeIds.rootFolderId(fromJoinPayload: [:]))
        XCTAssertNil(ProjectTreeIds.rootFolderId(fromJoinPayload: ["project": [String: Any]()]))
    }

    // MARK: Rejection wording

    func testInvalidSessionMeansSignInAgain() {
        guard case MangroveError.notAuthenticated = RealtimeChannel.describeRejection("invalid session") else {
            return XCTFail("expected notAuthenticated")
        }
        guard case MangroveError.notAuthenticated = RealtimeChannel.describeRejection("not authorized") else {
            return XCTFail("expected notAuthenticated")
        }
    }

    func testRateLimitIsExplainedPlainly() {
        let error = RealtimeChannel.describeRejection("rate-limit hit when joining project")
        XCTAssertTrue(error.errorDescription?.contains("limiting") ?? false)
    }

    // MARK: Live transport

    /// Exercises the real handshake, WebSocket upgrade and framing against
    /// overleaf.com. Without a session cookie the server must stop at its
    /// session check, which proves every step before authentication works.
    ///
    /// Skipped by default so the suite stays offline; run it with
    /// `MANGROVE_LIVE_PROTOCOL=1 swift test --filter testLiveRealtimeChannel`.
    func testLiveRealtimeChannelReachesSessionCheck() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["MANGROVE_LIVE_PROTOCOL"] == "1")

        let channel = RealtimeChannel(
            baseURL: URL(string: "https://www.overleaf.com")!,
            cookieHeader: "",
            userAgent: OverleafClient.userAgent,
            timeout: 20
        )

        do {
            _ = try await channel.joinProject("0123456789abcdef01234567")
            XCTFail("An unauthenticated join must not succeed")
        } catch let error as MangroveError {
            guard case MangroveError.notAuthenticated = error else {
                return XCTFail("Expected a session rejection, got: \(String(describing: error.errorDescription))")
            }
        }
    }
}
