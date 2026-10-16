import Foundation

/// Describes a proven index commit. A thrown post-commit recovery error can still have a committed receipt.
public struct StoreCommitReceipt: Equatable, Sendable {
    public let operationID: UUID
    public let committed: Bool
    public let indexDigest: String
}

public struct StoreWriteResult<Value: Sendable>: Sendable {
    public let value: Value
    public let receipt: StoreCommitReceipt
}

/// Actor-owned, fixed-capacity history; operation IDs are process-local, not a persistent idempotency ledger.
struct StoreCommitHistory {
    private var slots = [StoreCommitReceipt?](repeating: nil, count: 64)
    private var cursor = 0
    private(set) var count = 0

    func receipt(operationID: UUID) -> StoreCommitReceipt? {
        for offset in 1...slots.count {
            let index = (cursor + slots.count - offset) % slots.count
            if let receipt = slots[index], receipt.operationID == operationID { return receipt }
        }
        return nil
    }

    mutating func remove(operationID: UUID) {
        for index in slots.indices where slots[index]?.operationID == operationID {
            slots[index] = nil
            count -= 1
        }
    }

    mutating func record(_ receipt: StoreCommitReceipt) {
        guard self.receipt(operationID: receipt.operationID) != receipt else { return }
        remove(operationID: receipt.operationID)
        if slots[cursor] == nil { count += 1 }
        slots[cursor] = receipt
        cursor = (cursor + 1) % slots.count
    }
}

struct CreativeWorkLibrarySnapshot: Sendable {
    let works: [CreativeWork]
    let audioURLsByID: [String: URL]
}
