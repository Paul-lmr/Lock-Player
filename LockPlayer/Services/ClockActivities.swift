import AppKit
import Foundation
import IOKit.pwr_mgt
import Observation

// Lecture (seule) des minuteurs, alarmes et chronomètres de l'app Horloge d'Apple.
//
// Le service d'Horloge (mobiletimerd) refuse les autres apps, mais il recopie en direct
// son état dans ~/Library/Preferences/com.apple.mobiletimerd.plist. Format déduit des
// classes MobileTimer de macOS 27 :
//   • minuteur : MTTimerState 1 = arrêté, 2 = en pause, 3 = en cours ;
//     MTTimerFireTime = $MTTimerDate (fin) en cours, $MTTimerTimeInterval (restant) en pause.
//   • chronomètre : MTStopwatchState 0 = arrêté, 1 = en pause, 2 = en cours.
//   • alarme : MTAlarmRepeatSchedule = masque de jours (bit 0 = lundi … bit 6 = dimanche).

enum ActivityKind: String, CaseIterable {
    case timer, alarm, stopwatch

    var symbol: String {
        switch self {
        case .timer: "timer"
        case .alarm: "alarm.fill"
        case .stopwatch: "stopwatch"
        }
    }

    var defaultLabel: String {
        switch self {
        case .timer: "Minuteur"
        case .alarm: "Alarme"
        case .stopwatch: "Chronomètre"
        }
    }
}

struct ClockActivity: Identifiable, Equatable {
    let id: String
    let kind: ActivityKind
    var label: String = ""
    /// Minuteur : durée totale.
    var duration: TimeInterval = 0
    /// Minuteur en cours / alarme : moment où ça sonne.
    var endDate: Date?
    /// Minuteur en pause : temps restant.
    var pausedRemaining: TimeInterval?
    /// Chronomètre : en marche depuis (nil si en pause).
    var startDate: Date?
    var accumulated: TimeInterval = 0
    var isPaused = false
    var isRinging = false
    var isSnoozed = false

    var title: String { label.isEmpty ? kind.defaultLabel : label }

    func remaining(at now: Date) -> TimeInterval {
        if let pausedRemaining { return pausedRemaining }
        guard let endDate else { return 0 }
        return max(0, endDate.timeIntervalSince(now))
    }

    func elapsed(at now: Date) -> TimeInterval {
        accumulated + (startDate.map { max(0, now.timeIntervalSince($0)) } ?? 0)
    }

    /// Avancement de l'anneau, de 0 à 1.
    func progress(at now: Date) -> Double {
        switch kind {
        case .timer:
            return duration > 0 ? 1 - remaining(at: now) / duration : 1
        case .alarm:
            return 1 - min(1, remaining(at: now) / ClockStore.alarmHorizon)
        case .stopwatch:
            return elapsed(at: now).truncatingRemainder(dividingBy: 60) / 60
        }
    }
}

@MainActor
@Observable
final class ClockStore {
    /// Une alarme n'apparaît sur l'écran verrouillé que si elle sonne dans moins de 12 h.
    nonisolated static let alarmHorizon: TimeInterval = 12 * 3600

    private(set) var items: [ClockActivity] = []
    private(set) var now = Date()

    /// Appelé quand une alarme ou un minuteur d'Horloge se met à sonner.
    @ObservationIgnored var onRing: (() -> Void)?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var raw: [String: Any] = [:]

    private static let fileURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Preferences/com.apple.mobiletimerd.plist")

    func start() {
        refresh()
    }

    /// Relecture chaque seconde uniquement quand les widgets sont à l'écran.
    func setActive(_ active: Bool) {
        timer?.invalidate()
        timer = nil
        guard active else { return }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        timer?.tolerance = 0.2
    }

    /// Minuteur ou chronomètre en marche (pour garder l'écran allumé).
    var hasRunningTimers: Bool { items.contains { $0.kind != .alarm && !$0.isPaused && !$0.isRinging } }

    /// Ce qui sonne d'abord, puis minuteurs, chronomètres et alarmes proches.
    /// Alarmes : celles qui sonnent ou sont en rappel, plus la prochaine alarme activée (quelle que soit l'heure).
    var lockScreenItems: [ClockActivity] {
        let nextAlarm = items
            .filter { $0.kind == .alarm && !$0.isRinging && !$0.isSnoozed }
            .min { $0.remaining(at: now) < $1.remaining(at: now) }
        let visible = items.filter { item in
            item.kind != .alarm || item.isRinging || item.isSnoozed || item.id == nextAlarm?.id
        }
        return visible.filter(\.isRinging) + visible.filter { !$0.isRinging }
    }

    /// Les cartes d'un type (pour le widget Minuteurs, Alarmes ou Chronomètre).
    func items(of kind: ActivityKind) -> [ClockActivity] {
        lockScreenItems.filter { $0.kind == kind }
    }

    /// Ouvre l'app Horloge d'Apple.
    static func openClockApp() {
        let url = URL(fileURLWithPath: "/System/Applications/Clock.app")
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    // MARK: - Lecture

    private func refresh() {
        now = Date()
        raw = Self.readLive()
        // Recalculé chaque seconde : prochaines alarmes, rappels, sonneries.
        let wasRinging = Set(items.filter(\.isRinging).map(\.id))
        let parsed = Self.parse(raw, now: now)
        if parsed != items { items = parsed }
        let ringingNow = Set(items.filter(\.isRinging).map(\.id))
        if !ringingNow.subtracting(wasRinging).isEmpty {
            Self.wakeDisplay()
            onRing?()
        }
    }

    /// Lit l'état d'Horloge auprès du service des préférences (cfprefsd), qui a les valeurs
    /// à jour tout de suite. Le fichier .plist, lui, n'est écrit sur le disque que plusieurs
    /// secondes plus tard : une pause ou une reprise y apparaissait en retard.
    private static func readLive() -> [String: Any] {
        let domain = "com.apple.mobiletimerd" as CFString
        CFPreferencesAppSynchronize(domain) // vide notre cache pour relire les dernières valeurs
        var root: [String: Any] = [:]
        for key in ["MTTimers", "MTStopwatches", "MTAlarms"] {
            if let value = CFPreferencesCopyAppValue(key as CFString, domain) {
                root[key] = value
            }
        }
        if !root.isEmpty { return root }
        // Secours : le fichier sur le disque.
        guard let data = try? Data(contentsOf: fileURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return [:] }
        return plist
    }

    private static func list(_ root: [String: Any], _ key: String, _ wrapper: String) -> [[String: Any]] {
        ((root[key] as? [String: Any])?[key] as? [[String: Any]] ?? []).compactMap { $0[wrapper] as? [String: Any] }
    }

    private static func parse(_ root: [String: Any], now: Date) -> [ClockActivity] {
        var result: [ClockActivity] = []

        // Minuteurs
        for t in list(root, "MTTimers", "$MTTimer") {
            let state = (t["MTTimerState"] as? NSNumber)?.intValue ?? 0
            let id = t["MTTimerID"] as? String ?? UUID().uuidString
            var title = t["MTTimerTitle"] as? String ?? ""
            if title == "CURRENT_TIMER" { title = "" }
            let duration = (t["MTTimerDuration"] as? NSNumber)?.doubleValue ?? 0
            let fireTime = t["MTTimerFireTime"] as? [String: Any]
            let end = (fireTime?["$MTTimerDate"] as? [String: Any])?["MTTimerTimeDate"] as? Date
            let interval = ((fireTime?["$MTTimerTimeInterval"] as? [String: Any])?["MTTimerTimeInterval"] as? NSNumber)?.doubleValue
            let fired = t["MTTimerFiredDate"] as? Date
            let dismissed = t["MTTimerDismissedDate"] as? Date

            var activity = ClockActivity(id: id, kind: .timer, label: title, duration: duration)
            switch state {
            case 3: // en cours
                activity.endDate = end
                if let end, end <= now { activity.isRinging = true }
            case 2: // en pause
                activity.pausedRemaining = interval ?? duration
                activity.isPaused = true
            default: // arrêté : on ne l'affiche que s'il vient de sonner sans être fermé
                guard let fired, now.timeIntervalSince(fired) < 10 * 60, dismissed.map({ $0 < fired }) ?? true else { continue }
                activity.endDate = fired
                activity.isRinging = true
            }
            result.append(activity)
        }

        // Chronomètres
        for s in list(root, "MTStopwatches", "$MTStopwatch") {
            let state = (s["MTStopwatchState"] as? NSNumber)?.intValue ?? 0
            guard state == 1 || state == 2 else { continue }
            var activity = ClockActivity(id: s["MTStopwatchIdentifier"] as? String ?? UUID().uuidString, kind: .stopwatch,
                                         label: s["MTStopwatchTitle"] as? String ?? "")
            activity.accumulated = (s["MTStopwatchOffset"] as? NSNumber)?.doubleValue ?? 0
            if state == 2 {
                activity.startDate = s["MTStopwatchStartDate"] as? Date
            } else {
                activity.isPaused = true
            }
            result.append(activity)
        }

        // Alarmes
        for a in list(root, "MTAlarms", "$MTAlarm") {
            let enabled = (a["MTAlarmEnabled"] as? NSNumber)?.boolValue ?? false
            let hour = (a["MTAlarmHour"] as? NSNumber)?.intValue ?? 0
            let minute = (a["MTAlarmMinute"] as? NSNumber)?.intValue ?? 0
            let mask = (a["MTAlarmRepeatSchedule"] as? NSNumber)?.intValue ?? 0
            let fired = a["MTAlarmFireDate"] as? Date
            let dismissed = a["MTAlarmDismissDate"] as? Date
            let snooze = (a["MTAlarmSnoozeFireDate"] as? Date).flatMap { $0 > now ? $0 : nil }
            let keepOff = a["MTAlarmKeepOffUntilDate"] as? Date

            let ringing = fired.map { fired in
                fired <= now && now.timeIntervalSince(fired) < 15 * 60 && (dismissed.map { $0 < fired } ?? true) && snooze == nil
            } ?? false
            guard enabled || ringing || snooze != nil else { continue }

            var activity = ClockActivity(id: a["MTAlarmID"] as? String ?? UUID().uuidString, kind: .alarm,
                                         label: a["MTAlarmTitle"] as? String ?? "")
            activity.isRinging = ringing
            activity.isSnoozed = snooze != nil
            activity.endDate = ringing ? fired : (snooze ?? nextAlarm(hour: hour, minute: minute, mask: mask,
                                                                       after: max(now, keepOff ?? now)))
            result.append(activity)
        }
        return result
    }

    /// Prochaine sonnerie : masque de jours, bit 0 = lundi … bit 6 = dimanche (0 = une seule fois).
    private static func nextAlarm(hour: Int, minute: Int, mask: Int, after date: Date) -> Date? {
        let calendar = Calendar.current
        let time = DateComponents(hour: hour, minute: minute, second: 0)
        let days = (0..<7).filter { mask & (1 << $0) != 0 }
        if days.isEmpty {
            return calendar.nextDate(after: date, matching: time, matchingPolicy: .nextTime)
        }
        return days.compactMap { bit -> Date? in
            var components = time
            components.weekday = (bit + 1) % 7 + 1 // lundi = 2 … dimanche = 1
            return calendar.nextDate(after: date, matching: components, matchingPolicy: .nextTime)
        }.min()
    }

    /// Rallume l'écran quand quelque chose sonne.
    private static func wakeDisplay() {
        var id: IOPMAssertionID = 0
        guard IOPMAssertionDeclareUserActivity("LockPlayer : Horloge sonne" as CFString, kIOPMUserActiveLocal, &id) == kIOReturnSuccess else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { IOPMAssertionRelease(id) }
    }
}

// MARK: - Formats

func formatCountdown(_ seconds: TimeInterval) -> String {
    let total = Int(seconds.rounded(.up))
    let h = total / 3600, m = (total % 3600) / 60, s = total % 60
    return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
}

func formatStopwatch(_ seconds: TimeInterval) -> String {
    let tenths = Int(seconds * 10)
    let total = tenths / 10
    let h = total / 3600, m = (total % 3600) / 60, s = total % 60
    return h > 0
        ? String(format: "%d:%02d:%02d", h, m, s)
        : String(format: "%d:%02d,%d", m, s, tenths % 10)
}

/// « dans 2 h 05 » / « dans 12 min »
func formatUntil(_ seconds: TimeInterval) -> String {
    let minutes = Int((seconds / 60).rounded(.up))
    if minutes < 60 { return "dans \(minutes) min" }
    return String(format: "dans %d h %02d", minutes / 60, minutes % 60)
}
