import Foundation

/// Invalidates asynchronous focus callbacks from an earlier request.
@MainActor
final class HarnessFocusRequestGate {
    private var latest: UInt64 = 0

    @discardableResult
    func begin() -> UInt64 {
        latest &+= 1
        return latest
    }

    func isCurrent(_ requestID: UInt64) -> Bool { latest == requestID }
}
