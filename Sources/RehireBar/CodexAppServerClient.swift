import Foundation
import Darwin

protocol UsageFetching: Sendable {
    func fetch() async throws -> UsageSnapshot
}

enum CodexAppServerError: Error, Equatable, Sendable {
    case invalidResponse
    case serverError(code: Int)
    case timedOut
    case unavailable
}

protocol AppServerRunning: AnyObject, Sendable {
    func run() throws -> UsageSnapshot
    func cancelAndWait()
}

struct CodexAppServerClient: UsageFetching, Sendable {
    static let maximumResponseLineBytes = 1_048_576
    private let runnerFactory: @Sendable () -> any AppServerRunning

    init(runnerFactory: @escaping @Sendable () -> any AppServerRunning = {
        FoundationAppServerRunner()
    }) {
        self.runnerFactory = runnerFactory
    }
    static let initializeRequest = Data(
        (#"{"id":1,"method":"initialize","params":{"clientInfo":{"name":"rehirebar","version":"0.5.0"}}}"# + "\n").utf8
    )
    static let initializedNotification = Data(
        (#"{"method":"initialized","params":{}}"# + "\n").utf8
    )
    static let rateLimitsRequest = Data(
        (#"{"id":2,"method":"account/rateLimits/read","params":{}}"# + "\n").utf8
    )

    func fetch() async throws -> UsageSnapshot {
        let runner = runnerFactory()
        return try await withTaskCancellationHandler {
            try await Task.detached { try runner.run() }.value
        } onCancel: {
            runner.cancelAndWait()
        }
    }

    static func resolveExecutable(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        knownCandidates: [URL]? = nil
    ) throws -> URL {
        let candidates: [URL]
        if let override = environment["REHIREBAR_CODEX_PATH"], !override.isEmpty {
            guard (override as NSString).isAbsolutePath else {
                throw CodexAppServerError.unavailable
            }
            candidates = [URL(fileURLWithPath: override)]
        } else {
            candidates = knownCandidates ?? [
                homeDirectory.appending(path: ".local/bin/codex"),
                URL(fileURLWithPath: "/Applications/ChatGPT.app/Contents/Resources/codex"),
                URL(fileURLWithPath: "/opt/homebrew/bin/codex"),
                URL(fileURLWithPath: "/usr/local/bin/codex"),
            ]
        }
        for candidate in candidates {
            let resolvedCandidate = candidate.resolvingSymlinksInPath().standardizedFileURL
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: resolvedCandidate.path, isDirectory: &isDirectory),
                  !isDirectory.boolValue,
                  FileManager.default.isExecutableFile(atPath: resolvedCandidate.path) else { continue }
            let values = try? resolvedCandidate.resourceValues(forKeys: [.isRegularFileKey])
            if values?.isRegularFile == true { return resolvedCandidate }
        }
        throw CodexAppServerError.unavailable
    }

    static func decodeRateLimits(_ data: Data, observedAt: Date) throws -> UsageSnapshot {
        let response: RateLimitsResponse
        do {
            response = try JSONDecoder().decode(RateLimitsResponse.self, from: data)
        } catch {
            throw CodexAppServerError.invalidResponse
        }

        guard response.id == 2 else {
            throw CodexAppServerError.invalidResponse
        }
        if let error = response.error {
            throw CodexAppServerError.serverError(code: error.code)
        }
        guard let rateLimits = response.result?.rateLimits else {
            throw CodexAppServerError.invalidResponse
        }

        return try UsageSnapshot.from(
            primary: rateLimits.primary?.rawValue,
            secondary: rateLimits.secondary?.rawValue,
            observedAt: observedAt
        )
    }

    static func transact(
        standardInput: FileHandle,
        outputDescriptor: Int32,
        isCancelled: @escaping () -> Bool = { false }
    ) throws -> UsageSnapshot {
        do {
            try standardInput.write(contentsOf: initializeRequest)
            let initialization = try readResponse(
                id: 1,
                from: outputDescriptor, timeoutSeconds: 5, isCancelled: isCancelled
            )
            try validateInitialization(initialization)

            try standardInput.write(contentsOf: initializedNotification)
            try standardInput.write(contentsOf: rateLimitsRequest)
            let rateLimits = try readResponse(
                id: 2, from: outputDescriptor, timeoutSeconds: 5, isCancelled: isCancelled
            )
            return try decodeRateLimits(rateLimits, observedAt: Date())
        } catch let error as CodexAppServerError {
            throw error
        } catch {
            throw CodexAppServerError.unavailable
        }
    }

    static func validateInitialization(_ data: Data) throws {
        let envelope: ResponseEnvelope
        do {
            envelope = try JSONDecoder().decode(ResponseEnvelope.self, from: data)
        } catch {
            throw CodexAppServerError.invalidResponse
        }
        guard envelope.id == 1 else {
            throw CodexAppServerError.invalidResponse
        }
        if let error = envelope.error {
            throw CodexAppServerError.serverError(code: error.code)
        }
        guard envelope.result != nil else {
            throw CodexAppServerError.invalidResponse
        }
    }

    static func readResponse(
        id expectedID: Int,
        from fileDescriptor: Int32,
        timeoutSeconds: Int32,
        monotonicNanoseconds: () -> UInt64 = monotonicNow,
        poll pollDescriptor: (Int32, Int32) -> Int32 = pollForInput,
        readByte: (Int32) -> UInt8? = readSingleByte,
        isCancelled: () -> Bool = { false }
    ) throws -> Data {
        let nanosecondsPerSecond: UInt64 = 1_000_000_000
        let deadline = monotonicNanoseconds() + UInt64(timeoutSeconds) * nanosecondsPerSecond
        var line = Data()

        while true {
            if isCancelled() || Task.isCancelled { throw CancellationError() }
            let now = monotonicNanoseconds()
            guard now < deadline else {
                throw CodexAppServerError.timedOut
            }
            let nanosecondsRemaining = deadline - now
            let millisecondsRemaining = Int32(
                min(UInt64(Int32.max), (nanosecondsRemaining + 999_999) / 1_000_000)
            )

            let pollResult = pollDescriptor(fileDescriptor, millisecondsRemaining)
            guard pollResult > 0 else {
                if pollResult == 0 { throw CodexAppServerError.timedOut }
                if errno == EINTR { continue }
                throw CodexAppServerError.unavailable
            }

            guard let byte = readByte(fileDescriptor) else {
                throw CodexAppServerError.unavailable
            }

            if byte == 0x0A {
                if responseID(in: line) == expectedID {
                    return line
                }
                line.removeAll(keepingCapacity: true)
            } else {
                line.append(byte)
                if line.count > maximumResponseLineBytes {
                    throw CodexAppServerError.invalidResponse
                }
            }
        }
    }

    private static func monotonicNow() -> UInt64 {
        var time = timespec()
        clock_gettime(CLOCK_MONOTONIC, &time)
        return UInt64(time.tv_sec) * 1_000_000_000 + UInt64(time.tv_nsec)
    }

    private static func pollForInput(fileDescriptor: Int32, timeoutMilliseconds: Int32) -> Int32 {
        var descriptor = pollfd(fd: fileDescriptor, events: Int16(POLLIN), revents: 0)
        return Darwin.poll(&descriptor, 1, timeoutMilliseconds)
    }

    private static func readSingleByte(fileDescriptor: Int32) -> UInt8? {
        var byte: UInt8 = 0
        return Darwin.read(fileDescriptor, &byte, 1) == 1 ? byte : nil
    }

    private static func responseID(in data: Data) -> Int? {
        try? JSONDecoder().decode(ResponseEnvelope.self, from: data).id
    }
}

private final class FoundationAppServerRunner: AppServerRunning, @unchecked Sendable {
    private let condition = NSCondition()
    private var process: Process?
    private var input: Pipe?
    private var output: Pipe?
    private var cancelled = false

    func run() throws -> UsageSnapshot {
        let executable = try CodexAppServerClient.resolveExecutable()
        let process = Process(); let input = Pipe(); let output = Pipe()
        process.executableURL = executable
        process.arguments = ["app-server", "--stdio"]
        process.standardInput = input; process.standardOutput = output
        process.standardError = FileHandle.nullDevice

        condition.lock()
        if cancelled { condition.unlock(); throw CancellationError() }
        self.process = process; self.input = input; self.output = output
        condition.unlock()
        do { try process.run() } catch { finish(process); throw CodexAppServerError.unavailable }
        defer { finish(process) }
        return try CodexAppServerClient.transact(
            standardInput: input.fileHandleForWriting,
            outputDescriptor: output.fileHandleForReading.fileDescriptor,
            isCancelled: { [weak self] in self?.isCancelled ?? true }
        )
    }

    func cancelAndWait() {
        condition.lock(); cancelled = true
        let process = self.process; let input = self.input; let output = self.output
        condition.unlock()
        input?.fileHandleForWriting.closeFile()
        output?.fileHandleForReading.closeFile()
        if let process, process.isRunning { process.terminate(); process.waitUntilExit() }
    }

    private var isCancelled: Bool { condition.withLock { cancelled } }

    private func finish(_ process: Process) {
        input?.fileHandleForWriting.closeFile()
        if process.isRunning { process.terminate() }
        process.waitUntilExit()
        condition.withLock { self.process = nil; input = nil; output = nil }
    }
}

private struct ResponseEnvelope: Decodable {
    let id: Int?
    let result: EmptyResult?
    let error: ErrorValue?

    struct EmptyResult: Decodable {}

    struct ErrorValue: Decodable {
        let code: Int
    }
}

private struct RateLimitsResponse: Decodable {
    let id: Int
    let result: ResultValue?
    let error: ErrorValue?

    struct ResultValue: Decodable {
        let rateLimits: RateLimits
    }

    struct ErrorValue: Decodable {
        let code: Int
    }
}

private struct RateLimits: Decodable {
    let primary: Window?
    let secondary: Window?

    struct Window: Decodable {
        let usedPercent: Double
        let windowMinutes: Int
        let resetsAt: TimeInterval

        enum CodingKeys: String, CodingKey {
            case usedPercent
            case windowDurationMins
            case windowMinutes
            case resetsAt
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            usedPercent = try container.decode(Double.self, forKey: .usedPercent)
            windowMinutes = try container.decodeIfPresent(Int.self, forKey: .windowDurationMins)
                ?? container.decode(Int.self, forKey: .windowMinutes)
            resetsAt = try container.decode(TimeInterval.self, forKey: .resetsAt)
        }

        var rawValue: RawRateWindow {
            .init(usedPercent: usedPercent, windowMinutes: windowMinutes, resetsAt: resetsAt)
        }
    }
}
