import Foundation
import Darwin

struct SafeSessionCandidate: Sendable {
    let file: URL
    let allowedRoot: URL
}

struct SafeSessionFileChunk: Sendable {
    let inode: UInt64
    let length: UInt64
    let startOffset: UInt64
    let data: Data
    let didReset: Bool
}

struct SessionLogUsageProvider: UsageFetching, Sendable {
    private static let maximumTailBytes: UInt64 = 256 * 1_024
    private let root: URL
    private let candidateValidated: @Sendable (URL) -> Void

    init(
        root: URL = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".codex"),
        candidateValidated: @escaping @Sendable (URL) -> Void = { _ in }
    ) {
        self.root = root
        self.candidateValidated = candidateValidated
    }

    func fetch() async throws -> UsageSnapshot {
        let root = root
        let candidateValidated = candidateValidated
        return try await Task.detached {
            try Self.fetchSynchronously(root: root, candidateValidated: candidateValidated)
        }.value
    }

    private static func fetchSynchronously(
        root: URL,
        candidateValidated: @Sendable (URL) -> Void
    ) throws -> UsageSnapshot {
        guard let snapshot = candidateFiles(root: root)
            .compactMap({ newestSnapshot(in: $0, candidateValidated: candidateValidated) })
            .max(by: { $0.observedAt < $1.observedAt })
        else { throw UsageError.unavailable }
        return snapshot
    }

    static func candidateFiles(root: URL) -> [SafeSessionCandidate] {
        let fileManager = FileManager.default
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey]
        var files: [SafeSessionCandidate] = []

        let sessions = root.appending(path: "sessions", directoryHint: .isDirectory)
        if let enumerator = fileManager.enumerator(
            at: sessions,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        ) {
            for case let url as URL in enumerator where url.pathExtension == "jsonl" {
                if isSafeCandidate(url, inside: sessions) {
                    files.append(SafeSessionCandidate(file: url, allowedRoot: sessions))
                }
            }
        }

        let archived = root.appending(path: "archived_sessions", directoryHint: .isDirectory)
        if let children = try? fileManager.contentsOfDirectory(
            at: archived,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        ) {
            files.append(contentsOf: children.compactMap { url in
                guard url.pathExtension == "jsonl", isSafeCandidate(url, inside: archived) else {
                    return nil
                }
                return SafeSessionCandidate(file: url, allowedRoot: archived)
            })
        }

        return files.sorted {
            modificationDate(of: $0.file) > modificationDate(of: $1.file)
        }
    }

    private static func isSafeCandidate(_ candidate: URL, inside allowedRoot: URL) -> Bool {
        let standardizedRoot = allowedRoot.standardizedFileURL
        let standardizedCandidate = candidate.standardizedFileURL
        guard !containsSymbolicLink(from: standardizedRoot, through: standardizedCandidate) else {
            return false
        }

        let resolvedRoot = standardizedRoot.resolvingSymlinksInPath().standardizedFileURL
        let resolvedCandidate = standardizedCandidate.resolvingSymlinksInPath().standardizedFileURL
        guard resolvedRoot == standardizedRoot,
              isContained(resolvedCandidate, in: resolvedRoot),
              (try? resolvedCandidate.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
        else { return false }
        return true
    }

    private static func containsSymbolicLink(from root: URL, through candidate: URL) -> Bool {
        guard isContained(candidate, in: root) else { return true }
        var current = root
        if (try? current.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
            return true
        }
        let relativeComponents = candidate.pathComponents.dropFirst(root.pathComponents.count)
        for component in relativeComponents {
            current.append(path: component)
            if (try? current.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
                return true
            }
        }
        return false
    }

    private static func isContained(_ candidate: URL, in root: URL) -> Bool {
        candidate.path == root.path || candidate.path.hasPrefix(root.path + "/")
    }

    private static func modificationDate(of url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
            ?? .distantPast
    }

    private static func newestSnapshot(
        in candidate: SafeSessionCandidate,
        candidateValidated: @Sendable (URL) -> Void
    ) -> UsageSnapshot? {
        candidateValidated(candidate.file)
        guard let data = try? boundedTail(of: candidate.file, relativeTo: candidate.allowedRoot) else {
            return nil
        }
        return data.split(separator: 0x0A)
            .compactMap { try? JSONDecoder.codexSession.decode(TokenCountEvent.self, from: Data($0)) }
            .filter { $0.type == "event_msg" && $0.payload.type == "token_count" }
            .compactMap { event in
                guard event.payload.rateLimits.isAccountWide else { return nil }
                return try? UsageSnapshot.from(
                    primary: event.payload.rateLimits.primary?.rawValue,
                    secondary: event.payload.rateLimits.secondary?.rawValue,
                    observedAt: event.timestamp
                )
            }
            .max { $0.observedAt < $1.observedAt }
    }

    static func boundedTail(
        of file: URL,
        relativeTo allowedRoot: URL,
        maximumBytes: UInt64 = maximumTailBytes
    ) throws -> Data {
        let components = try relativeComponents(of: file, inside: allowedRoot)
        let rootDescriptor = Darwin.open(
            trustedRootPath(allowedRoot),
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard rootDescriptor >= 0 else { throw currentPOSIXError() }
        var descriptors = [rootDescriptor]
        defer { descriptors.reversed().forEach { Darwin.close($0) } }

        var parentDescriptor = rootDescriptor
        for component in components.dropLast() {
            let descriptor = Darwin.openat(
                parentDescriptor,
                component,
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            )
            guard descriptor >= 0 else { throw currentPOSIXError() }
            descriptors.append(descriptor)
            parentDescriptor = descriptor
        }

        guard let leaf = components.last else { throw POSIXError(.EINVAL) }
        let descriptor = Darwin.openat(
            parentDescriptor,
            leaf,
            O_RDONLY | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else { throw currentPOSIXError() }
        descriptors.append(descriptor)
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)

        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0 else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
        guard (metadata.st_mode & S_IFMT) == S_IFREG else {
            throw POSIXError(.EFTYPE)
        }
        let length = try handle.seekToEnd()
        let start = length > maximumBytes ? length - maximumBytes : 0
        try handle.seek(toOffset: start)
        var data = try handle.read(upToCount: Int(maximumBytes)) ?? Data()
        if start > 0, let newline = data.firstIndex(of: 0x0A) {
            data.removeSubrange(...newline)
        }
        return data
    }

    static func incrementalChunk(
        of file: URL,
        relativeTo allowedRoot: URL,
        previousInode: UInt64?,
        previousOffset: UInt64?,
        maximumBytes: UInt64
    ) throws -> SafeSessionFileChunk {
        let components = try relativeComponents(of: file, inside: allowedRoot)
        let rootDescriptor = Darwin.open(
            trustedRootPath(allowedRoot),
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard rootDescriptor >= 0 else { throw currentPOSIXError() }
        var descriptors = [rootDescriptor]
        defer { descriptors.reversed().forEach { Darwin.close($0) } }

        var parentDescriptor = rootDescriptor
        for component in components.dropLast() {
            let descriptor = Darwin.openat(
                parentDescriptor,
                component,
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            )
            guard descriptor >= 0 else { throw currentPOSIXError() }
            descriptors.append(descriptor)
            parentDescriptor = descriptor
        }
        guard let leaf = components.last else { throw POSIXError(.EINVAL) }
        let descriptor = Darwin.openat(
            parentDescriptor,
            leaf,
            O_RDONLY | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else { throw currentPOSIXError() }
        descriptors.append(descriptor)

        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0 else { throw currentPOSIXError() }
        guard (metadata.st_mode & S_IFMT) == S_IFREG else { throw POSIXError(.EFTYPE) }
        let inode = UInt64(metadata.st_ino)
        let length = UInt64(max(0, metadata.st_size))
        let reset = previousInode != inode
            || previousOffset == nil
            || length < (previousOffset ?? 0)
        var start = reset ? 0 : previousOffset!
        var didReset = reset
        if length - start > maximumBytes {
            start = length - maximumBytes
            didReset = true
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        try handle.seek(toOffset: start)
        var data = try handle.read(upToCount: Int(length - start)) ?? Data()
        if didReset, start > 0, let newline = data.firstIndex(of: 0x0A) {
            data.removeSubrange(...newline)
        }
        return SafeSessionFileChunk(
            inode: inode,
            length: length,
            startOffset: start,
            data: data,
            didReset: didReset
        )
    }

    private static func relativeComponents(of file: URL, inside allowedRoot: URL) throws -> [String] {
        guard file.pathComponents.allSatisfy({ $0 != "." && $0 != ".." }) else {
            throw POSIXError(.EINVAL)
        }
        let rootPath = trustedRootPath(allowedRoot.standardizedFileURL)
        let filePath = file.standardizedFileURL.path
        guard filePath.hasPrefix(rootPath + "/") else { throw POSIXError(.EINVAL) }
        let relativePath = String(filePath.dropFirst(rootPath.count + 1))
        let components = relativePath.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !components.isEmpty,
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.hasPrefix("/") })
        else { throw POSIXError(.EINVAL) }
        return components
    }

    private static func trustedRootPath(_ root: URL) -> String {
        root.path.hasSuffix("/") ? String(root.path.dropLast()) : root.path
    }

    private static func currentPOSIXError() -> POSIXError {
        POSIXError(.init(rawValue: errno) ?? .EIO)
    }
}

private struct TokenCountEvent: Decodable {
    let timestamp: Date
    let type: String
    let payload: Payload

    struct Payload: Decodable {
        let type: String
        let rateLimits: RateLimits

        enum CodingKeys: String, CodingKey {
            case type
            case rateLimits = "rate_limits"
        }
    }

    struct RateLimits: Decodable {
        let limitID: String?
        let primary: Window?
        let secondary: Window?

        enum CodingKeys: String, CodingKey {
            case limitID = "limit_id"
            case primary
            case secondary
        }

        var isAccountWide: Bool {
            limitID == nil || limitID == "codex"
        }
    }

    struct Window: Decodable {
        let usedPercent: Double
        let windowMinutes: Int
        let resetsAt: TimeInterval

        enum CodingKeys: String, CodingKey {
            case usedPercent = "used_percent"
            case windowMinutes = "window_minutes"
            case resetsAt = "resets_at"
        }

        var rawValue: RawRateWindow {
            .init(usedPercent: usedPercent, windowMinutes: windowMinutes, resetsAt: resetsAt)
        }
    }
}

private extension JSONDecoder {
    static var codexSession: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .compatibleISO8601
        return decoder
    }
}
