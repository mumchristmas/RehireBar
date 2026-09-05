import Foundation

protocol SessionSnapshotCaching: Sendable {
    func snapshot(in candidate: SafeSessionCandidate) async -> CurrentSessionSnapshot?
}

/// Shares rollout parsing between the focused-task and catalog paths. Rollouts are
/// append-only in normal operation, so an inode + offset cursor can decode only
/// appended lines; truncation or rotation safely rebuilds the bounded accumulator.
actor SessionSnapshotCache: SessionSnapshotCaching {
    private struct Entry {
        let inode: UInt64
        let offset: UInt64
        let remainder: Data
        let accumulator: SessionSnapshotAccumulator
        let snapshot: CurrentSessionSnapshot?
    }

    private static let maximumInitialBytes: UInt64 = 16 * 1_024 * 1_024
    private var entries: [String: Entry] = [:]

    func snapshot(in candidate: SafeSessionCandidate) async -> CurrentSessionSnapshot? {
        let path = candidate.file.standardizedFileURL.path
        let previous = entries[path]
        guard let chunk = try? SessionLogUsageProvider.incrementalChunk(
            of: candidate.file,
            relativeTo: candidate.allowedRoot,
            previousInode: previous?.inode,
            previousOffset: previous?.offset,
            maximumBytes: Self.maximumInitialBytes
        ) else {
            entries.removeValue(forKey: path)
            return nil
        }
        if !chunk.didReset, chunk.data.isEmpty, let previous {
            return previous.snapshot
        }
        var accumulator = chunk.didReset
            ? SessionSnapshotAccumulator()
            : previous?.accumulator ?? SessionSnapshotAccumulator()
        var combined = Data()
        if !chunk.didReset { combined.append(previous?.remainder ?? Data()) }
        combined.append(chunk.data)
        let remainder: Data
        if let finalNewline = combined.lastIndex(of: 0x0A) {
            let complete = Data(combined[...finalNewline])
            autoreleasepool { accumulator.consume(complete) }
            remainder = Data(combined[combined.index(after: finalNewline)...])
        } else {
            remainder = Data(combined.suffix(64 * 1_024))
        }
        let snapshot = accumulator.snapshot(in: candidate)
        entries[path] = Entry(
            inode: chunk.inode,
            offset: chunk.length,
            remainder: remainder,
            accumulator: accumulator,
            snapshot: snapshot
        )
        return snapshot
    }
}
