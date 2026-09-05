import Foundation
import XCTest
@testable import RehireBar

final class CodexDesktopIPCProtocolTests: XCTestCase {
    func testReplyRequestTargetsExactThreadAndUsesFixedResponse() throws {
        let thread = "10000000-0000-4000-8000-000000000002"
        let payload = try CodexDesktopIPCMessageFactory.replyRequest(requestID: "r", clientID: "c", threadID: thread, text: "อนุมัติ ดำเนินการต่อได้")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: payload) as? [String: Any])
        XCTAssertEqual(json["method"] as? String, "thread-follower-submit-user-message")
        XCTAssertEqual((json["params"] as? [String: Any])?["conversationId"] as? String, thread)
    }
    func testFramePrefixesPayloadWithLittleEndianLength() {
        let payload = Data(#"{"type":"request"}"#.utf8)

        let frame = CodexDesktopIPCFrameCodec.encode(payload)

        XCTAssertEqual(frame.prefix(4), Data([18, 0, 0, 0]))
        XCTAssertEqual(frame.dropFirst(4), payload)
    }

    func testFrameDecoderWaitsForACompleteFrame() throws {
        let payload = Data(#"{"type":"response"}"#.utf8)
        let frame = CodexDesktopIPCFrameCodec.encode(payload)
        var decoder = CodexDesktopIPCFrameDecoder()

        XCTAssertEqual(try decoder.append(frame.prefix(3)), [])
        XCTAssertEqual(try decoder.append(frame.dropFirst(3).prefix(5)), [])
        XCTAssertEqual(try decoder.append(frame.dropFirst(8)), [payload])
    }

    func testHistoryRequestTargetsExactThread() throws {
        let payload = try CodexDesktopIPCMessageFactory.historyRequest(
            requestID: "request-id",
            clientID: "client-id",
            threadID: "thread-id",
            ownerClientID: "owner-id"
        )
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: payload) as? [String: Any])
        XCTAssertEqual(json["version"] as? Int, 1)
        XCTAssertEqual(json["method"] as? String, "thread-follower-load-complete-history")
        XCTAssertEqual((json["params"] as? [String: Any])?["conversationId"] as? String, "thread-id")
        XCTAssertEqual(json["targetClientId"] as? String, "owner-id")
    }

    func testFollowingBroadcastRegistersAndUnregistersTheExactThread() throws {
        for following in [true, false] {
            let payload = try CodexDesktopIPCMessageFactory.followingChangedBroadcast(
                clientID: "client-id",
                threadID: "thread-id",
                hostID: "local",
                following: following
            )
            let json = try XCTUnwrap(
                JSONSerialization.jsonObject(with: payload) as? [String: Any]
            )
            let params = try XCTUnwrap(json["params"] as? [String: Any])

            XCTAssertEqual(json["type"] as? String, "broadcast")
            XCTAssertEqual(json["sourceClientId"] as? String, "client-id")
            XCTAssertEqual(json["version"] as? Int, 1)
            XCTAssertEqual(json["method"] as? String, "thread-stream-following-changed")
            XCTAssertEqual(params["conversationId"] as? String, "thread-id")
            XCTAssertEqual(params["hostId"] as? String, "local")
            XCTAssertEqual(params["following"] as? Bool, following)
        }
    }

    func testOwnerDiscoveryTargetsHostAndThread() throws {
        let payload = try CodexDesktopIPCMessageFactory.ownerDiscoveryRequest(
            requestID: "request-id",
            clientID: "client-id",
            threadID: "thread-id",
            hostID: "remote-host"
        )
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: payload) as? [String: Any])
        let params = try XCTUnwrap(json["params"] as? [String: Any])
        XCTAssertEqual(json["method"] as? String, "thread-owner-discovery")
        XCTAssertEqual(params["hostId"] as? String, "remote-host")
        XCTAssertEqual(params["conversationId"] as? String, "thread-id")
    }

    func testSnapshotExtractsTokenUsageRuntimeAndModelWithoutConversationContent() throws {
        let payload = Data(#"{"type":"broadcast","method":"thread-stream-state-changed","params":{"conversationId":"thread-id","change":{"type":"snapshot","conversationState":{"threadRuntimeStatus":{"type":"active","activeFlags":["waitingOnUserInput"]},"latestTokenUsageInfo":{"last":{"totalTokens":196000},"modelContextWindow":258000},"latestModel":"gpt-5.6-sol","latestReasoningEffort":"xhigh","latestServiceTier":"priority","messages":[{"text":"private"}]}}}}"#.utf8)

        let snapshot = try XCTUnwrap(
            CodexDesktopIPCMessageFactory.threadSnapshot(
                in: payload,
                identity: .init(hostID: "local", threadID: "thread-id")
            )
        )

        XCTAssertEqual(snapshot.usedTokens, 196_000)
        XCTAssertEqual(snapshot.contextWindow, 258_000)
        XCTAssertEqual(snapshot.model, "gpt-5.6-sol")
        XCTAssertEqual(snapshot.effort, "xhigh")
        XCTAssertEqual(snapshot.serviceTier, "priority")
        XCTAssertEqual(snapshot.executionState, .waiting)
        XCTAssertEqual(snapshot.isCompactingContext, false)
    }

    func testSnapshotUsesLatestThreadSettingsEffortWhenLegacyFieldIsNull() throws {
        let payload = Data(#"{"type":"broadcast","method":"thread-stream-state-changed","params":{"conversationId":"thread-id","change":{"type":"snapshot","conversationState":{"latestReasoningEffort":null,"latestThreadSettings":{"model":"gpt-5.6-sol","effort":"xhigh"}}}}}"#.utf8)

        let snapshot = try XCTUnwrap(CodexDesktopIPCMessageFactory.threadSnapshot(
            in: payload,
            identity: TaskIdentity(hostID: "local", threadID: "thread-id")
        ))

        XCTAssertEqual(snapshot.effort, "xhigh")
    }

    func testSnapshotMarksContextCompactionOnlyWhileItIsInProgress() throws {
        let active = Data(#"{"type":"broadcast","method":"thread-stream-state-changed","params":{"conversationId":"thread-id","change":{"type":"snapshot","conversationState":{"items":[{"type":"contextCompaction","completed":false}]}}}}"#.utf8)
        let completed = Data(#"{"type":"broadcast","method":"thread-stream-state-changed","params":{"conversationId":"thread-id","change":{"type":"snapshot","conversationState":{"items":[{"type":"contextCompaction","completed":true}]}}}}"#.utf8)

        let activeSnapshot = try XCTUnwrap(
            CodexDesktopIPCMessageFactory.threadSnapshot(
                in: active,
                identity: .init(hostID: "local", threadID: "thread-id")
            )
        )
        let completedSnapshot = try XCTUnwrap(
            CodexDesktopIPCMessageFactory.threadSnapshot(
                in: completed,
                identity: .init(hostID: "local", threadID: "thread-id")
            )
        )

        XCTAssertEqual(activeSnapshot.isCompactingContext, true)
        XCTAssertEqual(completedSnapshot.isCompactingContext, false)
    }

    func testSnapshotFindsInProgressCompactionInsideCanonicalTurnHistory() throws {
        let payload = Data(#"{"type":"broadcast","method":"thread-stream-state-changed","params":{"conversationId":"thread-id","change":{"type":"snapshot","conversationState":{"turnHistory":{"kind":"canonical","history":{"entitiesByKey":{"turn:latest":{"items":[{"type":"contextCompaction","id":"compact-id","completed":false,"source":"automatic"}]}}}}}}}}"#.utf8)

        let snapshot = try XCTUnwrap(
            CodexDesktopIPCMessageFactory.threadSnapshot(
                in: payload,
                identity: .init(hostID: "local", threadID: "thread-id")
            )
        )

        XCTAssertEqual(snapshot.isCompactingContext, true)
    }

    func testRemoteControlSnapshotPreservesExactIdentityAndObservationSource() throws {
        let identity = TaskIdentity(
            hostID: "remote-control:environment-private",
            threadID: "thread-id"
        )
        let observedAt = Date(timeIntervalSince1970: 42)
        let payload = Data(#"{"type":"broadcast","method":"thread-stream-state-changed","params":{"conversationId":"thread-id","hostId":"remote-control:environment-private","change":{"type":"snapshot","conversationState":{"threadRuntimeStatus":{"type":"idle"},"latestTokenUsageInfo":{"last":{"totalTokens":10},"modelContextWindow":100},"latestModel":"gpt-next","latestReasoningEffort":"medium"}}}}"#.utf8)

        let snapshot = try XCTUnwrap(CodexDesktopIPCMessageFactory.threadSnapshot(
            in: payload,
            identity: identity,
            observedAt: observedAt
        ))

        XCTAssertEqual(snapshot.identity, identity)
        XCTAssertEqual(snapshot.source, .desktopOwnerIPC)
        XCTAssertEqual(snapshot.observedAt, observedAt)
        XCTAssertEqual(snapshot.executionState, .idle)
        XCTAssertEqual(snapshot.usedTokens, 10)
        XCTAssertEqual(snapshot.contextWindow, 100)
    }

    func testSnapshotRejectsAHostMismatchEvenWhenThreadIDMatches() throws {
        let payload = Data(#"{"type":"broadcast","method":"thread-stream-state-changed","params":{"conversationId":"thread-id","hostId":"remote-control:other","change":{"type":"snapshot","conversationState":{"threadRuntimeStatus":{"type":"active"}}}}}"#.utf8)

        let snapshot = try CodexDesktopIPCMessageFactory.threadSnapshot(
            in: payload,
            identity: TaskIdentity(hostID: "remote-control:expected", threadID: "thread-id")
        )

        XCTAssertNil(snapshot)
    }

    func testContextDoesNotFallBackToCumulativeTotalTokens() throws {
        let payload = Data(#"{"type":"broadcast","method":"thread-stream-state-changed","params":{"conversationId":"thread-id","change":{"type":"snapshot","conversationState":{"latestTokenUsageInfo":{"total":{"totalTokens":999999},"modelContextWindow":200000}}}}}"#.utf8)

        let snapshot = try XCTUnwrap(CodexDesktopIPCMessageFactory.threadSnapshot(
            in: payload,
            identity: TaskIdentity(hostID: "local", threadID: "thread-id")
        ))

        XCTAssertNil(snapshot.usedTokens)
        XCTAssertEqual(snapshot.contextWindow, 200_000)
    }

    func testCurrentTurnRerouteModelOverridesConfiguredModel() throws {
        let payload = Data(#"{"type":"broadcast","method":"thread-stream-state-changed","params":{"conversationId":"thread-id","change":{"type":"snapshot","conversationState":{"threadRuntimeStatus":{"type":"active"},"latestModel":"gpt-configured","items":[{"type":"model/rerouted","toModel":"gpt-actual"}]}}}}"#.utf8)

        let snapshot = try XCTUnwrap(CodexDesktopIPCMessageFactory.threadSnapshot(
            in: payload,
            identity: TaskIdentity(hostID: "local", threadID: "thread-id")
        ))

        XCTAssertEqual(snapshot.model, "gpt-actual")
    }

    func testStatusReadMethodsExcludeTaskControlAndPairingOperations() {
        let forbidden = Set([
            "thread/resume", "turn/start", "turn/interrupt", "turn/steer",
            "remoteControl/pairing/start", "remoteControl/status/read",
        ])

        XCTAssertTrue(CodexDesktopIPCMessageFactory.statusReadMethods.isDisjoint(with: forbidden))
    }

    func testDiagnosticsTruncateIdentifiersAndNeverExposeErrorBodies() {
        let identifier = SanitizedDiagnostic.identifier("12345678-secret-tail")
        let error = SanitizedDiagnostic.errorCategory([
            "code": "no-client-found",
            "message": "private response body",
        ])

        XCTAssertEqual(identifier, "12345678")
        XCTAssertEqual(error, "no-client-found")
        XCTAssertFalse(error.contains("private"))
    }

    func testUnrelatedClientDiscoveryIsRejectedWithoutClaimingOwnership() throws {
        let request = Data(
            #"{"type":"client-discovery-request","requestId":"discovery-id","request":{}}"#.utf8
        )
        let response = try XCTUnwrap(
            CodexDesktopIPCMessageFactory.clientDiscoveryRejection(for: request)
        )
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: response) as? [String: Any])

        XCTAssertEqual(json["type"] as? String, "client-discovery-response")
        XCTAssertEqual(json["requestId"] as? String, "discovery-id")
        XCTAssertEqual((json["response"] as? [String: Any])?["canHandle"] as? Bool, false)
    }
}
