import Foundation
import Darwin

final class ConversationApprovalStore: @unchecked Sendable {
    static let changedNotification = Notification.Name("com.damgood.RehireBar.approvalChanged")
    private let url: URL
    private let lock = NSLock()

    convenience init() { self.init(url: ConversationApprovalStore.defaultURL()) }
    init(url: URL) { self.url = url }

    static func defaultURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/RehireBar/approvals.json")
    }

    func enqueue(_ approval: ConversationApproval) throws {
        try locked {
            var records = try loadUnlocked()
            guard !records.contains(where: { $0.id == approval.id }) else { return }
            records.append(approval)
            records.sort { $0.createdAt < $1.createdAt }
            try saveUnlocked(Array(records.suffix(32)))
        }
    }

    func pending(at now: Date = Date()) throws -> [ConversationApproval] {
        try locked {
            try loadUnlocked().filter { $0.deliveryState != .delivered && $0.expiresAt > now }
                .sorted { $0.createdAt < $1.createdAt }
        }
    }

    func setState(id: String, _ state: ConversationApproval.DeliveryState) throws {
        try locked {
            var records = try loadUnlocked()
            guard let index = records.firstIndex(where: { $0.id == id }) else { return }
            records[index].deliveryState = state
            try saveUnlocked(records)
        }
    }

    func markDelivered(id: String) throws { try setState(id: id, .delivered) }

    /// A separate inode survives atomic replacement of the queue itself.
    private func locked<T>(_ body: () throws -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let descriptor = Darwin.open(url.path + ".lock",
                                     O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK, 0o600)
        guard descriptor >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        defer { Darwin.close(descriptor) }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG else {
            throw POSIXError(.EFTYPE)
        }
        while flock(descriptor, LOCK_EX) != 0 {
            if errno != EINTR { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        }
        defer { flock(descriptor, LOCK_UN) }
        return try body()
    }

    /// Revalidate and reserve the exact displayed decision within the write lock.
    func beginDelivery(_ approval: ConversationApproval, at now: Date) throws -> Bool {
        try locked {
            var records = try loadUnlocked()
            guard let index = records.firstIndex(where: { $0.id == approval.id }),
                  records[index].deliveryState != .delivered,
                  records[index].expiresAt > now,
                  records[index].threadID == approval.threadID,
                  records[index].hostID == approval.hostID,
                  records[index].question == approval.question else { return false }
            records[index].deliveryState = .delivering
            try saveUnlocked(records)
            return true
        }
    }

    private func loadUnlocked() throws -> [ConversationApproval] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return try JSONDecoder().decode([ConversationApproval].self, from: Data(contentsOf: url))
    }

    private func saveUnlocked(_ records: [ConversationApproval]) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(records).write(to: url, options: .atomic)
    }
}
