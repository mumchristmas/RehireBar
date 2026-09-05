import Foundation

protocol DesktopThreadSnapshotFetching: Sendable {
    func fetchThreadSnapshot(
        threadID: String,
        hostID: String
    ) async throws -> CodexDesktopThreadSnapshot
}

protocol DesktopThreadSnapshotCaching: DesktopThreadSnapshotFetching {
    func cachedThreadSnapshot(
        threadID: String,
        hostID: String
    ) async -> CodexDesktopThreadSnapshot?

    func fetchThreadSnapshot(
        threadID: String,
        hostID: String,
        maximumAge: TimeInterval
    ) async throws -> CodexDesktopThreadSnapshot
}

extension DesktopThreadSnapshotCaching {
    func fetchThreadSnapshot(
        threadID: String,
        hostID: String,
        maximumAge: TimeInterval
    ) async throws -> CodexDesktopThreadSnapshot {
        try await fetchThreadSnapshot(threadID: threadID, hostID: hostID)
    }
}

struct CodexDesktopThreadSnapshot: Equatable, Sendable {
    enum Source: String, Equatable, Sendable { case desktopOwnerIPC }

    let identity: TaskIdentity
    let source: Source
    let observedAt: Date
    let usedTokens: Int?
    let contextWindow: Int?
    let model: String?
    let effort: String?
    let serviceTier: String?
    let executionState: SessionExecutionState?
    let isCompactingContext: Bool?

    init(
        identity: TaskIdentity = TaskIdentity(hostID: "local", threadID: "unknown"),
        source: Source = .desktopOwnerIPC,
        observedAt: Date = .now,
        usedTokens: Int?,
        contextWindow: Int?,
        model: String?,
        effort: String?,
        serviceTier: String? = nil,
        executionState: SessionExecutionState?,
        isCompactingContext: Bool? = nil
    ) {
        self.identity = identity
        self.source = source
        self.observedAt = observedAt
        self.usedTokens = usedTokens
        self.contextWindow = contextWindow
        self.model = model
        self.effort = effort
        self.serviceTier = serviceTier
        self.executionState = executionState
        self.isCompactingContext = isCompactingContext
    }
}

enum CodexDesktopIPCFrameCodec {
    static func encode(_ payload: Data) -> Data {
        var length = UInt32(payload.count).littleEndian
        var frame = withUnsafeBytes(of: &length) { Data($0) }
        frame.append(payload)
        return frame
    }
}

struct CodexDesktopIPCFrameDecoder {
    private static let maximumPayloadSize = 256 * 1024 * 1024
    private var buffer = Data()

    mutating func append<S: DataProtocol>(_ bytes: S) throws -> [Data] {
        buffer.append(contentsOf: bytes)
        var payloads: [Data] = []
        while buffer.count >= 4 {
            let length = buffer.prefix(4).enumerated().reduce(UInt32(0)) { value, entry in
                value | (UInt32(entry.element) << UInt32(entry.offset * 8))
            }
            guard length <= Self.maximumPayloadSize else {
                throw CocoaError(.fileReadCorruptFile)
            }
            let frameLength = 4 + Int(length)
            guard buffer.count >= frameLength else { break }
            payloads.append(buffer.subdata(in: 4..<frameLength))
            buffer.removeSubrange(0..<frameLength)
        }
        return payloads
    }
}

enum CodexDesktopIPCMessageFactory {
    static let replyMethod = "thread-follower-submit-user-message"
    static let historyMethod = "thread-follower-load-complete-history"
    static let streamStateMethod = "thread-stream-state-changed"
    static let followingChangedMethod = "thread-stream-following-changed"
    static let ownerDiscoveryMethod = "thread-owner-discovery"
    static let statusReadMethods: Set<String> = [
        historyMethod, followingChangedMethod, ownerDiscoveryMethod,
    ]

    static func initializeRequest(requestID: String, clientType: String) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "type": "request",
            "requestId": requestID,
            "sourceClientId": "initializing-client",
            "version": 0,
            "method": "initialize",
            "params": ["clientType": clientType],
        ])
    }

    static func replyRequest(
        requestID: String,
        clientID: String,
        threadID: String,
        text: String
    ) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "type": "request", "requestId": requestID,
            "sourceClientId": clientID, "version": 1,
            "method": replyMethod,
            "params": ["conversationId": threadID, "text": text],
            "timeoutMs": 5_000,
        ])
    }

    static func historyRequest(
        requestID: String,
        clientID: String,
        threadID: String,
        ownerClientID: String? = nil
    ) throws -> Data {
        var object: [String: Any] = [
            "type": "request",
            "requestId": requestID,
            "sourceClientId": clientID,
            "version": 1,
            "method": historyMethod,
            "params": ["conversationId": threadID],
            "timeoutMs": 12_000,
        ]
        if let ownerClientID { object["targetClientId"] = ownerClientID }
        return try JSONSerialization.data(withJSONObject: object)
    }

    static func followingChangedBroadcast(
        clientID: String,
        threadID: String,
        hostID: String,
        following: Bool
    ) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "type": "broadcast",
            "sourceClientId": clientID,
            "version": 1,
            "method": followingChangedMethod,
            "params": [
                "conversationId": threadID,
                "hostId": hostID,
                "following": following,
            ],
        ])
    }

    static func ownerDiscoveryRequest(
        requestID: String,
        clientID: String,
        threadID: String,
        hostID: String
    ) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "type": "request",
            "requestId": requestID,
            "sourceClientId": clientID,
            "version": 1,
            "method": ownerDiscoveryMethod,
            "params": [
                "hostId": hostID,
                "conversationId": threadID,
            ],
            "timeoutMs": 8_000,
        ])
    }

    static func discoveredOwnerClientID(
        in payload: Data,
        requestID: String
    ) throws -> String? {
        let object = try jsonObject(payload)
        guard object["type"] as? String == "response",
              object["requestId"] as? String == requestID,
              object["resultType"] as? String == "success",
              object["method"] as? String == ownerDiscoveryMethod
        else { return nil }
        return object["handledByClientId"] as? String
    }

    static func initializedClientID(_ payload: Data, requestID: String) throws -> String? {
        let object = try jsonObject(payload)
        guard object["type"] as? String == "response",
              object["requestId"] as? String == requestID,
              object["resultType"] as? String == "success",
              object["method"] as? String == "initialize",
              let result = object["result"] as? [String: Any]
        else { return nil }
        return result["clientId"] as? String
    }

    static func isConfirmedReplyResponse(_ payload: Data, requestID: String) throws -> Bool {
        let object = try jsonObject(payload)
        guard object["type"] as? String == "response",
              object["requestId"] as? String == requestID,
              object["resultType"] as? String == "success",
              object["method"] as? String == replyMethod,
              let result = object["result"] as? [String: Any] else { return false }
        return result["ok"] as? Bool == true
    }

    static func threadSnapshot(
        in payload: Data,
        identity: TaskIdentity,
        observedAt: Date = .now
    ) throws -> CodexDesktopThreadSnapshot? {
        let object = try jsonObject(payload)
        return threadSnapshot(in: object, identity: identity, observedAt: observedAt)
    }

    static func threadSnapshot(
        in object: [String: Any],
        identity: TaskIdentity,
        observedAt: Date = .now
    ) -> CodexDesktopThreadSnapshot? {
        guard object["type"] as? String == "broadcast",
              object["method"] as? String == streamStateMethod,
              let params = object["params"] as? [String: Any],
              (params["conversationId"] as? String)?.lowercased() == identity.threadID,
              let change = params["change"] as? [String: Any],
              change["type"] as? String == "snapshot",
              let state = change["conversationState"] as? [String: Any]
        else { return nil }
        if let payloadHostID = params["hostId"] as? String,
           payloadHostID != identity.hostID { return nil }

        var fields = SnapshotFields()
        collectSnapshotFields(in: state, into: &fields)
        let tokenUsage = fields.tokenUsage
        let usedTokens = integer(
            at: ["last", "totalTokens"],
            in: tokenUsage
        )
        let contextWindow = integer(at: ["modelContextWindow"], in: tokenUsage)

        return CodexDesktopThreadSnapshot(
            identity: identity,
            observedAt: observedAt,
            usedTokens: usedTokens,
            contextWindow: contextWindow,
            model: fields.reroutedModel ?? fields.model,
            effort: fields.effort ?? fields.fallbackEffort,
            serviceTier: fields.latestServiceTier ?? fields.fallbackServiceTier,
            executionState: executionState(from: fields.runtimeStatus),
            isCompactingContext: fields.isCompactingContext
        )
    }

    static func clientDiscoveryRejection(for payload: Data) throws -> Data? {
        let object = try jsonObject(payload)
        return try clientDiscoveryRejection(for: object)
    }

    static func clientDiscoveryRejection(for object: [String: Any]) throws -> Data? {
        guard object["type"] as? String == "client-discovery-request",
              let requestID = object["requestId"] as? String else { return nil }
        return try JSONSerialization.data(withJSONObject: [
            "type": "client-discovery-response",
            "requestId": requestID,
            "response": ["canHandle": false],
        ])
    }

    private static func executionState(from value: Any?) -> SessionExecutionState? {
        let type: String?
        let flags: [String]
        if let value = value as? String {
            type = value
            flags = []
        } else if let value = value as? [String: Any] {
            type = value["type"] as? String ?? value["status"] as? String
            flags = (value["activeFlags"] as? [String]) ?? []
        } else {
            return nil
        }
        switch type?.lowercased() {
        case "active":
            let attentionFlags = Set([
                "waitingonapproval", "waitingonuserinput", "waitingforapproval",
                "waitingforuserinput",
            ])
            return flags.contains { attentionFlags.contains($0.lowercased()) }
                ? .waiting : .working
        case "systemerror", "error": return .error
        case "idle", "notloaded": return .idle
        default: return nil
        }
    }

    private struct SnapshotFields {
        var tokenUsage: [String: Any]?
        var model: String?
        var reroutedModel: String?
        var effort: String?
        var fallbackEffort: String?
        var latestServiceTier: String?
        var fallbackServiceTier: String?
        var runtimeStatus: Any?
        var isCompactingContext = false
    }

    /// Walk the large Desktop snapshot once. The previous implementation recursively
    /// searched the same tree once per field and decoded the frame several times,
    /// multiplying CPU and temporary memory on every five-second refresh.
    private static func collectSnapshotFields(in value: Any, into fields: inout SnapshotFields) {
        if let dictionary = value as? [String: Any] {
            if fields.tokenUsage == nil {
                fields.tokenUsage = dictionary["latestTokenUsageInfo"] as? [String: Any]
            }
            if fields.model == nil { fields.model = dictionary["latestModel"] as? String }
            let normalizedType = (dictionary["type"] as? String)?
                .lowercased().replacingOccurrences(of: "/", with: "")
            if normalizedType == "modelrerouted" {
                fields.reroutedModel = dictionary["toModel"] as? String
                    ?? dictionary["to_model"] as? String
            }
            if fields.effort == nil {
                fields.effort = dictionary["latestReasoningEffort"] as? String
                if fields.effort == nil,
                   let settings = dictionary["latestThreadSettings"] as? [String: Any] {
                    fields.effort = settings["effort"] as? String
                        ?? settings["reasoningEffort"] as? String
                        ?? settings["reasoning_effort"] as? String
                }
            }
            if fields.fallbackEffort == nil {
                fields.fallbackEffort = dictionary["reasoningEffort"] as? String
                    ?? dictionary["reasoning_effort"] as? String
                    ?? dictionary["effort"] as? String
            }
            if fields.latestServiceTier == nil {
                fields.latestServiceTier = dictionary["latestServiceTier"] as? String
            }
            if fields.fallbackServiceTier == nil {
                fields.fallbackServiceTier = dictionary["serviceTier"] as? String
                    ?? dictionary["service_tier"] as? String
            }
            if fields.runtimeStatus == nil {
                fields.runtimeStatus = dictionary["threadRuntimeStatus"]
            }
            if (dictionary["type"] as? String)?.lowercased() == "contextcompaction" {
                if let completed = dictionary["completed"] as? Bool, !completed {
                    fields.isCompactingContext = true
                }
                if let status = dictionary["status"] as? String {
                    fields.isCompactingContext = fields.isCompactingContext
                        || status.lowercased() == "inprogress"
                }
            }
            for nested in dictionary.values {
                collectSnapshotFields(in: nested, into: &fields)
            }
        } else if let array = value as? [Any] {
            for nested in array {
                collectSnapshotFields(in: nested, into: &fields)
            }
        }
    }

    private static func integer(at path: [String], in dictionary: [String: Any]?) -> Int? {
        guard var value: Any = dictionary else { return nil }
        for key in path {
            guard let current = value as? [String: Any], let next = current[key] else {
                return nil
            }
            value = next
        }
        if let number = value as? NSNumber { return number.intValue }
        if let string = value as? String { return Int(string) }
        return nil
    }

    static func jsonObject(_ payload: Data) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: payload) as? [String: Any] else {
            throw CocoaError(.propertyListReadCorrupt)
        }
        return object
    }
}
