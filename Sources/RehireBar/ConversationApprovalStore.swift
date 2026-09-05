import Foundation

final class ConversationApprovalStore: @unchecked Sendable {
    static let changedNotification = Notification.Name("com.bigbom.RehireBar.approvalChanged")
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
            try loadUnlocked().filter { $0.deliveryState != .delivered && $0.expiresAt >= now }
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

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock(); defer { lock.unlock() }; return try body()
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
