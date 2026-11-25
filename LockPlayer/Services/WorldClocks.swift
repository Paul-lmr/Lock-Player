import Foundation
import Observation
import os

// Les villes de l'onglet « Horloges » de l'app Horloge d'Apple.
//
// Horloge range sa liste de villes (clé « cities », cf. WorldClockPreferences dans MobileTimer)
// dans son conteneur protégé, que macOS ne laisse lire qu'avec l'« Accès complet au disque ».
// Sans cette autorisation, le widget Horloges l'indique et reste vide.

struct WorldCity: Identifiable, Equatable {
    let id: String
    let name: String
    let timeZone: TimeZone
}

@MainActor
@Observable
final class WorldClockStore {
    /// Les villes d'Horloge, sauf celles qui ont la même heure que le Mac.
    private(set) var cities: [WorldCity] = []
    /// false tant que le fichier d'Horloge n'a pas pu être lu (autorisation refusée, aucune ville…).
    private(set) var isAvailable = false

    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var lastSignature = ""
    @ObservationIgnored private let log = Logger(subsystem: "com.lockplayer.app", category: "WorldClock")

    /// Réglages d'Horloge (clé « cities »), dans son conteneur protégé.
    private static let fileURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Containers/com.apple.clock/Data/Library/Preferences/com.apple.mobiletimer.plist")

    func start() {
        refresh()
    }

    /// Relecture à l'affichage, puis une fois par minute tant que c'est à l'écran.
    func setActive(_ active: Bool) {
        timer?.invalidate()
        timer = nil
        guard active else { return }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        timer?.tolerance = 10
    }

    func refresh() {
        guard let data = try? Data(contentsOf: Self.fileURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let rawCities = plist["cities"] as? [Any] else {
            if isAvailable || lastSignature.isEmpty {
                log.notice("Villes d'Horloge illisibles (Accès complet au disque non accordé ?)")
                lastSignature = "-"
            }
            isAvailable = false
            if !cities.isEmpty { cities = [] }
            return
        }

        let parsed = rawCities.compactMap(Self.city(from:))
        let signature = parsed.map(\.id).joined(separator: ",")
        if signature != lastSignature {
            lastSignature = signature
            log.notice("Villes d'Horloge : \(parsed.map(\.name).joined(separator: ", "), privacy: .public)")
        }
        isAvailable = true
        // Les villes qui ont déjà l'heure du Mac ne servent à rien dans le widget.
        let local = TimeZone.current.secondsFromGMT()
        let others = parsed.filter { $0.timeZone.secondsFromGMT() != local }
        if others != cities { cities = others }
    }

    /// Une ville d'Horloge : dictionnaire de propriétés (nom, fuseau…), parfois imbriqué.
    nonisolated private static func city(from value: Any) -> WorldCity? {
        guard let dict = value as? [String: Any] else { return nil }
        for wrapper in ["city", "City", "properties", "$WorldClockCity"] {
            if let inner = dict[wrapper] as? [String: Any], let city = city(from: inner) { return city }
        }
        let zoneName = ["timeZone", "TimeZone", "timezone", "olsonTimeZone", "tz"].lazy.compactMap { dict[$0] as? String }.first
        guard let zoneName, let zone = TimeZone(identifier: zoneName) else { return nil }
        let name = ["name", "Name", "displayName", "unlocalizedCityName", "cityName"].lazy.compactMap { dict[$0] as? String }.first
            ?? zoneName.split(separator: "/").last.map { $0.replacingOccurrences(of: "_", with: " ") }
            ?? zoneName
        let id = (dict["idUrl"] as? String) ?? (dict["identifier"] as? String) ?? "\(name)|\(zoneName)"
        return WorldCity(id: id, name: name, timeZone: zone)
    }
}
