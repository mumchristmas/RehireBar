import AgentStatusCore
import AppKit
import QuartzCore

struct SystemModalPresentationPlan: Equatable {
    let selectorName: String
    let usesPlacement: Bool
    let systemTrayIdentifier: NSTouchBarItem.Identifier?

    static let controlStripPreserving = SystemModalPresentationPlan(
        selectorName: "presentSystemModalTouchBar:systemTrayItemIdentifier:",
        usesPlacement: false,
        systemTrayIdentifier: NSTouchBarItem.Identifier("com.bigbom.RehireBar.controlStrip")
    )
}

enum TouchBarLayout {
    static let primaryIdentifier = NSTouchBarItem.Identifier("com.codex.touchbar.primary")
    static let secondaryIdentifier = NSTouchBarItem.Identifier("com.codex.touchbar.secondary")
    static let sessionIdentifier = NSTouchBarItem.Identifier("com.codex.touchbar.sessions-v2")
    static let rateWidth: CGFloat = 145
    static let sessionMinimumWidth: CGFloat = 188
    // A scrubber slot includes 8pt of horizontal card chrome, leaving a
    // 180pt readable content surface at the narrowest supported viewport.
    static let sessionCardMinimumWidth: CGFloat = 180
    static let maximumVisibleSessionCards = 4
    // Baseline measured on a 1004pt Touch Bar with two compact Control Strip
    // controls and only the 7D quota. It consumes the previously unused center
    // span so three readable task cards remain visible at once.
    static let sessionPreferredWidth: CGFloat = 607
    static let compactControlStripItemWidth: CGFloat = 44
    static let compactControlStripBaselineWidth: CGFloat = 160
    static let sessionPreferredPriority = NSLayoutConstraint.Priority(600)
    static let mainItemIdentifiers = metricItemIdentifiers(primaryAvailable: true)

    static func metricItemIdentifiers(primaryAvailable: Bool) -> [NSTouchBarItem.Identifier] {
        var identifiers: [NSTouchBarItem.Identifier] = []
        if primaryAvailable { identifiers.append(primaryIdentifier) }
        identifiers.append(secondaryIdentifier)
        // Session cards own their model/effort information. The scrubber receives
        // the largest safe width and yields lower-value quota items when necessary.
        identifiers.append(sessionIdentifier)
        identifiers.append(.otherItemsProxy)
        return identifiers
    }

    static func sessionWidth(
        primaryAvailable: Bool,
        geometry: TouchBarGeometry = .compactBaseline
    ) -> CGFloat {
        let physicalWidthDelta = geometry.screenWidth
            - TouchBarGeometry.compactBaseline.screenWidth
        let compactItemDelta = CGFloat(
            geometry.compactControlStripItemCount
                - TouchBarGeometry.compactBaseline.compactControlStripItemCount
        ) * compactControlStripItemWidth
        let hiddenControlStripGain = geometry.controlStripVisible
            ? 0
            : compactControlStripBaselineWidth + compactItemDelta
        let primaryQuotaCost = primaryAvailable ? rateWidth : 0
        let proposed = sessionPreferredWidth
            + physicalWidthDelta
            - compactItemDelta
            + hiddenControlStripGain
            - primaryQuotaCost
        return max(sessionMinimumWidth, proposed)
    }

    static func visibleSessionCardCount(sessionWidth: CGFloat, sessionCount: Int) -> Int {
        guard sessionCount > 0 else { return 1 }
        let capacity = max(1, Int(floor(sessionWidth / sessionMinimumWidth)))
        return min(sessionCount, maximumVisibleSessionCards, capacity)
    }
}

enum ApprovalTouchBarStyle {
    static let questionFontSize: CGFloat = 14
    static let actionFontSize: CGFloat = 13
    static let actionMinimumWidth: CGFloat = 96
}

enum TouchBarItemColor: Equatable {
    case green
    case yellow
    case red
    case neutral

    var systemColor: NSColor {
        switch self {
        case .green: .systemGreen
        case .yellow: .systemYellow
        case .red: .systemRed
        case .neutral: .secondaryLabelColor
        }
    }
}

struct RateMetricViewModel: Equatable {
    let label: String
    let resetText: String
    let percentText: String
    let progress: Double
    let color: TouchBarItemColor
    let isStale: Bool
}

struct SessionCardViewModel: Equatable {
    let id: String
    let threadID: String?
    let openURL: URL?
    let taskText: String
    let modelID: String?
    let effort: String?
    var modelEffortText: String?
    let isFastMode: Bool
    let elapsedText: String?
    let contextPercent: Int?
    let contextProgress: Double?
    let isCompactingContext: Bool
    let state: SessionExecutionState
    let stateText: String
    let remoteText: String?
}

struct TouchBarStatusViewModel {
    let primary: RateMetricViewModel
    let secondary: RateMetricViewModel
    let sessions: [SessionCardViewModel]

    init(
        status: TouchBarStatusSnapshot,
        locale: Locale = .autoupdatingCurrent,
        timeZone: TimeZone = .autoupdatingCurrent,
        now: Date = .now,
        modelDisplay: ModelDisplayConfiguration = ModelDisplayConfigurationLoader.bundledConfiguration
    ) {
        primary = Self.rateMetric(
            window: status.usage.flatMap { $0.primaryAvailable ? $0.primary : nil },
            label: "5H",
            includesWeekday: false,
            isStale: status.usage?.isStale == true,
            availabilityKnown: status.usage != nil,
            locale: locale,
            timeZone: timeZone
        )
        secondary = Self.rateMetric(
            window: status.usage.flatMap { $0.secondaryAvailable ? $0.secondary : nil },
            label: "7D",
            includesWeekday: true,
            isStale: status.usage?.isStale == true,
            availabilityKnown: status.usage != nil,
            locale: locale,
            timeZone: timeZone
        )
        let formatter = ModelDisplayFormatter(configuration: modelDisplay)
        sessions = (status.sessions.isEmpty ? [Self.placeholderSession] : status.sessions)
            .map { Self.sessionCard($0, now: now, formatter: formatter) }
    }

    static func contextPercent(used: Int, window: Int) -> Int? {
        guard window > 0, used >= 0 else { return nil }
        return Int((Double(min(used, window)) / Double(window) * 100).rounded())
    }

    private static func sessionCard(
        _ session: CurrentSessionSnapshot,
        now: Date,
        formatter: ModelDisplayFormatter
    ) -> SessionCardViewModel {
        let title = session.title?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        let projectName = session.projectName?
            .trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        // Local and remote cards share one information hierarchy. A task title is
        // always the primary identity; the project is only a fallback when the
        // title is unavailable. Remote origin is conveyed separately by the tag.
        let taskText = title ?? projectName ?? "Task"
        let percent = contextPercent(used: session.usedTokens, window: session.contextWindow)
        let stateText: String
        if session.isCompactingContext {
            stateText = "COMPACT"
        } else {
            stateText = switch session.executionState {
            case .working: "RUN"
            case .syncing: "SYNC"
            case .waiting: "WAIT"
            case .error: "ERR"
            case .idle: "IDLE"
            case .unknown: "—"
            }
        }
        return SessionCardViewModel(
            id: session.identity.map {
                "\($0.providerID)|\($0.hostID)|\($0.threadID)"
            } ?? session.sessionID,
            threadID: session.threadID,
            openURL: session.openURL ?? (
                session.providerID == "codex"
                    ? session.threadID.flatMap(CodexTaskDeepLink.url(threadID:))
                    : nil
            ),
            taskText: taskText,
            modelID: session.model,
            effort: session.effort,
            modelEffortText: formatter.modelAndEffort(
                model: session.model, effort: session.effort, providerID: session.providerID
            ),
            isFastMode: session.isFastMode,
            elapsedText: elapsedText(for: session, now: now),
            contextPercent: percent,
            contextProgress: percent.map { Double($0) / 100 },
            isCompactingContext: session.isCompactingContext,
            state: session.executionState,
            stateText: stateText,
            remoteText: session.isRemote ? "REMOTE" : nil
        )
    }

    private static func elapsedText(
        for session: CurrentSessionSnapshot,
        now: Date
    ) -> String? {
        guard session.executionState == .working,
              let activeSince = session.activeSince else { return nil }
        let seconds = max(0, Int(now.timeIntervalSince(activeSince)))
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3_600 { return "\(seconds / 60)m\(seconds % 60)s" }
        return "\(seconds / 3_600)h\((seconds % 3_600) / 60)m"
    }

    private static var placeholderSession: CurrentSessionSnapshot {
        .init(
            sessionID: "placeholder",
            usedTokens: 0,
            contextWindow: 0,
            model: nil,
            effort: nil,
            observedAt: .distantPast
        )
    }

    private static func rateMetric(
        window: RateWindow?,
        label: String,
        includesWeekday: Bool,
        isStale: Bool,
        availabilityKnown: Bool,
        locale: Locale,
        timeZone: TimeZone
    ) -> RateMetricViewModel {
        guard let window else {
            return RateMetricViewModel(
                label: label,
                resetText: availabilityKnown ? "not included" : "reset --",
                percentText: availabilityKnown ? "N/A" : "--",
                progress: 0,
                color: availabilityKnown ? .neutral : .red,
                isStale: false
            )
        }
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.setLocalizedDateFormatFromTemplate(includesWeekday ? "EEE HH:mm" : "HH:mm")
        let reset = formatter.string(from: window.resetsAt)
        let remaining = window.remainingPercent
        return RateMetricViewModel(
            label: label,
            resetText: includesWeekday ? reset : "reset \(reset)",
            percentText: "\(remaining)%",
            progress: Double(remaining) / 100,
            color: color(for: remaining),
            isStale: isStale
        )
    }

    private static func color(for remaining: Int) -> TouchBarItemColor {
        if remaining > 50 { return .green }
        if remaining >= 20 { return .yellow }
        return .red
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

@MainActor
protocol TouchBarBridging: AnyObject {
    var onRestore: (@MainActor @Sendable () -> Void)? { get set }
    func preparePersistentAccess(_ touchBar: NSTouchBar) -> Bool
    func activatePersistentAccess(_ touchBar: NSTouchBar) -> Bool
    func present(_ touchBar: NSTouchBar) -> Bool
    func resetAndRepresent(_ touchBar: NSTouchBar) -> Bool
    func dismissOwnTouchBar()
}

extension TouchBarBridging {
    func resetAndRepresent(_ touchBar: NSTouchBar) -> Bool { false }

    /// Call only during an explicit user action. Never defer recovery: system
    /// dismissal has no reliable callback, and the user may already have closed it.
    func presentOnUserRequest(_ touchBar: NSTouchBar) -> Bool {
        activatePersistentAccess(touchBar) || resetAndRepresent(touchBar)
    }
}

@MainActor
final class TouchBarPresenter: NSObject, UsagePresenting, ManualRefreshBinding,
    PresentationRestoreBinding, NSTouchBarDelegate {
    private static let primaryIdentifier = TouchBarLayout.primaryIdentifier
    private static let secondaryIdentifier = TouchBarLayout.secondaryIdentifier
    private static let sessionIdentifier = TouchBarLayout.sessionIdentifier
    private static let approvalQuestion = NSTouchBarItem.Identifier("approval.question")
    private static let approvalApprove = NSTouchBarItem.Identifier("approval.approve")
    private static let approvalReject = NSTouchBarItem.Identifier("approval.reject")
    private static let approvalChanges = NSTouchBarItem.Identifier("approval.changes")

    private let touchBar = NSTouchBar()
    private let bridge: any TouchBarBridging
    private let taskOpener: any TaskOpening
    private let logger: (String) -> Void
    private let geometryReader: any TouchBarGeometryReading
    private let showsPrimaryQuota: Bool
    private let modelDisplayConfiguration: @MainActor () -> ModelDisplayConfiguration
    private var didLogPresentationUnavailable = false
    private var statusModel = TouchBarStatusViewModel(status: .init(usage: nil, session: nil))
    private var renderedStatus = TouchBarStatusSnapshot(usage: nil, session: nil)
    private var activeSessionID: String?
    private var rateViews: [NSTouchBarItem.Identifier: RateMetricView] = [:]
    private var sessionScrubber: SessionScrubberView?
    private var textWidthConstraints: [NSTouchBarItem.Identifier: NSLayoutConstraint] = [:]
    private var approval: ConversationApproval?
    private var approvalAction: ((ConversationApprovalAction) -> Void)?
    private var approvalButtons: [NSButton] = []

    var onManualRefresh: (@MainActor @Sendable () -> Void)?
    var onExplicitRestore: (@MainActor @Sendable () -> Void)?

    var displayedItemIdentifiers: [NSTouchBarItem.Identifier] {
        touchBar.defaultItemIdentifiers
    }

    func showApproval(
        _ approval: ConversationApproval,
        action: @escaping (ConversationApprovalAction) -> Void
    ) {
        self.approval = approval
        approvalAction = action
        touchBar.defaultItemIdentifiers = [
            Self.approvalQuestion, Self.approvalApprove, Self.approvalReject,
            Self.approvalChanges, .otherItemsProxy,
        ]
    }

    func setApprovalSending(_ sending: Bool, result: String? = nil) {
        approvalButtons.forEach { $0.isEnabled = !sending }
        if let result { approvalButtons.first?.title = result }
    }

    func restoreMetrics() {
        approval = nil
        approvalAction = nil
        approvalButtons.removeAll()
        updateMetricComposition()
    }

    override convenience init() {
        self.init(
            bridge: SystemModalTouchBarBridge(),
            taskOpener: WorkspaceTaskOpener(),
            geometryReader: SystemTouchBarGeometryReader(),
            showsPrimaryQuota: !UserDefaults.standard.bool(forKey: "hideFiveHourQuota"),
            logger: { NSLog("%@", $0) }
        )
    }

    init(
        bridge: any TouchBarBridging,
        taskOpener: any TaskOpening = UnavailableTaskOpener(),
        geometryReader: any TouchBarGeometryReading = SystemTouchBarGeometryReader(),
        showsPrimaryQuota: Bool = true,
        modelDisplayConfiguration: @escaping @MainActor () -> ModelDisplayConfiguration = {
            ModelDisplayConfigurationLoader().load()
        },
        logger: @escaping (String) -> Void
    ) {
        self.bridge = bridge
        self.taskOpener = taskOpener
        self.geometryReader = geometryReader
        self.showsPrimaryQuota = showsPrimaryQuota
        self.modelDisplayConfiguration = modelDisplayConfiguration
        self.logger = logger
        super.init()
        bridge.onRestore = { [weak self] in self?.handleControlStripRestore() }
        touchBar.delegate = self
        touchBar.defaultItemIdentifiers = TouchBarLayout.mainItemIdentifiers
    }

    func preparePersistentAccess() {
        recordPresentation(
            bridge.preparePersistentAccess(touchBar),
            failureMessage: "Control Strip access is unavailable on this Mac or macOS version."
        )
    }

    func show(_ snapshot: UsageSnapshot) {
        showStatus(.init(usage: snapshot, session: nil))
    }

    func showStatus(_ status: TouchBarStatusSnapshot) {
        let previousLeadID = statusModel.sessions.first?.id
        renderedStatus = status
        statusModel = TouchBarStatusViewModel(status: status, modelDisplay: modelDisplayConfiguration())
        let availableSessionIDs = Set(statusModel.sessions.map(\.id))
        // The collection already carries monitoring priority. Foreground focus
        // must not scroll an idle card over tasks that are still running.
        if previousLeadID != statusModel.sessions.first?.id
            || activeSessionID == nil || !availableSessionIDs.contains(activeSessionID!) {
            activeSessionID = statusModel.sessions.first?.id
        }
        updateMetricComposition()
        refreshViews()
    }

    func showUnavailable() {
        renderedStatus = .init(usage: nil, session: nil)
        statusModel = TouchBarStatusViewModel(status: renderedStatus, modelDisplay: modelDisplayConfiguration())
        activeSessionID = nil
        updateMetricComposition()
        refreshViews()
    }

    func markRenderedStatusStale() {
        renderedStatus = renderedStatus.markingUsageStale()
        statusModel = TouchBarStatusViewModel(status: renderedStatus, modelDisplay: modelDisplayConfiguration())
        refreshViews()
    }

    func represent() -> Bool {
        recordPresentation(
            bridge.presentOnUserRequest(touchBar),
            failureMessage: "RehireBar restoration is unavailable on this Mac or macOS version."
        )
    }

    func hide() {
        bridge.dismissOwnTouchBar()
    }

    @discardableResult
    private func recordPresentation(_ succeeded: Bool, failureMessage: String) -> Bool {
        if succeeded {
            didLogPresentationUnavailable = false
        } else if !didLogPresentationUnavailable {
            didLogPresentationUnavailable = true
            logger(failureMessage)
        }
        return succeeded
    }

    func touchBar(
        _ touchBar: NSTouchBar,
        makeItemForIdentifier identifier: NSTouchBarItem.Identifier
    ) -> NSTouchBarItem? {
        if identifier == .otherItemsProxy { return nil }
        let item = NSCustomTouchBarItem(identifier: identifier)
        if identifier == Self.approvalQuestion {
            let label = NSTextField(labelWithString: approval?.question ?? "Codex ขออนุมัติ")
            label.lineBreakMode = .byTruncatingTail
            label.font = .systemFont(
                ofSize: ApprovalTouchBarStyle.questionFontSize,
                weight: .semibold
            )
            label.widthAnchor.constraint(equalToConstant: 250).isActive = true
            item.view = label
            return item
        }
        if let action = approvalAction(for: identifier) {
            let title: String = switch action {
            case .approve: "✓ อนุมัติ"
            case .reject: "✕ ไม่อนุมัติ"
            case .requestChanges: "✎ ขอแก้ไข"
            }
            let button = makePickerButton(title: title)
            button.font = .systemFont(
                ofSize: ApprovalTouchBarStyle.actionFontSize,
                weight: .bold
            )
            button.widthAnchor.constraint(
                greaterThanOrEqualToConstant: ApprovalTouchBarStyle.actionMinimumWidth
            ).isActive = true
            button.identifier = NSUserInterfaceItemIdentifier(action.rawValue)
            button.target = self
            button.action = #selector(handleApprovalAction(_:))
            approvalButtons.append(button)
            item.view = button
            return item
        }
        if identifier == Self.primaryIdentifier || identifier == Self.secondaryIdentifier {
            let view = RateMetricView()
            view.onTap = { [weak self] in self?.onManualRefresh?() }
            view.translatesAutoresizingMaskIntoConstraints = false
            view.widthAnchor.constraint(equalToConstant: TouchBarLayout.rateWidth).isActive = true
            rateViews[identifier] = view
            item.visibilityPriority = identifier == Self.secondaryIdentifier ? .high : .low
            item.view = view
            view.apply(identifier == Self.primaryIdentifier ? statusModel.primary : statusModel.secondary)
            return item
        }
        if identifier == Self.sessionIdentifier {
            let view = SessionScrubberView()
            view.onTaskTap = { [weak self] session in
                self?.openTask(session)
            }
            view.translatesAutoresizingMaskIntoConstraints = false
            let resolvedWidth = resolvedSessionWidth()
            let width = view.widthAnchor.constraint(equalToConstant: resolvedWidth)
            width.priority = TouchBarLayout.sessionPreferredPriority
            view.widthAnchor.constraint(
                greaterThanOrEqualToConstant: TouchBarLayout.sessionMinimumWidth
            ).isActive = true
            width.isActive = true
            textWidthConstraints[identifier] = width
            sessionScrubber = view
            item.visibilityPriority = .high
            item.view = view
            view.setViewportWidth(resolvedWidth)
            view.apply(displayedSessions, focusedSessionID: activeSessionID)
            return item
        }
        return nil
    }

    private func approvalAction(for identifier: NSTouchBarItem.Identifier) -> ConversationApprovalAction? {
        switch identifier {
        case Self.approvalApprove: .approve
        case Self.approvalReject: .reject
        case Self.approvalChanges: .requestChanges
        default: nil
        }
    }

    @objc private func handleApprovalAction(_ sender: NSButton) {
        guard let raw = sender.identifier?.rawValue,
              let action = ConversationApprovalAction(rawValue: raw) else { return }
        approvalAction?(action)
    }

    private func makePickerButton(title: String) -> NSButton {
        let button = NSButton(title: title, target: nil, action: nil)
        button.font = .monospacedSystemFont(ofSize: 10, weight: .semibold)
        button.bezelStyle = .rounded
        return button
    }

    private func refreshViews() {
        rateViews[Self.primaryIdentifier]?.apply(statusModel.primary)
        rateViews[Self.secondaryIdentifier]?.apply(statusModel.secondary)
        sessionScrubber?.apply(displayedSessions, focusedSessionID: activeSessionID)
    }

    private var isPrimaryAvailable: Bool {
        showsPrimaryQuota && renderedStatus.usage?.primaryAvailable != false
    }

    private var displayedSessions: [SessionCardViewModel] {
        statusModel.sessions
    }

    private func updateMetricComposition() {
        guard approval == nil else { return }
        let width = resolvedSessionWidth()
        let identifiers = TouchBarLayout.metricItemIdentifiers(
            primaryAvailable: isPrimaryAvailable
        )
        // Reassigning an unchanged identifier list invalidates item views while this
        // private system-modal Touch Bar is presented. A normal 30-second data refresh
        // must update the existing views without rebuilding the composition.
        if touchBar.defaultItemIdentifiers != identifiers {
            touchBar.defaultItemIdentifiers = identifiers
        }
        updateWidthConstraint(
            for: Self.sessionIdentifier,
            constant: width
        )
    }

    private func resolvedSessionWidth() -> CGFloat {
        TouchBarLayout.sessionWidth(
            primaryAvailable: isPrimaryAvailable,
            geometry: geometryReader.read()
        )
    }

    private func handleControlStripRestore() {
        // `NSTouchBarItem.isVisible` is not reliable for a private system-modal bar:
        // on hardware it can remain false while the item is visibly rendered. Keep
        // the geometry-derived composition authoritative across collapse/restore.
        updateMetricComposition()
        refreshViews()
        onExplicitRestore?()
    }

    private func updateWidthConstraint(
        for identifier: NSTouchBarItem.Identifier,
        constant: CGFloat
    ) {
        if identifier == Self.sessionIdentifier {
            sessionScrubber?.setViewportWidth(constant)
        }
        guard let constraint = textWidthConstraints[identifier],
              constraint.constant != constant else { return }
        constraint.constant = constant
    }

    private func openTask(_ session: SessionCardViewModel) {
        guard let openURL = session.openURL else { return }
        guard taskOpener.open(openURL) else {
            logger(
                "Could not open task "
                    + SanitizedDiagnostic.identifier(session.threadID ?? session.id) + "."
            )
            return
        }
        activeSessionID = session.id
        sessionScrubber?.apply(displayedSessions, focusedSessionID: session.id)
    }

}

@MainActor
private final class RateMetricView: NSStackView {
    private let nameLabel = NSTextField(labelWithString: "")
    private let resetLabel = NSTextField(labelWithString: "")
    private let percentLabel = NSTextField(labelWithString: "")
    private let staleLabel = NSTextField(labelWithString: "•")
    private let progress = ProgressTrackView()
    var onTap: (@MainActor @Sendable () -> Void)?

    init() {
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        orientation = .vertical
        spacing = 3
        alignment = .leading
        let header = NSStackView(views: [nameLabel, resetLabel, percentLabel, staleLabel])
        header.orientation = .horizontal
        header.spacing = 5
        header.distribution = .fill
        resetLabel.textColor = .secondaryLabelColor
        resetLabel.font = .systemFont(ofSize: 9, weight: .regular)
        nameLabel.font = .systemFont(ofSize: 10, weight: .semibold)
        percentLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .bold)
        staleLabel.font = .monospacedSystemFont(ofSize: 11, weight: .bold)
        staleLabel.textColor = .systemYellow
        staleLabel.isHidden = true
        resetLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addArrangedSubview(header)
        addArrangedSubview(progress)
        header.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
        progress.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
        progress.heightAnchor.constraint(equalToConstant: 5).isActive = true
        addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(handleTap)))
    }

    required init?(coder: NSCoder) { nil }

    @objc private func handleTap() {
        onTap?()
    }

    override func accessibilityPerformPress() -> Bool {
        guard let onTap else { return false }
        onTap()
        return true
    }

    func apply(_ model: RateMetricViewModel) {
        setAccessibilityLabel(
            "Refresh \(model.label) quota" + (model.isStale ? ", data delayed" : "")
        )
        nameLabel.stringValue = model.label
        resetLabel.stringValue = model.resetText
        percentLabel.stringValue = model.percentText
        percentLabel.textColor = model.color.systemColor
        staleLabel.isHidden = !model.isStale
        progress.fraction = model.progress
        progress.fillColor = model.color.systemColor
    }
}

@MainActor
private final class ProgressTrackView: NSView {
    var fraction: Double = 0 { didSet { needsDisplay = true } }
    var fillColor: NSColor = .systemGreen { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds, xRadius: 2.5, yRadius: 2.5)
        NSColor.quaternaryLabelColor.setFill()
        path.fill()
        let width = bounds.width * min(1, max(0, fraction))
        guard width > 0 else { return }
        fillColor.setFill()
        NSBezierPath(
            roundedRect: NSRect(x: 0, y: 0, width: width, height: bounds.height),
            xRadius: 2.5,
            yRadius: 2.5
        ).fill()
    }
}

@MainActor
private final class SessionScrubberView: NSScrubber, NSScrubberDataSource, NSScrubberDelegate {
    private static let cardIdentifier = NSUserInterfaceItemIdentifier("codex.session-card")
    private var models: [SessionCardViewModel] = []
    private var orderedIDs: [String] = []
    private var focusedSessionID: String?
    private var viewportWidth = TouchBarLayout.sessionMinimumWidth
    private var visibleCardCount = 1
    var onTaskTap: ((SessionCardViewModel) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        dataSource = self
        delegate = self
        scrubberLayout = NSScrubberProportionalLayout(numberOfVisibleItems: 1)
        mode = .free
        itemAlignment = .leading
        isContinuous = false
        showsArrowButtons = false
        showsAdditionalContentIndicators = true
        register(SessionScrubberItemView.self, forItemIdentifier: Self.cardIdentifier)
        heightAnchor.constraint(equalToConstant: 30).isActive = true
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Codex tasks, swipe horizontally and tap a card to open it")
    }

    required init(coder: NSCoder) {
        fatalError("SessionScrubberView does not support NSCoding")
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: 30)
    }

    func apply(_ models: [SessionCardViewModel], focusedSessionID: String?) {
        let ids = models.map(\.id)
        self.models = models
        let identityChanged = ids != orderedIDs
        let layoutChanged = updateVisibleCardCount()
        if identityChanged || layoutChanged {
            orderedIDs = ids
            reloadData()
        } else {
            for index in models.indices {
                (itemViewForItem(at: index) as? SessionScrubberItemView)?.apply(models[index])
            }
        }

        let focusChanged = self.focusedSessionID != focusedSessionID
        guard focusChanged || identityChanged || layoutChanged else { return }
        self.focusedSessionID = focusedSessionID
        guard let index = models.firstIndex(where: { $0.id == focusedSessionID }) else {
            selectedIndex = -1
            return
        }
        selectedIndex = index
        scrollItem(at: index, to: .leading)
    }

    func setViewportWidth(_ width: CGFloat) {
        viewportWidth = max(TouchBarLayout.sessionMinimumWidth, width)
        guard updateVisibleCardCount() else { return }
        reloadData()
        refocusCurrentThread()
    }

    private func updateVisibleCardCount() -> Bool {
        let count = TouchBarLayout.visibleSessionCardCount(
            sessionWidth: viewportWidth,
            sessionCount: models.count
        )
        guard count != visibleCardCount else { return false }
        visibleCardCount = count
        scrubberLayout = NSScrubberProportionalLayout(numberOfVisibleItems: count)
        return true
    }

    private func refocusCurrentThread() {
        guard let index = models.firstIndex(where: { $0.id == focusedSessionID }) else {
            selectedIndex = -1
            return
        }
        selectedIndex = index
        scrollItem(at: index, to: .leading)
    }

    func numberOfItems(for scrubber: NSScrubber) -> Int { models.count }

    func scrubber(_ scrubber: NSScrubber, viewForItemAt index: Int) -> NSScrubberItemView {
        guard let item = makeItem(
            withIdentifier: Self.cardIdentifier,
            owner: nil
        ) as? SessionScrubberItemView else {
            return SessionScrubberItemView(frame: .zero)
        }
        item.apply(models[index])
        item.onTaskTap = onTaskTap
        return item
    }

    func scrubber(_ scrubber: NSScrubber, didSelectItemAt selectedIndex: Int) {
        guard models.indices.contains(selectedIndex) else { return }
        let model = models[selectedIndex]
        guard model.openURL != nil else { return }
        onTaskTap?(model)
    }
}

@MainActor
private final class SessionScrubberItemView: NSScrubberItemView {
    private let card = SessionCardView()

    var onTaskTap: ((SessionCardViewModel) -> Void)? {
        didSet { card.onTaskTap = onTaskTap }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        card.translatesAutoresizingMaskIntoConstraints = false
        addSubview(card)
        NSLayoutConstraint.activate([
            card.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            card.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            card.topAnchor.constraint(equalTo: topAnchor),
            card.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { nil }

    func apply(_ model: SessionCardViewModel) {
        card.apply(model)
    }
}

@MainActor
private final class SessionCardView: NSView {
    private let dot = StatusDotView()
    private let stateLabel = NSTextField(labelWithString: "")
    private let taskLabel = NSTextField(labelWithString: "")
    private let remoteLabel = NSTextField(labelWithString: "")
    private let elapsedLabel = NSTextField(labelWithString: "")
    private let fastModeIcon = NSImageView()
    private let modelLabel = NSTextField(labelWithString: "")
    private let contextLabel = NSTextField(labelWithString: "")
    private let contextProgress = ProgressTrackView()
    private let details = NSStackView()
    private let separator = NSBox()
    private var representedModel: SessionCardViewModel?
    var onTaskTap: ((SessionCardViewModel) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(
            greaterThanOrEqualToConstant: TouchBarLayout.sessionCardMinimumWidth
        ).isActive = true
        heightAnchor.constraint(equalToConstant: 30).isActive = true

        stateLabel.font = .monospacedSystemFont(ofSize: 8, weight: .bold)
        stateLabel.identifier = NSUserInterfaceItemIdentifier("codex.task-state")
        taskLabel.font = .systemFont(ofSize: 9, weight: .semibold)
        taskLabel.lineBreakMode = .byTruncatingTail
        taskLabel.identifier = NSUserInterfaceItemIdentifier("codex.task-name")
        remoteLabel.font = .monospacedSystemFont(ofSize: 7, weight: .bold)
        remoteLabel.textColor = .systemCyan
        remoteLabel.alignment = .right
        remoteLabel.identifier = NSUserInterfaceItemIdentifier("codex.remote-tag")
        elapsedLabel.font = .monospacedDigitSystemFont(ofSize: 8, weight: .medium)
        elapsedLabel.textColor = .secondaryLabelColor
        elapsedLabel.identifier = NSUserInterfaceItemIdentifier("codex.task-elapsed")
        fastModeIcon.image = NSImage(
            systemSymbolName: "bolt.fill",
            accessibilityDescription: "Fast mode"
        )?.withSymbolConfiguration(.init(pointSize: 7, weight: .semibold))
        fastModeIcon.contentTintColor = .systemYellow
        fastModeIcon.imageScaling = .scaleProportionallyDown
        fastModeIcon.identifier = NSUserInterfaceItemIdentifier("codex.fast-mode-indicator")
        fastModeIcon.translatesAutoresizingMaskIntoConstraints = false
        fastModeIcon.widthAnchor.constraint(equalToConstant: 7).isActive = true
        fastModeIcon.heightAnchor.constraint(equalToConstant: 9).isActive = true
        fastModeIcon.setContentHuggingPriority(.required, for: .horizontal)
        fastModeIcon.setContentCompressionResistancePriority(.required, for: .horizontal)
        modelLabel.font = .monospacedSystemFont(ofSize: 8, weight: .semibold)
        modelLabel.textColor = .systemCyan
        modelLabel.lineBreakMode = .byTruncatingMiddle
        modelLabel.identifier = NSUserInterfaceItemIdentifier("codex.task-model-effort")
        contextLabel.font = .monospacedDigitSystemFont(ofSize: 9, weight: .semibold)
        contextLabel.alignment = .right
        contextLabel.identifier = NSUserInterfaceItemIdentifier("codex.task-context-percent")
        contextProgress.fillColor = .systemBlue
        contextProgress.identifier = NSUserInterfaceItemIdentifier("codex.task-context-progress")

        let header = NSStackView(views: [dot, stateLabel, taskLabel, remoteLabel])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 4
        [elapsedLabel, fastModeIcon, modelLabel, contextProgress, contextLabel]
            .forEach(details.addArrangedSubview)
        details.orientation = .horizontal
        details.alignment = .centerY
        details.spacing = 5
        details.identifier = NSUserInterfaceItemIdentifier("codex.task-details")
        let content = NSStackView(views: [header, details])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 1
        content.translatesAutoresizingMaskIntoConstraints = false

        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        addSubview(separator)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: leadingAnchor),
            content.trailingAnchor.constraint(equalTo: separator.leadingAnchor, constant: -7),
            content.centerYAnchor.constraint(equalTo: centerYAnchor),
            header.widthAnchor.constraint(equalTo: content.widthAnchor),
            details.widthAnchor.constraint(equalTo: content.widthAnchor),
            contextProgress.widthAnchor.constraint(equalToConstant: 38),
            contextProgress.heightAnchor.constraint(equalToConstant: 4),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            separator.topAnchor.constraint(equalTo: topAnchor, constant: 3),
            separator.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -3),
            separator.widthAnchor.constraint(equalToConstant: 1),
        ])
        taskLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        remoteLabel.setContentHuggingPriority(.required, for: .horizontal)
        elapsedLabel.setContentHuggingPriority(.required, for: .horizontal)
        modelLabel.setContentHuggingPriority(.required, for: .horizontal)
        contextLabel.setContentHuggingPriority(.required, for: .horizontal)
        contextProgress.setContentHuggingPriority(.required, for: .horizontal)
        setAccessibilityElement(true)
    }

    required init?(coder: NSCoder) { nil }

    override func accessibilityPerformPress() -> Bool {
        guard let representedModel,
              representedModel.openURL != nil else { return false }
        onTaskTap?(representedModel)
        return true
    }

    func apply(_ model: SessionCardViewModel) {
        representedModel = model
        stateLabel.stringValue = model.stateText
        taskLabel.stringValue = model.taskText
        taskLabel.toolTip = model.taskText
        remoteLabel.stringValue = model.remoteText ?? ""
        remoteLabel.isHidden = model.remoteText == nil
        elapsedLabel.stringValue = model.elapsedText ?? ""
        elapsedLabel.isHidden = model.elapsedText == nil
        modelLabel.stringValue = model.modelEffortText ?? ""
        modelLabel.isHidden = model.modelEffortText == nil
        fastModeIcon.isHidden = !model.isFastMode || model.modelEffortText == nil
        modelLabel.setAccessibilityLabel(
            model.modelEffortText.map { "Model and effort \($0) for \(model.taskText)" }
        )
        setAccessibilityRole(model.openURL == nil ? .group : .button)
        contextLabel.stringValue = model.contextPercent.map { "\($0)%" } ?? ""
        contextLabel.isHidden = model.contextPercent == nil
        contextProgress.fraction = model.contextProgress ?? 0
        contextProgress.isHidden = model.contextProgress == nil
        details.isHidden = model.elapsedText == nil
            && model.modelEffortText == nil
            && model.contextPercent == nil
        let color = Self.color(for: model)
        dot.apply(
            state: model.state,
            color: color,
            isCompactingContext: model.isCompactingContext
        )
        stateLabel.textColor = color
        setAccessibilityLabel(
            [
                model.openURL == nil ? nil : "Open task",
                model.taskText,
                model.remoteText,
                model.stateText,
                model.elapsedText.map { "running for \($0)" },
                model.modelEffortText.map { "model and effort \($0)" },
                model.isFastMode ? "fast mode" : nil,
                model.contextPercent.map { "context \($0) percent" },
                model.isCompactingContext ? "compacting context" : nil,
            ]
                .compactMap { $0 }
                .joined(separator: ", ")
        )
    }

    private static func color(for model: SessionCardViewModel) -> NSColor {
        if model.isCompactingContext { return .systemOrange }
        return switch model.state {
        case .working: .systemGreen
        case .syncing: .systemBlue
        case .waiting: .systemYellow
        case .error: .systemRed
        case .idle: NSColor(srgbRed: 0.58, green: 0.58, blue: 0.58, alpha: 1)
        case .unknown: .tertiaryLabelColor
        }
    }
}

@MainActor
private final class StatusDotView: NSView {
    private let dotLayer = CALayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 7).isActive = true
        heightAnchor.constraint(equalToConstant: 7).isActive = true
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        identifier = NSUserInterfaceItemIdentifier("codex.status-indicator")
        wantsLayer = true
        dotLayer.bounds = CGRect(x: 0, y: 0, width: 7, height: 7)
        dotLayer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        dotLayer.position = CGPoint(x: 3.5, y: 3.5)
        dotLayer.cornerRadius = 3.5
        layer?.addSublayer(dotLayer)
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        dotLayer.position = CGPoint(x: bounds.midX, y: bounds.midY)
        CATransaction.commit()
    }

    func apply(
        state: SessionExecutionState,
        color: NSColor,
        isCompactingContext: Bool
    ) {
        isHidden = false
        dotLayer.isHidden = false
        dotLayer.removeAllAnimations()
        dotLayer.backgroundColor = color.cgColor
        dotLayer.shadowColor = color.cgColor
        dotLayer.shadowOffset = .zero
        dotLayer.shadowRadius = 0
        dotLayer.shadowOpacity = 0
        dotLayer.opacity = 1
        dotLayer.cornerRadius = isCompactingContext ? 1 : 3.5

        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        if isCompactingContext {
            let scale = CABasicAnimation(keyPath: "transform.scale")
            scale.fromValue = 0.68
            scale.toValue = 1.16
            scale.duration = 0.58
            scale.autoreverses = true
            scale.repeatCount = .infinity
            scale.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            dotLayer.add(scale, forKey: "codex-compacting")
            return
        }
        switch state {
        case .working:
            let scale = CABasicAnimation(keyPath: "transform.scale")
            scale.fromValue = 0.72
            scale.toValue = 1.18
            let opacity = CABasicAnimation(keyPath: "opacity")
            opacity.fromValue = 0.45
            opacity.toValue = 1
            let breathing = CAAnimationGroup()
            breathing.animations = [scale, opacity]
            breathing.duration = 0.9
            breathing.autoreverses = true
            breathing.repeatCount = .infinity
            breathing.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            dotLayer.add(breathing, forKey: "codex-working")
        case .syncing:
            let scale = CABasicAnimation(keyPath: "transform.scale")
            scale.fromValue = 0.68
            scale.toValue = 1.08
            let opacity = CABasicAnimation(keyPath: "opacity")
            opacity.fromValue = 0.28
            opacity.toValue = 1
            let synchronizing = CAAnimationGroup()
            synchronizing.animations = [scale, opacity]
            synchronizing.duration = 1.15
            synchronizing.autoreverses = true
            synchronizing.repeatCount = .infinity
            synchronizing.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            dotLayer.add(synchronizing, forKey: "codex-syncing")
        case .waiting:
            dotLayer.shadowRadius = 4
            dotLayer.shadowOpacity = 0.9
            let attention = CAKeyframeAnimation(keyPath: "opacity")
            attention.values = [1, 0.22, 1, 0.22, 1]
            attention.keyTimes = [0, 0.16, 0.34, 0.52, 1]
            attention.duration = 1.35
            attention.repeatCount = .infinity
            attention.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            dotLayer.add(attention, forKey: "codex-waiting")
        case .error, .idle, .unknown:
            break
        }
    }
}
