import Foundation

struct CurrentSessionProvider: SessionFetching, Sendable {
    private let root: URL
    private let now: @Sendable () -> Date
    private let selectedThread: SelectedThreadState?
    private let metadata: (any ThreadMetadataReading)?
    private let snapshots: any SessionSnapshotCaching

    init(
        root: URL = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".codex"),
        now: @escaping @Sendable () -> Date = { .now },
        selectedThread: SelectedThreadState? = nil,
        metadata: (any ThreadMetadataReading)? = nil,
        snapshots: any SessionSnapshotCaching = SessionSnapshotCache()
    ) {
        self.root = root
        self.now = now
        self.selectedThread = selectedThread
        self.metadata = metadata
        self.snapshots = snapshots
    }

    func fetchSession() async throws -> CurrentSessionSnapshot {
        let root = root
        let now = now
        let selectedThread = selectedThread
        let metadata = metadata
        let snapshots = snapshots
        try Task.checkCancellation()
        let candidates = await Task.detached(priority: .utility) {
            SessionLogUsageProvider.candidateFiles(root: root)
        }.value
        if let threadID = selectedThread?.threadID {
            let threadMetadata = await Task.detached(priority: .utility) {
                Self.metadata(for: threadID, using: metadata)
            }.value
            let exactCandidates = candidates.filter {
                Self.threadID(inRolloutFilename: $0.file) == threadID
                    || $0.file.standardizedFileURL == threadMetadata?.rolloutURL.standardizedFileURL
            }
            let candidatesToRead = exactCandidates.isEmpty ? candidates : exactCandidates
            var matching: [CurrentSessionSnapshot] = []
            for candidate in candidatesToRead {
                try Task.checkCancellation()
                if let snapshot = await snapshots.snapshot(in: candidate),
                   snapshot.threadID == threadID {
                    matching.append(snapshot)
                }
            }
            if let snapshot = matching.max(by: { $0.observedAt < $1.observedAt }) {
                return snapshot.with(metadata: threadMetadata)
            }
            return CurrentSessionSnapshot(
                sessionID: threadMetadata?.rolloutURL.path ?? "selected-thread",
                threadID: threadID,
                title: threadMetadata?.title,
                usedTokens: 0,
                contextWindow: 0,
                model: threadMetadata?.model,
                effort: threadMetadata?.effort,
                observedAt: now(),
                isPlaceholder: true
            )
        }

        var newest: CurrentSessionSnapshot?
        for candidate in candidates {
            try Task.checkCancellation()
            guard let snapshot = await snapshots.snapshot(in: candidate) else { continue }
            if newest == nil || snapshot.observedAt > newest!.observedAt { newest = snapshot }
        }
        guard var snapshot = newest,
              now().timeIntervalSince(snapshot.observedAt) <= 900
        else { throw UsageError.unavailable }
        if let threadID = snapshot.threadID {
            let threadMetadata = await Task.detached(priority: .utility) {
                Self.metadata(for: threadID, using: metadata)
            }.value
            snapshot = snapshot.with(metadata: threadMetadata)
        }
        return snapshot
    }

    private static func metadata(
        for threadID: String,
        using reader: (any ThreadMetadataReading)?
    ) -> CodexThreadMetadata? {
        do { return try reader?.metadata(for: threadID) }
        catch { return nil }
    }

    static func executionState(in data: Data) -> SessionExecutionState? {
        runtimeState(in: data)?.state
    }

    static func activeSince(in data: Data) -> Date? {
        runtimeState(in: data)?.activeSince
    }

    private static func runtimeState(
        in data: Data
    ) -> SessionRuntimeObservation? {
        var completedCalls = Set<String>()
        for line in data.split(separator: 0x0A).reversed() {
            guard let event = try? JSONDecoder.currentSession.decode(
                SessionRuntimeEvent.self,
                from: Data(line)
            ) else { continue }

            if event.type == "response_item" {
                if event.payload.type == "custom_tool_call_output",
                   let callID = event.payload.callID {
                    completedCalls.insert(callID)
                    continue
                }
                if event.payload.type == "custom_tool_call",
                   let name = event.payload.name?.lowercased(),
                   Self.attentionToolNames.contains(name),
                   event.payload.callID.map({ !completedCalls.contains($0) }) != false {
                    return .init(state: .waiting, observedAt: event.timestamp, activeSince: nil)
                }
            }

            guard event.type == "event_msg", let runtimeType = event.payload.type else {
                continue
            }
            switch runtimeType {
            case "task_complete":
                return .init(state: .idle, observedAt: event.timestamp, activeSince: nil)
            case "task_started":
                return .init(
                    state: .working,
                    observedAt: event.timestamp,
                    activeSince: event.timestamp
                )
            case "task_failed", "stream_error", "turn_aborted", "error":
                return .init(state: .error, observedAt: event.timestamp, activeSince: nil)
            case "request_user_input", "request_onboarding_input", "request_option_picker":
                return .init(state: .waiting, observedAt: event.timestamp, activeSince: nil)
            default: continue
            }
        }
        return nil
    }

    fileprivate static let attentionToolNames: Set<String> = [
        "request_user_input",
        "request_onboarding_input",
        "request_option_picker",
        "setup_codex_step",
    ]

    fileprivate static func normalizedThreadID(_ value: String?) -> String? {
        guard let value, let identifier = UUID(uuidString: value) else { return nil }
        return identifier.uuidString.lowercased()
    }

    static func threadID(inRolloutFilename file: URL) -> String? {
        let name = file.deletingPathExtension().lastPathComponent
        return normalizedThreadID(String(name.suffix(36)))
    }
}

struct SessionSnapshotAccumulator {
    private var identity: String?
    private var metadata: [SessionMetadataEvent] = []
    private var settings: [SessionSettingsEvent] = []
    private var latestToken: SessionTokenEvent?
    private var runtime: SessionRuntimeObservation?
    private var taskStartedAt: Date?
    private var pendingAttentionCalls = Set<String>()

    mutating func consume(_ data: Data) {
        for line in data.split(separator: 0x0A) {
            consumeLine(Data(line))
        }
    }

    func snapshot(in candidate: SafeSessionCandidate) -> CurrentSessionSnapshot? {
        guard let token = latestToken,
              token.payload.info.lastTokenUsage.totalTokens >= 0,
              token.payload.info.modelContextWindow > 0 else { return nil }
        let context = metadata
            .filter { $0.timestamp <= token.timestamp }
            .max(by: { $0.timestamp < $1.timestamp })
        let appliedSettings = settings
            .filter { $0.timestamp <= token.timestamp }
            .max(by: { $0.timestamp < $1.timestamp })
        return CurrentSessionSnapshot(
            sessionID: candidate.file.path,
            threadID: CurrentSessionProvider.normalizedThreadID(identity)
                ?? CurrentSessionProvider.threadID(inRolloutFilename: candidate.file),
            usedTokens: token.payload.info.lastTokenUsage.totalTokens,
            contextWindow: token.payload.info.modelContextWindow,
            model: context?.payload.model ?? appliedSettings?.payload.threadSettings.model,
            effort: context?.payload.effort
                ?? context?.payload.collaborationMode?.settings?.reasoningEffort
                ?? appliedSettings?.payload.threadSettings.reasoningEffort,
            serviceTier: context?.payload.serviceTier
                ?? appliedSettings?.payload.threadSettings.serviceTier,
            observedAt: token.timestamp,
            lastActivityAt: [token.timestamp, runtime?.observedAt].compactMap { $0 }.max(),
            activeSince: runtime?.activeSince,
            executionStateObservedAt: runtime?.observedAt,
            executionState: runtime?.state ?? .unknown
        )
    }

    private mutating func consumeLine(_ bytes: Data) {
        if identity == nil,
           let event = try? JSONDecoder.currentSession.decode(SessionIdentityEvent.self, from: bytes),
           event.type == "session_meta" {
            identity = event.payload.sessionID
        }
        if let event = try? JSONDecoder.currentSession.decode(SessionMetadataEvent.self, from: bytes),
           event.type == "turn_context" {
            metadata.append(event)
            if metadata.count > 64 { metadata.removeFirst(metadata.count - 64) }
        }
        if let event = try? JSONDecoder.currentSession.decode(SessionSettingsEvent.self, from: bytes),
           event.type == "event_msg", event.payload.type == "thread_settings_applied" {
            settings.append(event)
            if settings.count > 64 { settings.removeFirst(settings.count - 64) }
        }
        if let event = try? JSONDecoder.currentSession.decode(SessionTokenEvent.self, from: bytes),
           event.type == "event_msg", event.payload.type == "token_count",
           latestToken == nil || event.timestamp >= latestToken!.timestamp {
            latestToken = event
            // Progress confirms an already-running turn is still publishing.
            // Do not let a long task age out solely because task_started is old,
            // and never revive a completed/waiting turn from a later token count.
            if runtime?.state == .working,
               event.timestamp >= (runtime?.observedAt ?? .distantPast) {
                runtime = .init(state: .working, observedAt: event.timestamp,
                                activeSince: taskStartedAt)
            }
        }
        guard let event = try? JSONDecoder.currentSession.decode(
            SessionRuntimeEvent.self,
            from: bytes
        ) else { return }
        consumeRuntime(event)
    }

    private mutating func consumeRuntime(_ event: SessionRuntimeEvent) {
        if event.type == "response_item" {
            if event.payload.type == "custom_tool_call_output",
               let callID = event.payload.callID {
                pendingAttentionCalls.remove(callID)
                if pendingAttentionCalls.isEmpty, runtime?.state == .waiting {
                    runtime = .init(
                        state: .working,
                        observedAt: event.timestamp,
                        activeSince: taskStartedAt
                    )
                }
                return
            }
            if event.payload.type == "custom_tool_call",
               let name = event.payload.name?.lowercased(),
               CurrentSessionProvider.attentionToolNames.contains(name),
               let callID = event.payload.callID {
                pendingAttentionCalls.insert(callID)
                runtime = .init(state: .waiting, observedAt: event.timestamp, activeSince: nil)
                return
            }
        }

        guard event.type == "event_msg", let runtimeType = event.payload.type else { return }
        switch runtimeType {
        case "task_complete":
            pendingAttentionCalls.removeAll()
            taskStartedAt = nil
            runtime = .init(state: .idle, observedAt: event.timestamp, activeSince: nil)
        case "task_started":
            pendingAttentionCalls.removeAll()
            taskStartedAt = event.timestamp
            runtime = .init(
                state: .working,
                observedAt: event.timestamp,
                activeSince: event.timestamp
            )
        case "task_failed", "stream_error", "turn_aborted", "error":
            pendingAttentionCalls.removeAll()
            taskStartedAt = nil
            runtime = .init(state: .error, observedAt: event.timestamp, activeSince: nil)
        case "request_user_input", "request_onboarding_input", "request_option_picker":
            runtime = .init(state: .waiting, observedAt: event.timestamp, activeSince: nil)
        default:
            break
        }
    }
}

private extension CurrentSessionSnapshot {
    func with(metadata: CodexThreadMetadata?) -> Self {
        .init(
            sessionID: sessionID,
            threadID: threadID,
            title: metadata?.title,
            usedTokens: usedTokens,
            contextWindow: contextWindow,
            model: model ?? metadata?.model,
            effort: effort ?? metadata?.effort,
            serviceTier: serviceTier,
            observedAt: observedAt,
            lastActivityAt: lastActivityAt,
            contextObservedAt: contextObservedAt,
            modelObservedAt: modelObservedAt,
            activeSince: activeSince,
            isCompactingContext: isCompactingContext,
            projectName: projectName,
            projectID: projectID,
            hostName: hostName,
            providerID: providerID,
            hostID: hostID,
            hostKind: hostKind,
            openURL: openURL,
            isPlaceholder: isPlaceholder,
            executionStateObservedAt: executionStateObservedAt,
            executionState: executionState
        )
    }
}

private struct SessionRuntimeObservation: Sendable {
    let state: SessionExecutionState
    let observedAt: Date?
    let activeSince: Date?
}

private struct SessionSettingsEvent: Decodable {
    let timestamp: Date
    let type: String
    let payload: Payload

    struct Payload: Decodable {
        let type: String
        let threadSettings: ThreadSettings
        enum CodingKeys: String, CodingKey {
            case type
            case threadSettings = "thread_settings"
        }
    }

    struct ThreadSettings: Decodable {
        let model: String?
        let reasoningEffort: String?
        let serviceTier: String?
        enum CodingKeys: String, CodingKey {
            case model
            case reasoningEffort = "reasoning_effort"
            case serviceTier = "service_tier"
        }
    }
}

private struct SessionIdentityEvent: Decodable {
    let type: String
    let payload: Payload

    struct Payload: Decodable {
        let sessionID: String
        enum CodingKeys: String, CodingKey { case sessionID = "session_id" }
    }
}

private struct SessionTokenEvent: Decodable {
    let timestamp: Date
    let type: String
    let payload: Payload

    struct Payload: Decodable {
        let type: String
        let info: Info
    }

    struct Info: Decodable {
        let lastTokenUsage: TokenUsage
        let modelContextWindow: Int

        enum CodingKeys: String, CodingKey {
            case lastTokenUsage = "last_token_usage"
            case modelContextWindow = "model_context_window"
        }
    }

    struct TokenUsage: Decodable {
        let totalTokens: Int
        enum CodingKeys: String, CodingKey { case totalTokens = "total_tokens" }
    }
}

private struct SessionMetadataEvent: Decodable {
    let timestamp: Date
    let type: String
    let payload: Payload

    struct Payload: Decodable {
        let model: String?
        let effort: String?
        let serviceTier: String?
        let collaborationMode: CollaborationMode?
        enum CodingKeys: String, CodingKey {
            case model, effort
            case serviceTier = "service_tier"
            case collaborationMode = "collaboration_mode"
        }
    }

    struct CollaborationMode: Decodable {
        let settings: Settings?
    }

    struct Settings: Decodable {
        let reasoningEffort: String?
        enum CodingKeys: String, CodingKey { case reasoningEffort = "reasoning_effort" }
    }
}

private struct SessionRuntimeEvent: Decodable {
    let timestamp: Date?
    let type: String
    let payload: Payload

    struct Payload: Decodable {
        let type: String?
        let name: String?
        let callID: String?

        enum CodingKeys: String, CodingKey {
            case type, name
            case callID = "call_id"
        }
    }
}

private extension JSONDecoder {
    static var currentSession: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
