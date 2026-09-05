import Foundation
import OSLog
import ServiceManagement

@MainActor
protocol LoginItemManaging: AnyObject {
    func register()
}

@MainActor
final class LoginItemManager: LoginItemManaging {
    private let logger = Logger(subsystem: "com.bigbom.RehireBar", category: "login-item")

    func register() {
        let bundleURL = Bundle.main.bundleURL.resolvingSymlinksInPath().standardizedFileURL
        guard Self.isInstalledApplication(bundleURL) else {
            logger.info("Skipping login-item registration outside an Applications folder")
            return
        }
        guard SMAppService.mainApp.status == .notRegistered else { return }

        do {
            try SMAppService.mainApp.register()
        } catch {
            logger.error("Could not register login item: \(error.localizedDescription, privacy: .public). Enable RehireBar in System Settings > General > Login Items.")
        }
    }

    static func isInstalledApplication(_ bundleURL: URL) -> Bool {
        guard bundleURL.pathExtension == "app" else { return false }
        let roots = [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true)
        ]
        let path = bundleURL.resolvingSymlinksInPath().standardizedFileURL.path
        return roots.contains { root in
            path.hasPrefix(root.resolvingSymlinksInPath().standardizedFileURL.path + "/")
        }
    }
}
