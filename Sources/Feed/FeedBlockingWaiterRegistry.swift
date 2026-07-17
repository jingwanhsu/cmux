import CMUXAgentLaunch
import Foundation

/// Actor-owned request/reply state for blocking Feed socket calls.
///
/// Each request receives one buffered decision stream. Delivery is
/// first-writer-wins, and timeout removal finishes the stream so no suspended
/// consumer or continuation outlives its socket request.
actor FeedBlockingWaiterRegistry {
    struct PendingWaiter {
        let continuation: AsyncStream<WorkstreamDecision>.Continuation
        var decision: WorkstreamDecision?
        var itemID: UUID?
        var attentionTarget: FeedCoordinator.AttentionTarget?
    }

    private var waiters: [String: PendingWaiter] = [:]

    func register(requestID: String) -> AsyncStream<WorkstreamDecision>? {
        guard waiters[requestID] == nil else { return nil }
        var installedContinuation: AsyncStream<WorkstreamDecision>.Continuation?
        let stream = AsyncStream<WorkstreamDecision>(bufferingPolicy: .bufferingNewest(1)) {
            installedContinuation = $0
        }
        guard let continuation = installedContinuation else { return nil }
        waiters[requestID] = PendingWaiter(
            continuation: continuation,
            decision: nil,
            itemID: nil,
            attentionTarget: nil
        )
        return stream
    }

    /// Records the UI state created for a still-pending waiter. Returns false
    /// when the request resolved or timed out while MainActor was ingesting it.
    func recordIngest(
        itemID: UUID?,
        attentionTarget: FeedCoordinator.AttentionTarget?,
        requestID: String
    ) -> Bool {
        guard var waiter = waiters[requestID], waiter.decision == nil else {
            return false
        }
        waiter.itemID = itemID
        waiter.attentionTarget = attentionTarget
        waiters[requestID] = waiter
        return true
    }

    func deliver(
        _ decision: WorkstreamDecision,
        requestID: String
    ) -> (accepted: Bool, itemID: UUID?, attentionTarget: FeedCoordinator.AttentionTarget?) {
        guard var waiter = waiters[requestID], waiter.decision == nil else {
            return (false, nil, nil)
        }
        waiter.decision = decision
        waiters[requestID] = waiter
        waiter.continuation.yield(decision)
        waiter.continuation.finish()
        return (true, waiter.itemID, waiter.attentionTarget)
    }

    func remove(requestID: String) -> PendingWaiter? {
        let waiter = waiters.removeValue(forKey: requestID)
        waiter?.continuation.finish()
        return waiter
    }

    func isAwaitingDecision(requestID: String) -> Bool {
        guard let waiter = waiters[requestID] else { return false }
        return waiter.decision == nil
    }
}
