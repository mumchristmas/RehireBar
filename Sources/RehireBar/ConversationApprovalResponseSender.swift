import AppKit

protocol ConversationReplyUpdating: Sendable {
    func submitUserMessage(threadID: String, text: String) async throws -> Bool
}

extension CodexDesktopIPCClient: ConversationReplyUpdating {}

struct ConversationApprovalResponseSender: Sendable {
    let updater: any ConversationReplyUpdating

    init(updater: any ConversationReplyUpdating = CodexDesktopIPCClient()) {
        self.updater = updater
    }

    func send(action: ConversationApprovalAction, approval: ConversationApproval) async -> Bool {
        do { return try await updater.submitUserMessage(threadID: approval.threadID, text: action.responseText) }
        catch { return false }
    }
}
