import SwiftUI

extension ActivityKind {
    var tint: Color {
        switch self {
        case .timer: Color(red: 1.0, green: 0.62, blue: 0.04)
        case .alarm: Color(red: 1.0, green: 0.82, blue: 0.28)
        case .stopwatch: Color(red: 0.39, green: 0.90, blue: 0.75)
        }
    }
}

/// Un minuteur / une alarme / un chronomètre de l'app Horloge, façon « activité en direct » iPhone.
/// Un clic ouvre Horloge.
struct ActivityCardView: View {
    let activity: ClockActivity
    @State private var hovering = false

    private var tint: Color { activity.kind.tint }

    var body: some View {
        Button(action: ClockStore.openClockApp) {
            TimelineView(.periodic(from: .now, by: activity.kind == .stopwatch ? 0.1 : 0.5)) { context in
                content(now: context.date)
            }
            .padding(.leading, 14)
            .padding(.trailing, 16)
            .padding(.vertical, 12)
            .frame(width: 380)
            .contentShape(.rect(cornerRadius: 24))
        }
        .buttonStyle(PressScaleStyle())
        .onHover { hovering = $0 }
        .help("Ouvrir Horloge")
        .shadow(color: .black.opacity(0.5), radius: 4, y: 1)
        .shadow(color: .black.opacity(0.25), radius: 12)
        .glassEffect(
            activity.isRinging ? .clear.tint(tint.opacity(0.6)).interactive() : .clear.interactive(),
            in: .rect(cornerRadius: 24)
        )
    }

    private func content(now: Date) -> some View {
        HStack(spacing: 14) {
            ring(now: now)

            VStack(alignment: .leading, spacing: 0) {
                Text(subtitle(now: now))
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.7))
                    .lineLimit(1)
                Text(mainText(now: now))
                    .font(.system(size: 28, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(activity.isPaused ? .white.opacity(0.6) : .white)
                    .lineLimit(1)
                    .contentTransition(.numericText(countsDown: activity.kind != .stopwatch))
            }

            Spacer(minLength: 6)

            Image(systemName: "arrow.up.forward.app")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.white.opacity(hovering ? 0.85 : 0.4))
        }
    }

    private func ring(now: Date) -> some View {
        ZStack {
            Circle().stroke(.white.opacity(0.15), lineWidth: 4)
            Circle()
                .trim(from: 0, to: activity.isRinging ? 1 : activity.progress(at: now))
                .stroke(tint, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Image(systemName: activity.kind.symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(tint)
                .symbolEffect(.wiggle, options: .repeating, isActive: activity.isRinging)
        }
        .frame(width: 42, height: 42)
    }

    private func subtitle(now: Date) -> String {
        if activity.isRinging {
            return activity.kind == .alarm ? "\(activity.title) · sonne" : "\(activity.title) · terminé"
        }
        switch activity.kind {
        case .timer, .stopwatch:
            return activity.isPaused ? "\(activity.title) · en pause" : activity.title
        case .alarm:
            let prefix = activity.isSnoozed ? "Rappel" : activity.title
            return "\(prefix) · \(formatUntil(activity.remaining(at: now)))"
        }
    }

    private func mainText(now: Date) -> String {
        switch activity.kind {
        case .timer:
            return activity.isRinging ? "0:00" : formatCountdown(activity.remaining(at: now))
        case .alarm:
            return (activity.endDate ?? now).formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))
        case .stopwatch:
            return formatStopwatch(activity.elapsed(at: now))
        }
    }
}
