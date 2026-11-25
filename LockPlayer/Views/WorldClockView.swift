import SwiftUI

/// Les autres fuseaux d'Horloge, comme le widget « Horloges » de l'iPhone. Un clic ouvre Horloge.
/// Trois tailles (clic droit › Taille) :
/// • Petit : liste compacte « ville … heure » ;
/// • Moyen : grille de 3 colonnes, heure + décalage ;
/// • Grand : grille de 3 colonnes, grands chiffres, jour + décalage.
struct WorldClockCard: View {
    let cities: [WorldCity]
    var size: WidgetSize = .medium

    private var width: CGFloat {
        switch size {
        case .small: 250
        case .medium: 380
        case .large: 500
        }
    }

    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 10), count: min(max(cities.count, 1), 3))
    }

    var body: some View {
        Button(action: ClockStore.openClockApp) {
            TimelineView(.everyMinute) { context in
                if size == .small {
                    VStack(spacing: 7) {
                        ForEach(cities) { city in
                            HStack(alignment: .firstTextBaseline) {
                                Text(city.name)
                                    .font(.system(size: 13.5, weight: .semibold))
                                    .foregroundStyle(.white.opacity(0.85))
                                    .lineLimit(1)
                                Spacer(minLength: 8)
                                Text(time(in: city.timeZone, now: context.date))
                                    .font(.system(size: 17, weight: .semibold, design: .rounded).monospacedDigit())
                                    .foregroundStyle(.white)
                            }
                        }
                    }
                } else {
                    LazyVGrid(columns: columns, alignment: .leading, spacing: size == .large ? 16 : 12) {
                        ForEach(cities) { city in
                            cell(city, now: context.date)
                        }
                    }
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, size == .small ? 12 : 14)
            .frame(width: width)
            .contentShape(.rect(cornerRadius: 24))
        }
        .buttonStyle(PressScaleStyle())
        .help("Ouvrir Horloge")
        .shadow(color: .black.opacity(0.5), radius: 4, y: 1)
        .shadow(color: .black.opacity(0.25), radius: 12)
        .glassEffect(.clear.interactive(), in: .rect(cornerRadius: 24))
        .animation(.spring(duration: 0.35), value: size)
    }

    private func cell(_ city: WorldCity, now: Date) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(city.name)
                .font(.system(size: size == .large ? 15 : 13, weight: .semibold))
                .foregroundStyle(.white.opacity(0.85))
                .lineLimit(1)
            Text(time(in: city.timeZone, now: now))
                .font(.system(size: size == .large ? 38 : 26, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(.white)
            Text(offset(of: city.timeZone, now: now))
                .font(.system(size: size == .large ? 12.5 : 11.5, weight: .medium))
                .foregroundStyle(.white.opacity(0.6))
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func time(in zone: TimeZone, now: Date) -> String {
        var style = Date.FormatStyle.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits)
        style.timeZone = zone
        return now.formatted(style)
    }

    /// « −4 h 30 », ou « Demain, +3 h 30 » quand le jour change
    private func offset(of zone: TimeZone, now: Date) -> String {
        let delta = zone.secondsFromGMT(for: now) - TimeZone.current.secondsFromGMT(for: now)
        let sign = delta >= 0 ? "+" : "−"
        let h = abs(delta) / 3600, m = (abs(delta) % 3600) / 60
        let amount = m == 0 ? "\(sign)\(h) h" : "\(sign)\(h) h \(String(format: "%02d", m))"

        var there = Calendar.current
        there.timeZone = zone
        let thereDay = there.dateComponents([.year, .month, .day], from: now)
        let hereDay = Calendar.current.dateComponents([.year, .month, .day], from: now)
        func key(_ c: DateComponents) -> Int { (c.year ?? 0) * 10_000 + (c.month ?? 0) * 100 + (c.day ?? 0) }
        // Le jour n'est précisé que s'il change (« Demain, +3 h 30 ») ; sinon juste le décalage.
        if key(thereDay) == key(hereDay) { return amount }
        return "\(key(thereDay) > key(hereDay) ? "Demain" : "Hier"), \(amount)"
    }
}
