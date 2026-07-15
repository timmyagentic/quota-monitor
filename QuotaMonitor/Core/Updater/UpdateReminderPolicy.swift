import Foundation

enum UpdateReminderPolicy {
    static let initialDelay: TimeInterval = 86_400
    static let recurringDelay: TimeInterval = 259_200

    static func nextDate(after now: Date, deliveredCount: Int) -> Date {
        now.addingTimeInterval(deliveredCount == 0 ? initialDelay : recurringDelay)
    }

    static func isDue(_ snapshot: PendingUpdateSnapshot, at now: Date) -> Bool {
        guard let nextReminderAt = snapshot.nextReminderAt else { return false }
        return now >= nextReminderAt
    }
}
