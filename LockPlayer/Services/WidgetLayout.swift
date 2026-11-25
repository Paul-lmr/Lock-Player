import AppKit
import Observation

/// Les widgets que l'on peut placer sur l'écran verrouillé.
enum WidgetKind: String, CaseIterable, Codable, Identifiable {
    case music, timers, alarms, stopwatch, worldClocks

    var id: String { rawValue }

    var title: String {
        switch self {
        case .music: "Musique"
        case .timers: "Minuteurs"
        case .alarms: "Alarmes"
        case .stopwatch: "Chronomètre"
        case .worldClocks: "Horloges"
        }
    }

    var symbol: String {
        switch self {
        case .music: "music.note"
        case .timers: "timer"
        case .alarms: "alarm.fill"
        case .stopwatch: "stopwatch"
        case .worldClocks: "globe"
        }
    }

    /// Tailles proposées dans le menu du clic droit (vide = une seule taille).
    var availableSizes: [WidgetSize] {
        switch self {
        case .worldClocks: [.small, .medium, .large]
        case .music: [.small, .medium]
        default: []
        }
    }

    /// Type de carte Horloge affiché par ce widget.
    var activityKind: ActivityKind? {
        switch self {
        case .timers: .timer
        case .alarms: .alarm
        case .stopwatch: .stopwatch
        case .music, .worldClocks: nil
        }
    }
}

enum WidgetSize: String, CaseIterable, Codable {
    case small, medium, large

    var title: String {
        switch self {
        case .small: "Petit"
        case .medium: "Moyen"
        case .large: "Grand"
        }
    }
}

/// Les crans magnétiques : chaque widget lâché se cale sur le plus proche.
/// Positions en proportion de l'écran, donc valables sur tous les écrans.
enum SnapSlot: String, CaseIterable, Codable {
    case topLeft, underClock, topRight, middleLeft, middleRight, bottomLeft, aboveLogin, bottomRight

    enum Align { case leading, center, trailing }
    enum Growth { case down, up, centered }

    /// Marge au bord de l'écran : 36 pt visibles, moins la marge d'ombre déjà incluse dans chaque panneau.
    static let edge: CGFloat = 36 - WidgetLayoutStore.shadowMargin

    var align: Align {
        switch self {
        case .topLeft, .middleLeft, .bottomLeft: .leading
        case .underClock, .aboveLogin: .center
        case .topRight, .middleRight, .bottomRight: .trailing
        }
    }

    var growth: Growth {
        switch self {
        case .topLeft, .underClock, .topRight: .down
        case .middleLeft, .middleRight: .centered
        case .bottomLeft, .aboveLogin, .bottomRight: .up
        }
    }

    /// Ligne d'ancrage : haut de la pile (down), bas (up) ou milieu (centered).
    func anchorY(in f: NSRect) -> CGFloat {
        switch self {
        case .topLeft, .topRight: f.maxY - f.height * 0.08
        case .underClock: f.maxY - f.height * 0.30
        case .middleLeft, .middleRight: f.midY
        case .bottomLeft, .bottomRight: f.minY + Self.edge
        case .aboveLogin: f.minY + f.height * 0.24
        }
    }

    func x(width: CGFloat, in f: NSRect) -> CGFloat {
        switch align {
        case .leading: f.minX + Self.edge
        case .center: f.midX - width / 2
        case .trailing: f.maxX - Self.edge - width
        }
    }

    /// Haut de la pile pour une hauteur totale donnée.
    func stackTop(totalHeight: CGFloat, in f: NSRect) -> CGFloat {
        switch growth {
        case .down: anchorY(in: f)
        case .up: anchorY(in: f) + totalHeight
        case .centered: anchorY(in: f) + totalHeight / 2
        }
    }
}

struct WidgetPlacement: Codable, Equatable {
    var slot: SnapSlot
    var order: Double
    var enabled: Bool
}

@MainActor
@Observable
final class WidgetLayoutStore {
    /// Marge transparente autour de chaque widget, pour que son ombre ne soit jamais coupée.
    nonisolated static let shadowMargin: CGFloat = 64
    /// Écart entre deux widgets d'une même pile : 28 pt visibles (les marges d'ombre se chevauchent).
    static let gap: CGFloat = 28 - 2 * shadowMargin

    private(set) var placements: [WidgetKind: WidgetPlacement] = [:] {
        didSet { save() }
    }

    /// Taille choisie pour chaque widget (clic droit › Taille).
    private(set) var widgetSizes: [WidgetKind: WidgetSize] = [:] {
        didSet { saveSettings() }
    }

    /// Villes d'Horloge que l'utilisateur a masquées dans le widget Horloges.
    private(set) var hiddenCities: Set<String> = [] {
        didSet { saveSettings() }
    }

    @ObservationIgnored private static let key = "widgetLayout"
    @ObservationIgnored private static let sizesKey = "widgetSizes"
    @ObservationIgnored private static let hiddenCitiesKey = "hiddenWorldCities"

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let saved = try? JSONDecoder().decode([String: WidgetPlacement].self, from: data) {
            for (raw, placement) in saved {
                if let kind = WidgetKind(rawValue: raw) { placements[kind] = placement }
            }
        }
        // Valeurs par défaut (et reprise de l'ancien réglage « Position du lecteur »).
        let oldMusicSlot: SnapSlot? = UserDefaults.standard.string(forKey: "miniPosition").flatMap { SnapSlot(rawValue: $0) }
        // Alarmes et chrono : en bas à gauche, sauf si la musique y est déjà.
        let clockSlot: SnapSlot = oldMusicSlot == .bottomLeft ? .topLeft : .bottomLeft
        let defaults: [WidgetKind: WidgetPlacement] = [
            .music: WidgetPlacement(slot: oldMusicSlot ?? .underClock, order: 0, enabled: true),
            .timers: WidgetPlacement(slot: oldMusicSlot ?? .underClock, order: 1, enabled: true),
            .alarms: WidgetPlacement(slot: clockSlot, order: 0, enabled: true),
            .stopwatch: WidgetPlacement(slot: clockSlot, order: 1, enabled: true),
            .worldClocks: WidgetPlacement(slot: .bottomRight, order: 0,
                                          enabled: UserDefaults.standard.object(forKey: "showWorldClocks") as? Bool ?? true),
        ]
        for (kind, placement) in defaults where placements[kind] == nil {
            placements[kind] = placement
        }
        if let raw = UserDefaults.standard.dictionary(forKey: Self.sizesKey) as? [String: String] {
            for (k, v) in raw {
                if let kind = WidgetKind(rawValue: k), let size = WidgetSize(rawValue: v) { widgetSizes[kind] = size }
            }
        }
        hiddenCities = Set(UserDefaults.standard.stringArray(forKey: Self.hiddenCitiesKey) ?? [])
    }

    func size(of kind: WidgetKind) -> WidgetSize {
        widgetSizes[kind] ?? .medium
    }

    func setSize(_ size: WidgetSize, for kind: WidgetKind) {
        widgetSizes[kind] = size
    }

    func isCityShown(_ id: String) -> Bool { !hiddenCities.contains(id) }

    func setCity(_ id: String, shown: Bool) {
        if shown { hiddenCities.remove(id) } else { hiddenCities.insert(id) }
    }

    private func saveSettings() {
        UserDefaults.standard.set(Dictionary(uniqueKeysWithValues: widgetSizes.map { ($0.key.rawValue, $0.value.rawValue) }),
                                  forKey: Self.sizesKey)
        UserDefaults.standard.set(Array(hiddenCities), forKey: Self.hiddenCitiesKey)
    }

    func placement(_ kind: WidgetKind) -> WidgetPlacement {
        placements[kind] ?? WidgetPlacement(slot: .underClock, order: 0, enabled: true)
    }

    func isEnabled(_ kind: WidgetKind) -> Bool { placement(kind).enabled }

    var disabledKinds: [WidgetKind] { WidgetKind.allCases.filter { !isEnabled($0) } }

    func setEnabled(_ kind: WidgetKind, _ enabled: Bool) {
        var p = placement(kind)
        guard p.enabled != enabled else { return }
        p.enabled = enabled
        if enabled {
            // Remis en bas de sa pile.
            p.order = (placements.values.filter { $0.slot == p.slot && $0.enabled }.map(\.order).max() ?? -1) + 1
        }
        placements[kind] = p
    }

    /// Range `kind` dans `slot`, à la position `index` parmi les widgets visibles de ce cran.
    func move(_ kind: WidgetKind, to slot: SnapSlot, index: Int, among visible: [WidgetKind]) {
        var members = visible
            .filter { $0 != kind && placement($0).slot == slot }
            .sorted(by: inStackOrder)
        members.insert(kind, at: max(0, min(index, members.count)))
        var updated = placements
        for (i, member) in members.enumerated() {
            var p = placement(member)
            p.slot = slot
            p.order = Double(i)
            updated[member] = p
        }
        placements = updated
    }

    /// Ordre dans une pile : rang choisi, puis ordre fixe des widgets en cas d'égalité.
    private func inStackOrder(_ a: WidgetKind, _ b: WidgetKind) -> Bool {
        let (pa, pb) = (placement(a).order, placement(b).order)
        if pa != pb { return pa < pb }
        return WidgetKind.allCases.firstIndex(of: a)! < WidgetKind.allCases.firstIndex(of: b)!
    }

    /// Cadre de chaque widget visible : piles par cran, dans l'ordre choisi.
    func frames(sizes: [WidgetKind: CGSize], visible: [WidgetKind], in f: NSRect) -> [WidgetKind: NSRect] {
        var result: [WidgetKind: NSRect] = [:]
        for slot in SnapSlot.allCases {
            let members = visible
                .filter { placement($0).slot == slot && sizes[$0] != nil }
                .sorted(by: inStackOrder)
            guard !members.isEmpty else { continue }
            let total = members.reduce(0) { $0 + sizes[$1]!.height } + Self.gap * CGFloat(members.count - 1)
            var top = slot.stackTop(totalHeight: total, in: f)
            for member in members {
                let size = sizes[member]!
                result[member] = NSRect(x: slot.x(width: size.width, in: f), y: top - size.height,
                                        width: size.width, height: size.height)
                top -= size.height + Self.gap
            }
        }
        return result
    }

    /// Où atterrirait `kind` s'il était lâché dans `slot` au rang `index` (sans rien modifier).
    func landingFrame(of kind: WidgetKind, slot: SnapSlot, index: Int,
                      sizes: [WidgetKind: CGSize], visible: [WidgetKind], in f: NSRect) -> NSRect? {
        guard let size = sizes[kind] else { return nil }
        var members = visible
            .filter { $0 != kind && placement($0).slot == slot && sizes[$0] != nil }
            .sorted(by: inStackOrder)
        let position = max(0, min(index, members.count))
        members.insert(kind, at: position)
        let total = members.reduce(0) { $0 + sizes[$1]!.height } + Self.gap * CGFloat(members.count - 1)
        var top = slot.stackTop(totalHeight: total, in: f)
        for member in members.prefix(position) {
            top -= sizes[member]!.height + Self.gap
        }
        return NSRect(x: slot.x(width: size.width, in: f), y: top - size.height, width: size.width, height: size.height)
    }

    /// Zone d'un cran pour un widget de cette taille (guides et aimantation).
    func slotRect(_ slot: SnapSlot, size: CGSize, in f: NSRect) -> NSRect {
        let top = slot.stackTop(totalHeight: size.height, in: f)
        return NSRect(x: slot.x(width: size.width, in: f), y: top - size.height, width: size.width, height: size.height)
    }

    func nearestSlot(to center: NSPoint, size: CGSize, in f: NSRect) -> SnapSlot {
        SnapSlot.allCases.min { a, b in
            distance(center, slotRect(a, size: size, in: f)) < distance(center, slotRect(b, size: size, in: f))
        } ?? .underClock
    }

    private func distance(_ p: NSPoint, _ r: NSRect) -> CGFloat {
        hypot(p.x - r.midX, p.y - r.midY)
    }

    private func save() {
        let raw = Dictionary(uniqueKeysWithValues: placements.map { ($0.key.rawValue, $0.value) })
        guard let data = try? JSONEncoder().encode(raw) else { return }
        UserDefaults.standard.set(data, forKey: Self.key)
    }
}
