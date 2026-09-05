import Darwin
import Foundation

/// Pins both descriptors and bounds the read, including files replaced while read.
enum BoundedJSONFileReader {
    static func read(_ file: URL, in directory: URL, maximumBytes: Int) -> Data? {
        guard maximumBytes > 0, maximumBytes < Int.max else { return nil }
        let root = Darwin.open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard root >= 0 else { return nil }
        defer { Darwin.close(root) }
        let descriptor = Darwin.openat(
            root, file.lastPathComponent, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC
        )
        guard descriptor >= 0 else { return nil }
        defer { Darwin.close(descriptor) }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              (metadata.st_mode & S_IFMT) == S_IFREG,
              metadata.st_size >= 0,
              metadata.st_size <= maximumBytes else { return nil }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        guard let data = try? handle.read(upToCount: maximumBytes + 1),
              data.count <= maximumBytes else { return nil }
        return data
    }
}
