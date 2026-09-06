import CoreGraphics
import Darwin
import Foundation

struct TouchBarGeometry: Equatable {
    static let compactBaseline = TouchBarGeometry(
        screenWidth: 1_004,
        compactControlStripItemCount: 2,
        controlStripVisible: true
    )

    let screenWidth: CGFloat
    let compactControlStripItemCount: Int
    let controlStripVisible: Bool
}

protocol TouchBarGeometryReading {
    func read() -> TouchBarGeometry
}

final class SystemTouchBarGeometryReader: TouchBarGeometryReading {
    /// Unlike the layout fallback, this only reports a physical device returned
    /// by the system. A missing private API also results in "not detected".
    static var hardwareDetected: Bool { physicalScreenSize() != nil }

    private static let frameworkPath =
        "/System/Library/PrivateFrameworks/DFRFoundation.framework/DFRFoundation"
    private let screenSizeProvider: () -> CGSize?
    private var lastValidScreenWidth: CGFloat?

    init(screenSizeProvider: @escaping () -> CGSize? = SystemTouchBarGeometryReader.physicalScreenSize) {
        self.screenSizeProvider = screenSizeProvider
    }

    func read() -> TouchBarGeometry {
        let controlStripDefaults = UserDefaults(suiteName: "com.apple.controlstrip")
        let compactItems = controlStripDefaults?.stringArray(forKey: "MiniCustomized")?.count
            ?? TouchBarGeometry.compactBaseline.compactControlStripItemCount
        let presentationMode = UserDefaults(suiteName: "com.apple.touchbar.agent")?
            .string(forKey: "PresentationModeGlobal")
        if let width = screenSizeProvider()?.width,
           width >= 500, width <= 1_500
        {
            lastValidScreenWidth = width
        }
        return TouchBarGeometry(
            screenWidth: lastValidScreenWidth
                ?? TouchBarGeometry.compactBaseline.screenWidth,
            compactControlStripItemCount: max(0, compactItems),
            controlStripVisible: presentationMode != "app"
        )
    }

    private static func physicalScreenSize() -> CGSize? {
        guard let handle = dlopen(Self.frameworkPath, RTLD_LAZY | RTLD_LOCAL) else { return nil }
        defer { dlclose(handle) }
        guard let getMainSymbol = dlsym(handle, "DFRTouchBarGetMain"),
              let getSizeSymbol = dlsym(handle, "DFRTouchBarGetScreenSize") else { return nil }

        typealias GetMain = @convention(c) () -> UnsafeRawPointer?
        typealias GetScreenSize = @convention(c) (UnsafeRawPointer?) -> CGSize
        let getMain = unsafeBitCast(getMainSymbol, to: GetMain.self)
        let getScreenSize = unsafeBitCast(getSizeSymbol, to: GetScreenSize.self)
        guard let touchBar = getMain() else { return nil }
        let size = getScreenSize(touchBar)
        guard size.width >= 500, size.width <= 1_500,
              size.height >= 20, size.height <= 100 else { return nil }
        return size
    }
}
