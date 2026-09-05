import Darwin
import Foundation

struct CodexAppThreadStatus: Equatable, Sendable {
    let threadID: String
    let hostID: String?
    let executionState: SessionExecutionState
    let updatedAt: Date
    let activeSince: Date?

    var identity: TaskIdentity? {
        hostID.map { TaskIdentity(hostID: $0, threadID: threadID) }
    }

    init(
        identity: TaskIdentity,
        executionState: SessionExecutionState,
        updatedAt: Date,
        activeSince: Date?
    ) {
        self.threadID = identity.threadID
        self.hostID = identity.hostID
        self.executionState = executionState
        self.updatedAt = updatedAt
        self.activeSince = activeSince
    }

    init(
        threadID: String,
        hostID: String = "local",
        executionState: SessionExecutionState,
        updatedAt: Date,
        activeSince: Date?
    ) {
        self.init(
            identity: TaskIdentity(hostID: hostID, threadID: threadID),
            executionState: executionState,
            updatedAt: updatedAt,
            activeSince: activeSince
        )
    }

    init(
        unscopedThreadID threadID: String,
        executionState: SessionExecutionState,
        updatedAt: Date,
        activeSince: Date?
    ) {
        self.threadID = threadID.lowercased()
        self.hostID = nil
        self.executionState = executionState
        self.updatedAt = updatedAt
        self.activeSince = activeSince
    }
}

struct CodexRemoteHostStatus: Equatable, Sendable {
    enum Stage: String, Equatable, Sendable {
        case connecting
        case recovering
        case offline
        case errored
        case ready

        var isSynchronizing: Bool { self != .ready }
    }

    let hostID: String
    let stage: Stage
    let updatedAt: Date

    init(hostID: String, stage: Stage, updatedAt: Date) {
        self.hostID = hostID
        self.stage = stage
        self.updatedAt = updatedAt
    }

    init(hostID: String, isSynchronizing: Bool, updatedAt: Date) {
        self.init(
            hostID: hostID,
            stage: isSynchronizing ? .recovering : .ready,
            updatedAt: updatedAt
        )
    }

    var isSynchronizing: Bool { stage.isSynchronizing }
}

protocol CodexAppThreadStatusFetching: Sendable {
    func fetchThreadStatuses() async throws -> [CodexAppThreadStatus]
    func fetchRemoteHostStatuses() async throws -> [CodexRemoteHostStatus]
}

extension CodexAppThreadStatusFetching {
    func fetchRemoteHostStatuses() async throws -> [CodexRemoteHostStatus] { [] }
}

/// Reads only Codex Desktop's turn-boundary metadata from its local diagnostic logs.
/// Titles and completion recency still come from Codex's catalog database.
actor CodexDesktopLogStatusProvider: CodexAppThreadStatusFetching {
    private struct FileCursor: Sendable {
        var inode: UInt64
        var offset: UInt64
        var remainder: Data
        var latestEvents: [CodexDesktopLogThreadEvent.Key: CodexDesktopLogThreadEvent]
        var latestHostEvents: [String: CodexDesktopLogHostEvent]
    }

    private let logRoot: URL
    private let maximumFiles: Int
    private let maximumBytesPerFile: UInt64
    private var cursors: [String: FileCursor] = [:]

    init(
        logRoot: URL = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Logs/com.openai.codex"),
        maximumFiles: Int = 6,
        maximumBytesPerFile: UInt64 = 16 * 1_024 * 1_024
    ) {
        self.logRoot = logRoot
        self.maximumFiles = maximumFiles
        self.maximumBytesPerFile = maximumBytesPerFile
    }

    func fetchThreadStatuses() async throws -> [CodexAppThreadStatus] {
        try refreshCursors()
        let latest = Dictionary(
            cursors.values.flatMap(\.latestEvents.values).map { ($0.key, $0) },
            uniquingKeysWith: { first, second in
                first.timestamp >= second.timestamp ? first : second
            }
        )
        return latest.values.map { event in
            if let identity = event.identity {
                CodexAppThreadStatus(
                    identity: identity,
                    executionState: event.executionState,
                    updatedAt: event.timestamp,
                    activeSince: event.executionState == .working ? event.timestamp : nil
                )
            } else {
                CodexAppThreadStatus(
                    unscopedThreadID: event.threadID,
                    executionState: event.executionState,
                    updatedAt: event.timestamp,
                    activeSince: event.executionState == .working ? event.timestamp : nil
                )
            }
        }
    }

    func fetchRemoteHostStatuses() async throws -> [CodexRemoteHostStatus] {
        try refreshCursors()
        let latest = Dictionary(
            cursors.values.flatMap(\.latestHostEvents.values).map { ($0.hostID, $0) },
            uniquingKeysWith: { first, second in
                first.timestamp >= second.timestamp ? first : second
            }
        )
        return latest.values.map { event in
            CodexRemoteHostStatus(
                hostID: event.hostID,
                stage: event.stage,
                updatedAt: event.timestamp
            )
        }
    }

    private func refreshCursors() throws {
        try Task.checkCancellation()
        let files = try Self.recentLogFiles(in: logRoot, limit: maximumFiles)
        let currentPaths = Set(files.map { $0.standardizedFileURL.path })
        cursors = cursors.filter { currentPaths.contains($0.key) }

        for file in files {
            try Task.checkCancellation()
            try updateCursor(for: file)
        }
    }

    static func decodeEvents(from data: Data) -> [CodexDesktopLogThreadEvent] {
        let turnStart = Data("method=turn/start".utf8)
        let successful = Data("errorCode=null".utf8)
        let completion = Data("[desktop-notifications] show turn-complete".utf8)
        let resumedCompleted = Data("latestTurnStatus=completed".utf8)

        return data.split(separator: 0x0A).compactMap { bytes in
            let line = Data(bytes)
            let state: SessionExecutionState
            if line.range(of: completion) != nil || line.range(of: resumedCompleted) != nil {
                state = .idle
            } else if line.range(of: turnStart) != nil {
                state = line.range(of: successful) != nil ? .working : .error
            } else {
                return nil
            }

            guard let text = String(data: line, encoding: .utf8),
                  let timestamp = timestamp(in: text),
                  let threadID = field(named: "conversationId", in: text),
                  UUID(uuidString: threadID) != nil
            else { return nil }
            return CodexDesktopLogThreadEvent(
                threadID: threadID,
                hostID: field(named: "hostId", in: text),
                executionState: state,
                timestamp: timestamp
            )
        }
    }

    static func decodeHostEvents(from data: Data) -> [CodexDesktopLogHostEvent] {
        let connectionState = Data("app_server_connection.state_changed".utf8)
        let recoveryDone = Data("websocket_reconnect_recovery_done".utf8)

        return data.split(separator: 0x0A).compactMap { bytes in
            let line = Data(bytes)
            let stage: CodexRemoteHostStatus.Stage
            if line.range(of: recoveryDone) != nil {
                guard let text = String(data: line, encoding: .utf8) else { return nil }
                let recoveryFailed = field(
                    named: "refreshRecentConversationsFailed",
                    in: text
                )?.lowercased() != "false"
                stage = recoveryFailed ? .recovering : .ready
            } else if line.range(of: connectionState) != nil {
                guard let text = String(data: line, encoding: .utf8),
                      let next = field(named: "next", in: text)?.lowercased(),
                      ["connecting", "connected", "error", "errored", "offline", "recovering"]
                        .contains(next)
                else { return nil }
                // A transport-level `connected` event precedes the Desktop recovery
                // pass. Keep showing SYNC until `websocket_reconnect_recovery_done`.
                stage = switch next {
                case "connecting": .connecting
                case "offline": .offline
                case "error", "errored": .errored
                default: .recovering
                }
            } else {
                return nil
            }

            guard let text = String(data: line, encoding: .utf8),
                  let timestamp = timestamp(in: text),
                  let hostID = field(named: "hostId", in: text),
                  hostID != "local"
            else { return nil }
            return CodexDesktopLogHostEvent(
                hostID: hostID,
                stage: stage,
                timestamp: timestamp
            )
        }
    }

    static func recentLogFiles(in root: URL, limit: Int) throws -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { throw CocoaError(.fileReadNoSuchFile) }

        var datedFiles: [(url: URL, date: Date)] = []
        for case let file as URL in enumerator where file.pathExtension == "log" {
            let values = try? file.resourceValues(forKeys: [
                .contentModificationDateKey,
                .isRegularFileKey
            ])
            guard values?.isRegularFile == true else { continue }
            datedFiles.append((file, values?.contentModificationDate ?? .distantPast))
        }
        let sorted = datedFiles.sorted { $0.date > $1.date }
        guard let newest = sorted.first,
              let generation = desktopLogGeneration(of: newest.url.lastPathComponent)
        else { return Array(sorted.prefix(limit).map(\.url)) }
        return Array(
            sorted.lazy
                .filter { desktopLogGeneration(of: $0.url.lastPathComponent) == generation }
                .prefix(limit)
                .map(\.url)
        )
    }

    private func updateCursor(for file: URL) throws {
        let path = file.standardizedFileURL.path
        var fileInfo = stat()
        guard Darwin.lstat(path, &fileInfo) == 0 else { throw CocoaError(.fileReadNoSuchFile) }
        let inode = UInt64(fileInfo.st_ino)
        let length = UInt64(max(0, fileInfo.st_size))
        let previous = cursors[path]
        let reset = previous == nil || previous?.inode != inode || length < (previous?.offset ?? 0)
        var cursor = reset
            ? FileCursor(
                inode: inode,
                offset: 0,
                remainder: Data(),
                latestEvents: [:],
                latestHostEvents: [:]
            )
            : previous!
        guard length != cursor.offset else {
            cursors[path] = cursor
            return
        }

        var start = reset ? 0 : cursor.offset
        if length - start > maximumBytesPerFile {
            start = length - maximumBytesPerFile
            cursor.remainder.removeAll(keepingCapacity: false)
            cursor.latestEvents.removeAll(keepingCapacity: true)
            cursor.latestHostEvents.removeAll(keepingCapacity: true)
        }
        let appended = try Self.read(of: file, from: start, through: length)
        var decodable = Data()
        if !reset && start == cursor.offset { decodable.append(cursor.remainder) }
        decodable.append(appended)
        if start > 0 && (reset || start != cursor.offset),
           let firstNewline = decodable.firstIndex(of: 0x0A) {
            decodable.removeSubrange(...firstNewline)
        }
        if let finalNewline = decodable.lastIndex(of: 0x0A) {
            cursor.remainder = Data(decodable[decodable.index(after: finalNewline)...])
        } else {
            cursor.remainder = Data(decodable.suffix(64 * 1_024))
        }
        let events = autoreleasepool { Self.decodeEvents(from: decodable) }
        for event in events {
            if let existing = cursor.latestEvents[event.key],
               existing.timestamp > event.timestamp { continue }
            cursor.latestEvents[event.key] = event
        }
        let hostEvents = autoreleasepool { Self.decodeHostEvents(from: decodable) }
        for event in hostEvents {
            if let existing = cursor.latestHostEvents[event.hostID],
               existing.timestamp > event.timestamp { continue }
            cursor.latestHostEvents[event.hostID] = event
        }
        cursor.inode = inode
        cursor.offset = length
        cursors[path] = cursor
    }

    private static func read(of file: URL, from start: UInt64, through end: UInt64) throws -> Data {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        try handle.seek(toOffset: start)
        return try handle.read(upToCount: Int(end - start)) ?? Data()
    }

    private static func timestamp(in line: String) -> Date? {
        guard line.count >= 24 else { return nil }
        let prefix = String(line.prefix(24))
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: prefix)
    }

    private static func field(named name: String, in line: String) -> String? {
        let prefix = "\(name)="
        guard let range = line.range(of: prefix) else { return nil }
        let tail = line[range.upperBound...]
        let value = tail.prefix { !$0.isWhitespace }
        return value.isEmpty ? nil : String(value)
    }

    private static func desktopLogGeneration(of filename: String) -> String? {
        guard filename.hasPrefix("codex-desktop-"),
              let turnMarker = filename.range(of: "-t", options: .backwards)
        else { return nil }
        return String(filename[..<turnMarker.lowerBound])
    }
}

struct CodexDesktopLogThreadEvent: Equatable, Sendable {
    struct Key: Hashable, Sendable {
        let threadID: String
        let hostID: String?
    }

    let threadID: String
    let hostID: String?
    let executionState: SessionExecutionState
    let timestamp: Date

    init(
        threadID: String,
        hostID: String?,
        executionState: SessionExecutionState,
        timestamp: Date
    ) {
        self.threadID = threadID.lowercased()
        self.hostID = hostID
        self.executionState = executionState
        self.timestamp = timestamp
    }

    var identity: TaskIdentity? {
        hostID.map { TaskIdentity(hostID: $0, threadID: threadID) }
    }

    var key: Key { Key(threadID: threadID, hostID: hostID) }
}

struct CodexDesktopLogHostEvent: Equatable, Sendable {
    let hostID: String
    let stage: CodexRemoteHostStatus.Stage
    let timestamp: Date

    var isSynchronizing: Bool { stage.isSynchronizing }
}
