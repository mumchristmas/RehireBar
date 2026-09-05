import AppKit

@MainActor
struct StatusTrayButtonFactory {
    let iconResolver: @MainActor () -> NSImage?

    init(iconResolver: @escaping @MainActor () -> NSImage? = { StatusSymbol.makeImage() }) {
        self.iconResolver = iconResolver
    }

    func makeIcon() -> NSImage {
        let image = iconResolver() ?? StatusSymbol.makeImage()
        image.size = NSSize(width: 20, height: 20)
        return image
    }

    func make(target: AnyObject, action: Selector) -> NSButton {
        let image = makeIcon()
        let button = NSButton(image: image, target: target, action: action)
        button.title = ""
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleProportionallyDown
        button.bezelStyle = .rounded
        button.toolTip = "Show RehireBar"
        return button
    }

}

/// The app icon's capsule and three indicators reduced to a solid silhouette.
/// Transparent cutouts survive light/dark menus and the native Control Strip;
/// macOS supplies the foreground color through NSImage's template rendering.
@MainActor
enum StatusSymbol {
    static func makeImage() -> NSImage {
        let image = NSImage(size: NSSize(width: 20, height: 20), flipped: false) { _ in
            NSColor.black.set()
            let silhouette = NSBezierPath(
                roundedRect: NSRect(x: 0.5, y: 5.5, width: 19, height: 9),
                xRadius: 4.5, yRadius: 4.5
            )
            silhouette.windingRule = .evenOdd
            silhouette.appendOval(in: NSRect(x: 3.5, y: 8.25, width: 3.5, height: 3.5))
            silhouette.append(NSBezierPath(
                roundedRect: NSRect(x: 8.25, y: 8.25, width: 3.5, height: 3.5),
                xRadius: 0.75, yRadius: 0.75
            ))
            silhouette.append(NSBezierPath(
                roundedRect: NSRect(x: 13, y: 8.75, width: 4, height: 2.5),
                xRadius: 1.25, yRadius: 1.25
            ))
            silhouette.fill()
            return true
        }
        image.isTemplate = true
        return image
    }
}

@MainActor
final class RetainedTouchBarRestoreAction: NSObject {
    weak var touchBar: NSTouchBar?
    private let handler: @MainActor (NSTouchBar) -> Void

    init(handler: @escaping @MainActor (NSTouchBar) -> Void) {
        self.handler = handler
    }

    @objc func restore() {
        guard let touchBar else { return }
        handler(touchBar)
    }
}
