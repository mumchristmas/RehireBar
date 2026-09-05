import AppKit

@MainActor
final class ConversationApprovalCoordinator {
    private let store: ConversationApprovalStore
    private let presenter: TouchBarPresenter
    private let sender: ConversationApprovalResponseSender
    private var observer: NSObjectProtocol?
    private var current: ConversationApproval?
    private var deliveringApprovalID: String?
    private var deliveryTask: Task<Void, Never>?

    init(
        store: ConversationApprovalStore = ConversationApprovalStore(),
        presenter: TouchBarPresenter,
        sender: ConversationApprovalResponseSender = .init()
    ) {
        self.store = store
        self.presenter = presenter
        self.sender = sender
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
        if let observer { DistributedNotificationCenter.default().removeObserver(observer) }
        observer = nil
        deliveryTask?.cancel()
        deliveryTask = nil
        deliveringApprovalID = nil
    }

    private func reload() {
        guard let approval = try? store.pending().first else {
            current = nil
            presenter.restoreMetrics()
            return
        }
        current = approval
        presenter.showApproval(approval) { [weak self, approvalID = approval.id] action in
            self?.respond(action, approvalID: approvalID)
        }
    }

    private func respond(_ action: ConversationApprovalAction, approvalID: String) {
        guard let approval = current,
              approval.id == approvalID,
              deliveringApprovalID == nil else { return }
        deliveringApprovalID = approvalID
        presenter.setApprovalSending(true)
        try? store.setState(id: approval.id, .delivering)
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
                if self.current?.id == approval.id {
                    self.presenter.setApprovalSending(false, result: "NOT SENT")
                }
            }
        }
    }
}
