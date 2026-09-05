import AppKit

@MainActor
protocol ApplicationRelaunching: AnyObject {
    func relaunch()
}

@MainActor
final class ApplicationRelauncher: ApplicationRelaunching {
    func relaunch() {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        SingleInstanceGuard.shared.release()
        NSWorkspace.shared.openApplication(
            at: Bundle.main.bundleURL,
            configuration: configuration
        ) { _, error in
            Task { @MainActor in
                guard error == nil else {
                    _ = SingleInstanceGuard.shared.acquire()
                    NSLog("RehireBar relaunch failed: %@", String(describing: error))
                    return
                }
                NSApplication.shared.terminate(nil)
            }
        }
    }
}

@MainActor
final class NoopApplicationRelauncher: ApplicationRelaunching {
    func relaunch() {}
}
