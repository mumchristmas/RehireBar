import Foundation

protocol ThreadMetadataCaching: Sendable {
    func metadata(
        for identity: TaskIdentity,
        sourceVersion: Date
    ) async -> CodexThreadMetadata?
}

/// Catalog timestamps are the invalidation version. A stable row therefore reuses
/// its title/model/effort instead of opening state_5.sqlite once per task per tick.
actor ThreadMetadataCache: ThreadMetadataCaching {
    private struct Entry: Sendable {
        let sourceVersion: Date
        let value: CodexThreadMetadata?
    }

    private let reader: any ThreadMetadataReading
    private var entries: [TaskIdentity: Entry] = [:]

    init(reader: any ThreadMetadataReading) {
        self.reader = reader
    }

    func metadata(
        for identity: TaskIdentity,
        sourceVersion: Date
    ) -> CodexThreadMetadata? {
        if let entry = entries[identity], entry.sourceVersion == sourceVersion {
            return entry.value
        }
        let value = try? reader.metadata(for: identity.threadID)
        entries[identity] = Entry(sourceVersion: sourceVersion, value: value)
        if entries.count > 128,
           let evictionKey = entries.keys.first(where: { $0 != identity }) {
            entries.removeValue(forKey: evictionKey)
        }
        return value
    }
}
