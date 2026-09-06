import Foundation

/// One bundle-derived version for menus, command-line inspection, and client metadata.
struct ApplicationVersion: Equatable, Sendable {
    let name: String?
    let version: String?
    let build: String?

    static var current: Self {
        // XCTest and other host tools have their own version. Do not advertise it
        // as RehireBar's when running an unpackaged development/test executable.
        guard Bundle.main.executableURL?.lastPathComponent == "RehireBar" else { return .init(info: [:]) }
        return .init(info: Bundle.main.infoDictionary ?? [:])
    }

    init(info: [String: Any]) {
        func value(_ key: String) -> String? {
            guard let raw = info[key] as? String else { return nil }
            let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : text
        }
        name = value("CFBundleDisplayName") ?? value("CFBundleName")
        version = value("CFBundleShortVersionString")
        build = value("CFBundleVersion")
    }

    var displayText: String {
        let label: String
        switch (version, build) {
        case let (version?, build?): label = "\(version) (\(build))"
        case let (version?, nil): label = version
        case let (nil, build?): label = "build \(build)"
        case (nil, nil): label = "version unavailable"
        }
        return "\(name ?? "RehireBar") \(label)"
    }
}
