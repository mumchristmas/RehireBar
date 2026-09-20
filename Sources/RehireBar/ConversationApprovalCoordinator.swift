import AppKit

@MainActor
final class ConversationApprovalCoordinator {
    private let store: ConversationApprovalStore
    private let presenter: TouchBarPresenter
    private let sender: ConversationApprovalResponseSender
    private let now: @MainActor () -> Date
    private let scheduler: any RefreshScheduling
    private var expiryCancellation: (any RefreshCancellation)?
    private var observer: NSObjectProtocol?
    private var current: ConversationApproval?
    private var deliveringApprovalID: String?
    private var deliveryTask: Task<Void, Never>?

    init(
        store: ConversationApprovalStore = ConversationApprovalStore(),
        presenter: TouchBarPresenter,
        sender: ConversationApprovalResponseSender = .init(),
        now: @escaping @MainActor () -> Date = { .now },
        scheduler: any RefreshScheduling = TimerRefreshScheduler()
    ) {
        self.store = store
        self.presenter = presenter
        self.sender = sender
        self.now = now
        self.scheduler = scheduler
    }

    func start() {
        guard observer == nil else { return }
        observer = DistributedNotificationCenter.default().addObserver(
            forName: ConversationApprovalStore.changedNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in Task { @MainActor in self?.reload() } }
        reload()
    }

    func stop() {
        expiryCancellation?.cancel()
        expiryCancellation = nil
        current = nil
        presenter.restoreMetrics()
        if let observer { DistributedNotificationCenter.default().removeObserver(observer) }
        observer = nil
        deliveryTask?.cancel()
        deliveryTask = nil
        deliveringApprovalID = nil
    }

    private func reload() {
        guard observer != nil else { return }
        expiryCancellation?.cancel()
        expiryCancellation = nil
        guard let approval = try? store.pending(at: now()).first else {
            current = nil
            presenter.restoreMetrics()
            return
        }
        current = approval
        expiryCancellation = scheduler.scheduleOnce(after: max(0.001, approval.expiresAt.timeIntervalSince(now()))) { [weak self] in
            self?.reload()
        }
        presenter.showApproval(approval) { [weak self, approvalID = approval.id] action in
            self?.respond(action, approvalID: approvalID)
        }
        if deliveringApprovalID != nil { presenter.setApprovalSending(true) }
    }

    private func respond(_ action: ConversationApprovalAction, approvalID: String) {
        guard let approval = current,
              approval.id == approvalID,
              deliveringApprovalID == nil else { return }
        guard (try? store.beginDelivery(approval, at: now())) == true else {
            reload()
            return
        }
        deliveringApprovalID = approvalID
        presenter.setApprovalSending(true)
        deliveryTask = Task { [weak self] in
            guard let self else { return }
            let confirmed = await sender.send(action: action, approval: approval)
            guard !Task.isCancelled else { return }
            self.deliveryTask = nil
            self.deliveringApprovalID = nil
            if confirmed {
                try? store.markDelivered(id: approval.id)
                if action == .requestChanges {
                    NSRunningApplication.runningApplications(
                        withBundleIdentifier: "com.openai.codex"
                    ).first?.activate(options: [.activateAllWindows])
                }
                self.reload()
            } else {
                try? store.setState(id: approval.id, .pending)
                self.reload()
                if self.current?.id == approval.id {
                    self.presenter.setApprovalSending(false, result: "NOT SENT")
                }
            }
        }
    }
}
