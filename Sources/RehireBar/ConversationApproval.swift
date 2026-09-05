import Foundation

struct ConversationApproval: Codable, Equatable, Identifiable {
    enum DeliveryState: String, Codable { case pending, delivering, delivered }

    let id: String
    let threadID: String
    let hostID: String?
    let question: String
    let createdAt: Date
    let expiresAt: Date
    var deliveryState: DeliveryState

    init(
        id: String = UUID().uuidString.lowercased(),
        threadID: String,
        hostID: String? = nil,
        question: String,
        createdAt: Date = Date(),
        expiresAt: Date? = nil,
        deliveryState: DeliveryState = .pending
    ) throws {
        guard UUID(uuidString: threadID) != nil else { throw ValidationError.invalidThreadID }
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 120 else { throw ValidationError.invalidQuestion }
        let expiry = expiresAt ?? createdAt.addingTimeInterval(86_400)
        guard expiry >= createdAt, expiry <= createdAt.addingTimeInterval(86_400) else {
            throw ValidationError.invalidExpiry
        }
        self.id = id
        self.threadID = threadID.lowercased()
        self.hostID = hostID
        self.question = trimmed
        self.createdAt = createdAt
        self.expiresAt = expiry
        self.deliveryState = deliveryState
    }

    enum ValidationError: Error { case invalidThreadID, invalidQuestion, invalidExpiry }
}

enum ConversationApprovalAction: String, Equatable {
    case approve
    case reject
    case requestChanges

    var responseText: String {
        switch self {
        case .approve: "อนุมัติ ดำเนินการต่อได้"
        case .reject: "ไม่อนุมัติ หยุดงานนี้ไว้ก่อน"
        case .requestChanges: "ขอแก้ไข รอรายละเอียดเพิ่มเติมจากผู้ใช้"
        }
    }
}
