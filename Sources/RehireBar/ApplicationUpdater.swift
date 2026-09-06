import AppKit
import Foundation
import Sparkle

struct ApplicationUpdateConfiguration: Equatable, Sendable {
    let feedURL: URL
    let publicKey: Data

    init?(info: [String: Any]) {
        guard let feed = info["SUFeedURL"] as? String,
              let url = URL(string: feed), url.scheme == "https", url.host != nil,
              url.user == nil, url.password == nil,
              let key = info["SUPublicEDKey"] as? String,
              let bytes = Data(base64Encoded: key), bytes.count == 32 else { return nil }
        feedURL = url
        publicKey = bytes
    }
}

@MainActor
protocol ApplicationUpdating: AnyObject {
    var canCheckForUpdates: Bool { get }
    func start()
    func checkForUpdates()
}

/// Sparkle owns update discovery, signature validation, installation, and relaunch.
/// Defaults live in Info.plist: no background checks, unattended installs, or profiling.
@MainActor
final class SparkleApplicationUpdater: ApplicationUpdating {
    private var controller: SPUStandardUpdaterController?

    var canCheckForUpdates: Bool { controller?.updater.canCheckForUpdates == true }

    func start() {
        guard controller == nil,
              Bundle.main.bundleURL.pathExtension == "app",
              ApplicationUpdateConfiguration(info: Bundle.main.infoDictionary ?? [:]) != nil else { return }
        let controller = SPUStandardUpdaterController(
            startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil
        )
        self.controller = controller
        controller.startUpdater()
    }

    func checkForUpdates() {
        guard canCheckForUpdates else { return }
        controller?.checkForUpdates(nil)
    }
}

@MainActor
final class NoopApplicationUpdater: ApplicationUpdating {
    let canCheckForUpdates = false
    func start() {}
    func checkForUpdates() {}
}
