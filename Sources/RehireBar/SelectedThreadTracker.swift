import AppKit
import ApplicationServices
import Foundation

enum CodexThreadRouteParser {
    private static let expression = try! NSRegularExpression(
        pattern: #"(?:/(?:local|remote)/|/hotkey-window/(?:thread|remote)/|(?:local|remote)%3A)([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})(?:[^0-9a-fA-F]|$)"#
    )

    static func threadID(in value: String) -> String? {
        let range = NSRange(value.startIndex..., in: value)
        guard let match = expression.firstMatch(in: value, range: range),
              let identifierRange = Range(match.range(at: 1), in: value),
              let identifier = UUID(uuidString: String(value[identifierRange]))
        else { return nil }
        return identifier.uuidString.lowercased()
    }
}

final class SelectedThreadState: @unchecked Sendable {
    private let lock = NSLock()
    private var storedThreadID: String?

    init(initialThreadID: String?) {
        storedThreadID = Self.normalized(initialThreadID)
    }

    var threadID: String? {
        lock.lock()
        defer { lock.unlock() }
        return storedThreadID
    }

    @discardableResult
    func update(threadID: String) -> Bool {
        guard let normalized = Self.normalized(threadID) else { return false }
        lock.lock()
        defer { lock.unlock() }
        guard storedThreadID != normalized else { return false }
        storedThreadID = normalized
        return true
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value, let identifier = UUID(uuidString: value) else { return nil }
        return identifier.uuidString.lowercased()
    }
}

@MainActor
protocol SelectedThreadReading: AnyObject {
    func selectedThreadID(promptIfNeeded: Bool) -> String?
}

enum CodexDesktopSelectedThreadLogDecoder {
    static func reduce(_ text: String, selectedThreadID: String? = nil) -> String? {
        text.split(whereSeparator: \Character.isNewline).reduce(selectedThreadID) { selected, line in
            reduceLine(String(line), selectedThreadID: selected)
        }
    }

    private static func reduceLine(_ line: String, selectedThreadID: String?) -> String? {
        guard line.contains("thread_stream_view_activity_changed"),
              line.contains("rendererWindowAppearance=primary"),
              line.contains("rendererWindowFocused=true"),
              line.contains("rendererWindowVisible=true"),
              let threadID = field(named: "conversationId", in: line),
              let identifier = UUID(uuidString: threadID)
        else { return selectedThreadID }

        let normalized = identifier.uuidString.lowercased()
        if line.contains(" active=true ") {
            return normalized
        }
        if line.contains(" active=false "), selectedThreadID == normalized {
            return nil
        }
        return selectedThreadID
    }

    private static func field(named name: String, in line: String) -> String? {
        let prefix = "\(name)="
        guard let range = line.range(of: prefix) else { return nil }
        let tail = line[range.upperBound...]
        let value = tail.prefix { !$0.isWhitespace }
        return value.isEmpty ? nil : String(value)
    }
}

/// Follows the task shown in Codex's focused primary window without requiring
/// Accessibility permission. Codex Desktop logs only route/activity metadata here;
/// prompt and response contents are never inspected.
@MainActor
final class CodexDesktopSelectedThreadReader: SelectedThreadReading {
    private let logRoot: URL
    private let maximumInitialBytes: UInt64
    private var currentLogFile: URL?
    private var readOffset: UInt64 = 0
    private var pendingBytes = Data()
    private var latestThreadID: String?

    init(
        logRoot: URL = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Logs/com.openai.codex"),
        maximumInitialBytes: UInt64 = 8 * 1_024 * 1_024
    ) {
        self.logRoot = logRoot
        self.maximumInitialBytes = maximumInitialBytes
    }

    func selectedThreadID(promptIfNeeded: Bool) -> String? {
        guard let file = newestLogFile(), let handle = try? FileHandle(forReadingFrom: file) else {
            return latestThreadID
        }
        defer { try? handle.close() }

        guard let length = try? handle.seekToEnd() else { return latestThreadID }
        let fileChanged = currentLogFile?.standardizedFileURL != file.standardizedFileURL
        if fileChanged || length < readOffset {
            currentLogFile = file
            readOffset = length > maximumInitialBytes ? length - maximumInitialBytes : 0
            pendingBytes.removeAll(keepingCapacity: true)
            latestThreadID = nil
        }
        guard length > readOffset else { return latestThreadID }

        do {
            try handle.seek(toOffset: readOffset)
            let newBytes = try handle.readToEnd() ?? Data()
            readOffset = length
            consume(newBytes)
        } catch {
            return latestThreadID
        }
        return latestThreadID
    }

    private func consume(_ newBytes: Data) {
        pendingBytes.append(newBytes)
        let newline = Data([0x0A])
        guard let finalNewline = pendingBytes.range(of: newline, options: .backwards) else { return }

        let complete = pendingBytes[..<finalNewline.upperBound]
        pendingBytes = Data(pendingBytes[finalNewline.upperBound...])
        guard let text = String(data: complete, encoding: .utf8) else { return }
        latestThreadID = CodexDesktopSelectedThreadLogDecoder.reduce(
            text,
            selectedThreadID: latestThreadID
        )
    }

    private func newestLogFile() -> URL? {
        guard let enumerator = FileManager.default.enumerator(
            at: logRoot,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }

        var newest: (url: URL, date: Date)?
        for case let file as URL in enumerator
            where file.pathExtension == "log" && file.lastPathComponent.contains("-t0-")
        {
            let values = try? file.resourceValues(forKeys: [
                .contentModificationDateKey,
                .isRegularFileKey,
            ])
            guard values?.isRegularFile == true else { continue }
            let candidate = (file, values?.contentModificationDate ?? .distantPast)
            if newest == nil || candidate.1 > newest!.date {
                newest = candidate
            }
        }
        return newest?.url
    }
}

@MainActor
final class ProductionSelectedThreadReader: SelectedThreadReading {
    private let desktopLog: any SelectedThreadReading
    private let accessibility: any SelectedThreadReading

    init(
        desktopLog: any SelectedThreadReading = CodexDesktopSelectedThreadReader(),
        accessibility: any SelectedThreadReading = AccessibilitySelectedThreadReader()
    ) {
        self.desktopLog = desktopLog
        self.accessibility = accessibility
    }

    func selectedThreadID(promptIfNeeded: Bool) -> String? {
        desktopLog.selectedThreadID(promptIfNeeded: false)
            ?? accessibility.selectedThreadID(promptIfNeeded: promptIfNeeded)
    }
}

@MainActor
final class AccessibilitySelectedThreadReader: SelectedThreadReading {
    private static let maximumElements = 4_000
    private static let maximumDepth = 24

    private let bundleIdentifier: String

    init(bundleIdentifier: String = CodexActivityMonitor.defaultBundleIdentifier) {
        self.bundleIdentifier = bundleIdentifier
    }

    func selectedThreadID(promptIfNeeded: Bool) -> String? {
        guard isTrusted(promptIfNeeded: promptIfNeeded),
              let application = NSRunningApplication
                .runningApplications(withBundleIdentifier: bundleIdentifier)
                .first(where: { !$0.isTerminated })
        else { return nil }

        let applicationElement = AXUIElementCreateApplication(application.processIdentifier)
        let root = elementAttribute(kAXFocusedWindowAttribute, from: applicationElement)
            ?? elementsAttribute(kAXWindowsAttribute, from: applicationElement).first
            ?? applicationElement
        return bestThreadID(in: root)
    }

    private func isTrusted(promptIfNeeded: Bool) -> Bool {
        guard promptIfNeeded else { return AXIsProcessTrusted() }
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    private func bestThreadID(in root: AXUIElement) -> String? {
        var queue: [(AXUIElement, Int)] = [(root, 0)]
        var cursor = 0
        var candidates: [(score: Int, order: Int, id: String)] = []

        while cursor < queue.count, cursor < Self.maximumElements {
            let (element, depth) = queue[cursor]
            cursor += 1
            let selected = boolAttribute(kAXSelectedAttribute, from: element)
            let focused = boolAttribute(kAXFocusedAttribute, from: element)
            for (index, attribute) in candidateAttributes.enumerated() {
                guard let value = stringAttribute(attribute, from: element),
                      let threadID = CodexThreadRouteParser.threadID(in: value)
                else { continue }
                let score = (selected ? 400 : 0) + (focused ? 300 : 0)
                    + (attribute == kAXURLAttribute ? 200 : 100) - index
                candidates.append((score, cursor, threadID))
            }
            if depth < Self.maximumDepth {
                queue.append(contentsOf: elementsAttribute(kAXChildrenAttribute, from: element).map {
                    ($0, depth + 1)
                })
            }
        }

        return candidates.max {
            $0.score == $1.score ? $0.order > $1.order : $0.score < $1.score
        }?.id
    }

    private var candidateAttributes: [String] {
        [
            kAXURLAttribute,
            kAXIdentifierAttribute,
            // Older SDKs omit the symbol; unsupported AX attributes return nil.
            "AXDOMIdentifier",
            kAXValueAttribute,
            kAXTitleAttribute,
            kAXDescriptionAttribute,
        ]
    }

    private func rawAttribute(_ attribute: String, from element: AXUIElement) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
            return nil
        }
        return value
    }

    private func elementAttribute(_ attribute: String, from element: AXUIElement) -> AXUIElement? {
        guard let value = rawAttribute(attribute, from: element),
              CFGetTypeID(value) == AXUIElementGetTypeID()
        else { return nil }
        return unsafeDowncast(value, to: AXUIElement.self)
    }

    private func elementsAttribute(_ attribute: String, from element: AXUIElement) -> [AXUIElement] {
        guard let values = rawAttribute(attribute, from: element) as? [CFTypeRef] else { return [] }
        return values.compactMap { value in
            guard CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
            return unsafeDowncast(value, to: AXUIElement.self)
        }
    }

    private func boolAttribute(_ attribute: String, from element: AXUIElement) -> Bool {
        rawAttribute(attribute, from: element) as? Bool ?? false
    }

    private func stringAttribute(_ attribute: String, from element: AXUIElement) -> String? {
        let value = rawAttribute(attribute, from: element)
        if let string = value as? String { return string }
        if let url = value as? URL { return url.absoluteString }
        return nil
    }
}

@MainActor
protocol SelectedThreadMonitoring: AnyObject {
    func start(_ handler: @escaping @MainActor @Sendable () -> Void)
    func setCodexActive(_ active: Bool)
    func stop()
}

@MainActor
final class SelectedThreadTracker: SelectedThreadMonitoring {
    static let persistedThreadIDKey = "selectedCodexThreadID"
    private static let pollingInterval: TimeInterval = 1

    private let state: SelectedThreadState
    private let reader: any SelectedThreadReading
    private let defaults: UserDefaults
    private var handler: (@MainActor @Sendable () -> Void)?
    private var timer: Timer?
    private var isActive = false
    private var didPrompt = false

    init(
        state: SelectedThreadState,
        reader: any SelectedThreadReading = ProductionSelectedThreadReader(),
        defaults: UserDefaults = .standard
    ) {
        self.state = state
        self.reader = reader
        self.defaults = defaults
    }

    func start(_ handler: @escaping @MainActor @Sendable () -> Void) {
        self.handler = handler
        if isActive { beginPolling() }
    }

    func setCodexActive(_ active: Bool) {
        guard active != isActive else { return }
        isActive = active
        if active {
            beginPolling()
        } else {
            timer?.invalidate()
            timer = nil
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        handler = nil
        isActive = false
    }

    func pollNow() {
        let prompt = !didPrompt
        didPrompt = true
        guard let threadID = reader.selectedThreadID(promptIfNeeded: prompt),
              state.update(threadID: threadID)
        else { return }
        defaults.set(threadID, forKey: Self.persistedThreadIDKey)
        handler?()
    }

    private func beginPolling() {
        pollNow()
        guard handler != nil, timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: Self.pollingInterval, repeats: true) {
            [weak self] _ in
            Task { @MainActor in self?.pollNow() }
        }
    }
}

@MainActor
final class NoopSelectedThreadMonitor: SelectedThreadMonitoring {
    func start(_ handler: @escaping @MainActor @Sendable () -> Void) {}
    func setCodexActive(_ active: Bool) {}
    func stop() {}
}
