import Darwin
import Foundation

@MainActor
final class SingleInstanceGuard {
    static let shared = SingleInstanceGuard()

    private let lockPath: String
    private var descriptor: Int32 = -1

    init(identifier: String = "com.bigbom.RehireBar") {
        lockPath = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("\(identifier).instance.lock", isDirectory: false)
            .path
    }

    func acquire() -> Bool {
        if descriptor >= 0 { return true }

        let candidate = Darwin.open(
            lockPath,
            O_CREAT | O_RDWR | O_EXLOCK | O_NONBLOCK,
            S_IRUSR | S_IWUSR
        )
        guard candidate >= 0 else { return false }

        descriptor = candidate
        return true
    }

    func release() {
        guard descriptor >= 0 else { return }
        Darwin.close(descriptor)
        descriptor = -1
    }
}
