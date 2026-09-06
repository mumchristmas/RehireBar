import Darwin
import Dispatch
import Foundation

/// Status acquisition is confined to Desktop's local owner/follower IPC. It never
/// opens a relay connection and never reads or persists enrollment tokens, pairing
/// codes, controller credentials, or device keys.
final class CodexDesktopIPCClient: DesktopThreadSnapshotFetching, Sendable {
    private static let clientType = "rehirebar"
    private static let maximumFramesPerResponse = 64
    private static let statusReadQueue = DispatchQueue(
        label: "com.bigbom.RehireBar.status-ipc", qos: .utility, attributes: .concurrent
    )

    func submitUserMessage(threadID: String, text: String) async throws -> Bool {
        try await Task.detached(priority: .userInitiated) {
            try autoreleasepool {
                try Self.submitUserMessageBlocking(threadID: threadID, text: text)
            }
        }.value
    }

    func fetchThreadSnapshot(
        threadID: String,
        hostID: String
    ) async throws -> CodexDesktopThreadSnapshot {
        return try await withCheckedThrowingContinuation { continuation in
            Self.statusReadQueue.async {
                // Blocking socket I/O must not occupy Swift's cooperative workers.
                // Each read owns its connection; only typed snapshots are cached.
                let follower = FollowerSession(threadID: threadID, hostID: hostID)
                defer { follower.close() }
                do {
                    let snapshot = try autoreleasepool { try follower.fetchSnapshot() }
                    continuation.resume(returning: snapshot)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private final class FollowerSession: @unchecked Sendable {
        private struct DiscoveryResult {
            let ownerClientID: String?
            let snapshot: CodexDesktopThreadSnapshot?
        }

        private let lock = NSLock()
        private let threadID: String
        private let hostID: String
        private var descriptor: Int32 = -1
        private var clientID: String?
        private var ownerClientID: String?

        init(threadID: String, hostID: String) {
            self.threadID = threadID
            self.hostID = hostID
        }

        deinit { close() }

        func fetchSnapshot() throws -> CodexDesktopThreadSnapshot {
            lock.lock()
            defer { lock.unlock() }
            do {
                return try fetchSnapshotOnce()
            } catch {
                resetConnection()
                do { return try fetchSnapshotOnce() }
                catch {
                    resetConnection()
                    throw error
                }
            }
        }

        func close() {
            lock.lock()
            defer { lock.unlock() }
            resetConnection()
        }

        private func fetchSnapshotOnce() throws -> CodexDesktopThreadSnapshot {
            if let subscribedSnapshot = try establishConnectionIfNeeded() {
                // A snapshot can race ahead of an owner-discovery response. It is
                // already authoritative for this exact host/thread, so use it even
                // when the router reports that no owner is discoverable.
                if ownerClientID == nil { resetConnection() }
                return subscribedSnapshot
            }
            guard descriptor >= 0, let clientID, let ownerClientID else {
                throw CocoaError(.fileReadCorruptFile)
            }
            let requestID = UUID().uuidString.lowercased()
            try CodexDesktopIPCClient.write(
                CodexDesktopIPCFrameCodec.encode(
                    try CodexDesktopIPCMessageFactory.historyRequest(
                        requestID: requestID,
                        clientID: clientID,
                        threadID: threadID,
                        ownerClientID: ownerClientID
                    )
                ),
                to: descriptor
            )

            var snapshot: CodexDesktopThreadSnapshot?
            for _ in 0..<CodexDesktopIPCClient.maximumFramesPerResponse {
                let payload = try CodexDesktopIPCClient.readFrame(from: descriptor)
                let object = try CodexDesktopIPCMessageFactory.jsonObject(payload)
                if let rejection = try CodexDesktopIPCMessageFactory.clientDiscoveryRejection(
                    for: object
                ) {
                    try CodexDesktopIPCClient.write(
                        CodexDesktopIPCFrameCodec.encode(rejection),
                        to: descriptor
                    )
                    continue
                }
                if let received = CodexDesktopIPCMessageFactory.threadSnapshot(
                    in: object,
                    identity: TaskIdentity(hostID: hostID, threadID: threadID),
                    observedAt: .now
                ) {
                    snapshot = received
                    continue
                }
                guard object["type"] as? String == "response",
                      object["requestId"] as? String == requestID else { continue }
                guard object["resultType"] as? String == "success",
                      object["method"] as? String == CodexDesktopIPCMessageFactory.historyMethod,
                      let snapshot else { throw CocoaError(.fileReadCorruptFile) }
                return snapshot
            }
            throw CocoaError(.fileReadCorruptFile)
        }

        private func establishConnectionIfNeeded() throws -> CodexDesktopThreadSnapshot? {
            guard descriptor < 0 else { return nil }
            let connectedDescriptor = try CodexDesktopIPCClient.connectToRouter(timeoutSeconds: 2)
            do {
                let initializeID = UUID().uuidString.lowercased()
                try CodexDesktopIPCClient.write(
                    CodexDesktopIPCFrameCodec.encode(
                        try CodexDesktopIPCMessageFactory.initializeRequest(
                            requestID: initializeID,
                            clientType: CodexDesktopIPCClient.clientType
                        )
                    ),
                    to: connectedDescriptor
                )
                let initializeResponse = try CodexDesktopIPCClient.readResponse(
                    requestID: initializeID,
                    from: connectedDescriptor
                )
                guard let initializedClientID = try CodexDesktopIPCMessageFactory.initializedClientID(
                    initializeResponse,
                    requestID: initializeID
                ) else { throw CocoaError(.fileReadCorruptFile) }

                // Subscribe first. Owners publish a state snapshot as part of the
                // following handshake, and that publication can arrive before or
                // after the discovery response.
                try CodexDesktopIPCClient.write(
                    CodexDesktopIPCFrameCodec.encode(
                        try CodexDesktopIPCMessageFactory.followingChangedBroadcast(
                            clientID: initializedClientID,
                            threadID: threadID,
                            hostID: hostID,
                            following: true
                        )
                    ),
                    to: connectedDescriptor
                )
                let discoveryID = UUID().uuidString.lowercased()
                try CodexDesktopIPCClient.write(
                    CodexDesktopIPCFrameCodec.encode(
                        try CodexDesktopIPCMessageFactory.ownerDiscoveryRequest(
                            requestID: discoveryID,
                            clientID: initializedClientID,
                            threadID: threadID,
                            hostID: hostID
                        )
                    ),
                    to: connectedDescriptor
                )
                let discovery = try readDiscoveryResult(
                    requestID: discoveryID,
                    identity: TaskIdentity(hostID: hostID, threadID: threadID),
                    from: connectedDescriptor
                )
                guard discovery.ownerClientID != nil || discovery.snapshot != nil
                else { throw CocoaError(.fileReadCorruptFile) }
                descriptor = connectedDescriptor
                clientID = initializedClientID
                ownerClientID = discovery.ownerClientID
                return discovery.snapshot
            } catch {
                Darwin.close(connectedDescriptor)
                throw error
            }
        }

        private func readDiscoveryResult(
            requestID: String,
            identity: TaskIdentity,
            from descriptor: Int32
        ) throws -> DiscoveryResult {
            var ownerClientID: String?
            var snapshot: CodexDesktopThreadSnapshot?
            var receivedResponse = false
            for _ in 0..<CodexDesktopIPCClient.maximumFramesPerResponse {
                // If discovery says no owner, leave a short grace period for the
                // snapshot triggered by the preceding following broadcast.
                if receivedResponse,
                   !CodexDesktopIPCClient.waitForReadable(descriptor, timeoutMilliseconds: 500) {
                    break
                }
                let payload = try CodexDesktopIPCClient.readFrame(from: descriptor)
                let object = try CodexDesktopIPCMessageFactory.jsonObject(payload)
                if let rejection = try CodexDesktopIPCMessageFactory.clientDiscoveryRejection(
                    for: object
                ) {
                    try CodexDesktopIPCClient.write(
                        CodexDesktopIPCFrameCodec.encode(rejection),
                        to: descriptor
                    )
                    continue
                }
                if let received = CodexDesktopIPCMessageFactory.threadSnapshot(
                    in: object,
                    identity: identity,
                    observedAt: .now
                ) {
                    snapshot = received
                    // The exact snapshot is the requested result. Waiting for a
                    // separate discovery response here added 8-10 seconds on
                    // Desktop versions that publish the snapshot but leave owner
                    // discovery unresolved, expiring its 15-second state evidence
                    // before the catalog could render it.
                    break
                }
                guard object["type"] as? String == "response",
                      object["requestId"] as? String == requestID
                else { continue }
                receivedResponse = true
                ownerClientID = try CodexDesktopIPCMessageFactory.discoveredOwnerClientID(
                    in: payload,
                    requestID: requestID
                )
                if ownerClientID != nil || snapshot != nil { break }
            }
            return DiscoveryResult(ownerClientID: ownerClientID, snapshot: snapshot)
        }

        private func resetConnection() {
            guard descriptor >= 0 else { return }
            if let clientID,
               let payload = try? CodexDesktopIPCMessageFactory.followingChangedBroadcast(
                    clientID: clientID,
                    threadID: threadID,
                    hostID: hostID,
                    following: false
               ) {
                try? CodexDesktopIPCClient.write(
                    CodexDesktopIPCFrameCodec.encode(payload),
                    to: descriptor
                )
            }
            Darwin.close(descriptor)
            descriptor = -1
            clientID = nil
            ownerClientID = nil
        }
    }

    private static func submitUserMessageBlocking(threadID: String, text: String) throws -> Bool {
        let descriptor = try connectToRouter()
        defer { Darwin.close(descriptor) }
        let initializeID = UUID().uuidString.lowercased()
        try write(CodexDesktopIPCFrameCodec.encode(try CodexDesktopIPCMessageFactory.initializeRequest(requestID: initializeID, clientType: clientType)), to: descriptor)
        let initializeResponse = try readResponse(requestID: initializeID, from: descriptor)
        guard let clientID = try CodexDesktopIPCMessageFactory.initializedClientID(initializeResponse, requestID: initializeID) else { return false }
        let requestID = UUID().uuidString.lowercased()
        try write(CodexDesktopIPCFrameCodec.encode(try CodexDesktopIPCMessageFactory.replyRequest(requestID: requestID, clientID: clientID, threadID: threadID, text: text)), to: descriptor)
        return try CodexDesktopIPCMessageFactory.isConfirmedReplyResponse(try readResponse(requestID: requestID, from: descriptor), requestID: requestID)
    }

    private static func connectToRouter(timeoutSeconds: Int = 15) throws -> Int32 {
        var lastError: Error?
        for socketPath in routerSocketPaths() {
            do { return try connectToRouter(at: socketPath, timeoutSeconds: timeoutSeconds) }
            catch { lastError = error }
        }
        throw lastError ?? CocoaError(.fileNoSuchFile)
    }

    static func routerSocketPaths(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        temporaryDirectory: URL = FileManager.default.temporaryDirectory,
        userID: uid_t = getuid()
    ) -> [String] {
        let primary = homeDirectory
            .appending(path: ".codex/ipc/ipc.sock")
            .path
        let legacy = temporaryDirectory
            .appending(path: "codex-ipc")
            .appending(path: "ipc-\(userID).sock")
            .path
        return [primary, legacy]
    }

    private static func connectToRouter(at socketPath: String, timeoutSeconds: Int) throws -> Int32 {
        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw posixError() }

        do {
            try configure(descriptor, timeoutSeconds: timeoutSeconds)
            var address = sockaddr_un()
            address.sun_family = sa_family_t(AF_UNIX)
            let pathBytes = socketPath.utf8CString
            let capacity = MemoryLayout.size(ofValue: address.sun_path)
            guard pathBytes.count <= capacity else {
                throw CocoaError(.fileWriteInvalidFileName)
            }
            withUnsafeMutablePointer(to: &address.sun_path) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: capacity) { destination in
                    for (index, byte) in pathBytes.enumerated() {
                        destination[index] = byte
                    }
                }
            }
            let addressLength = socklen_t(MemoryLayout<sa_family_t>.size + pathBytes.count)
            let result = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(descriptor, $0, addressLength)
                }
            }
            guard result == 0 else { throw posixError() }
            return descriptor
        } catch {
            Darwin.close(descriptor)
            throw error
        }
    }

    private static func configure(_ descriptor: Int32, timeoutSeconds: Int) throws {
        var timeout = timeval(tv_sec: timeoutSeconds, tv_usec: 0)
        guard setsockopt(
            descriptor,
            SOL_SOCKET,
            SO_RCVTIMEO,
            &timeout,
            socklen_t(MemoryLayout<timeval>.size)
        ) == 0,
        setsockopt(
            descriptor,
            SOL_SOCKET,
            SO_SNDTIMEO,
            &timeout,
            socklen_t(MemoryLayout<timeval>.size)
        ) == 0 else { throw posixError() }

        var noSignal: Int32 = 1
        guard setsockopt(
            descriptor,
            SOL_SOCKET,
            SO_NOSIGPIPE,
            &noSignal,
            socklen_t(MemoryLayout<Int32>.size)
        ) == 0 else { throw posixError() }
    }

    private static func write(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(descriptor, base.advanced(by: offset), bytes.count - offset)
                guard count > 0 else { throw posixError() }
                offset += count
            }
        }
    }

    private static func readResponse(requestID: String, from descriptor: Int32) throws -> Data {
        for _ in 0..<maximumFramesPerResponse {
            let payload = try readFrame(from: descriptor)
            if let rejection = try CodexDesktopIPCMessageFactory.clientDiscoveryRejection(
                for: payload
            ) {
                try write(CodexDesktopIPCFrameCodec.encode(rejection), to: descriptor)
                continue
            }
            guard let object = try JSONSerialization.jsonObject(with: payload) as? [String: Any]
            else { continue }
            if ProcessInfo.processInfo.environment["REHIREBAR_IPC_DEBUG"] == "1" {
                fputs(
                    "ipc stage=\(object["method"] as? String ?? "unknown") "
                        + "result=\(object["resultType"] as? String ?? "-") "
                        + "error=\(SanitizedDiagnostic.errorCategory(object["error"])) "
                        + "request=\(SanitizedDiagnostic.identifier(object["requestId"])) "
                        + "owner=\(SanitizedDiagnostic.identifier(object["handledByClientId"]))\n",
                    stderr
                )
            }
            if object["type"] as? String == "response",
               object["requestId"] as? String == requestID {
                return payload
            }
        }
        throw CocoaError(.fileReadCorruptFile)
    }

    private static func readFrame(from descriptor: Int32) throws -> Data {
        let header = try readExactly(4, from: descriptor)
        let length = header.enumerated().reduce(UInt32(0)) { value, entry in
            value | (UInt32(entry.element) << UInt32(entry.offset * 8))
        }
        guard length <= 256 * 1024 * 1024 else { throw CocoaError(.fileReadCorruptFile) }
        return try readExactly(Int(length), from: descriptor)
    }

    private static func waitForReadable(
        _ descriptor: Int32,
        timeoutMilliseconds: Int32
    ) -> Bool {
        var item = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
        while true {
            let result = Darwin.poll(&item, 1, timeoutMilliseconds)
            if result >= 0 { return result > 0 && (item.revents & Int16(POLLIN)) != 0 }
            if errno != EINTR { return false }
        }
    }

    private static func readExactly(_ count: Int, from descriptor: Int32) throws -> Data {
        var data = Data(count: count)
        var offset = 0
        while offset < count {
            let bytesRead = data.withUnsafeMutableBytes { bytes in
                Darwin.read(descriptor, bytes.baseAddress!.advanced(by: offset), count - offset)
            }
            guard bytesRead > 0 else { throw posixError() }
            offset += bytesRead
        }
        return data
    }

    private static func posixError() -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }
}
