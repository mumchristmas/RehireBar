import Darwin
import Foundation

enum CodexVersionProbe {
    /// Runs only the resolved CLI's version command. Output and elapsed time are
    /// bounded; diagnostics never echo an arbitrary executable's output.
    static func read(executable: URL, timeout: TimeInterval = 2) -> String? {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = executable
        process.arguments = ["--version"]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        defer {
            try? pipe.fileHandleForReading.close()
            try? pipe.fileHandleForWriting.close()
        }
        do { try process.run() } catch { return nil }
        try? pipe.fileHandleForWriting.close()
        let descriptor = pipe.fileHandleForReading.fileDescriptor
        let flags = fcntl(descriptor, F_GETFL)
        guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
            stop(process)
            return nil
        }
        let deadline = ProcessInfo.processInfo.systemUptime + max(0, timeout)
        var output = Data()
        var buffer = [UInt8](repeating: 0, count: 1_024)
        while true {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count > 0 {
                output.append(contentsOf: buffer.prefix(count))
                if output.count > 4_096 { stop(process); return nil }
            } else if count == 0 || (count < 0 && !process.isRunning) {
                break
            } else if errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR {
                stop(process)
                return nil
            }
            guard ProcessInfo.processInfo.systemUptime < deadline else {
                stop(process)
                return nil
            }
            if count <= 0 { usleep(10_000) }
        }
        // EOF alone does not imply exit: a broken wrapper can close stdout and
        // keep running. Wait for the child only within the same deadline.
        while process.isRunning && ProcessInfo.processInfo.systemUptime < deadline {
            usleep(10_000)
        }
        guard !process.isRunning else { stop(process); return nil }
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let text = String(data: output, encoding: .utf8) else { return nil }
        return parse(text)
    }

    static func parse(_ output: String) -> String? {
        let line = output.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = "codex-cli "
        guard line.hasPrefix(prefix) else { return nil }
        let version = String(line.dropFirst(prefix.count))
        guard version.range(
            of: #"\A[0-9]+(?:\.[0-9]+){1,3}(?:[-+][A-Za-z0-9.-]+)?\z"#,
            options: .regularExpression
        ) != nil else { return nil }
        return version
    }

    private static func stop(_ process: Process) {
        if process.isRunning {
            process.terminate()
            let deadline = ProcessInfo.processInfo.systemUptime + 0.25
            while process.isRunning && ProcessInfo.processInfo.systemUptime < deadline {
                usleep(10_000)
            }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
        process.waitUntilExit()
    }
}
