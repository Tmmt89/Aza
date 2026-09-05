import Foundation

enum MenuBarDisplay: String, CaseIterable {
    static let storageKey = "MenuBarDisplay"

    case logo, prayer, time, countdown

    var title: String {
        switch self {
        case .logo: "Логотип Aza"
        case .prayer: "Намаз и время"
        case .time: "Только время"
        case .countdown: "До намаза"
        }
    }

    /// nil оставляет фирменный знак, в том числе пока город не выбран.
    func text(for next: PrayerOccurrence?, now: Date) -> String? {
        guard self != .logo, let next else { return nil }
        switch self {
        case .logo: return nil
        case .prayer: return "\(next.kind.title) \(next.time)"
        case .time: return next.time
        case .countdown:
            let minutes = max(1, Int(ceil(next.date.timeIntervalSince(now) / 60)))
            let remaining = minutes < 60
                ? "\(minutes) мин"
                : "\(minutes / 60) ч \(minutes % 60) мин"
            return "\(next.kind.title) · \(remaining)"
        }
    }
}
