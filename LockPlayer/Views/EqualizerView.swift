import SwiftUI

/// Barres qui bougent avec la musique (vrai son si disponible, sinon animation de secours).
struct EqualizerView: View {
    let core: AppCore
    var barWidth: CGFloat = 3
    var spacing: CGFloat = 2.5
    var height: CGFloat = 18

    var body: some View {
        let levels = core.audio
        let playing = core.model.isPlaying
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !playing || levels.isLive)) { context in
            let values: [Float] = {
                guard playing else { return [Float](repeating: 0, count: AudioLevels.bandCount) }
                if levels.isLive { return levels.bands }
                return Self.fallback(at: context.date.timeIntervalSinceReferenceDate)
            }()
            HStack(alignment: .center, spacing: spacing) {
                ForEach(values.indices, id: \.self) { i in
                    Capsule()
                        .fill(.white.opacity(0.9))
                        .frame(width: barWidth, height: barWidth + (height - barWidth) * CGFloat(min(1, max(0, values[i]))))
                }
            }
            .frame(height: height)
            .animation(.easeOut(duration: levels.isLive ? 0.08 : 0.2), value: values)
        }
    }

    /// Mouvement pseudo-aléatoire quand on n'a pas accès au son.
    private static func fallback(at t: Double) -> [Float] {
        (0..<AudioLevels.bandCount).map { i in
            let x = t * (2.1 + Double(i) * 0.7) + Double(i) * 1.3
            let v = 0.55 + 0.3 * sin(x) + 0.15 * sin(x * 2.7 + 0.5)
            return Float(v)
        }
    }
}
