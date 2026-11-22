import SwiftUI

struct ArtworkView: View {
    let image: NSImage?
    let size: CGFloat
    let cornerRadius: CGFloat

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    LinearGradient(colors: [.gray.opacity(0.5), .gray.opacity(0.25)], startPoint: .topLeading, endPoint: .bottomTrailing)
                    Image(systemName: "music.note")
                        .font(.system(size: size * 0.38, weight: .medium))
                        .foregroundStyle(.white.opacity(0.7))
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}

/// Barre de progression cliquable / glissable pour se déplacer dans le morceau.
struct ProgressRow: View {
    let elapsed: Double
    let duration: Double
    var compact = true
    let onSeek: (Double) -> Void

    @State private var dragValue: Double?

    var body: some View {
        let shown = dragValue ?? elapsed
        HStack(spacing: 10) {
            Text(formatTime(shown))
                .frame(width: 40, alignment: .leading)
            GeometryReader { geo in
                let fraction = duration > 0 ? min(1, max(0, shown / duration)) : 0
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.22))
                    Capsule().fill(.white.opacity(dragValue == nil ? 0.85 : 1))
                        .frame(width: max(0, geo.size.width * fraction))
                }
                .frame(height: dragValue == nil ? (compact ? 5 : 7) : (compact ? 8 : 10))
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            guard duration > 0 else { return }
                            dragValue = min(1, max(0, value.location.x / geo.size.width)) * duration
                        }
                        .onEnded { _ in
                            if let dragValue { onSeek(dragValue) }
                            dragValue = nil
                        }
                )
                .animation(.easeOut(duration: 0.15), value: dragValue == nil)
            }
            .frame(height: 16)
            Text("-" + formatTime(max(0, duration - shown)))
                .frame(width: 44, alignment: .trailing)
        }
        .font(.system(size: compact ? 11 : 13, weight: .medium).monospacedDigit())
        .foregroundStyle(.white.opacity(0.6))
    }
}

struct TransportControls: View {
    let core: AppCore
    var iconSize: CGFloat = 22
    var spacing: CGFloat = 40

    var body: some View {
        HStack(spacing: spacing) {
            ControlButton(systemName: "backward.fill", size: iconSize) { core.previous() }
            ControlButton(systemName: core.model.isPlaying ? "pause.fill" : "play.fill", size: iconSize * 1.35) {
                core.togglePlayPause()
            }
            .contentTransition(.symbolEffect(.replace))
            ControlButton(systemName: "forward.fill", size: iconSize) { core.next() }
        }
    }
}

struct ControlButton: View {
    let systemName: String
    let size: CGFloat
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: size * 1.9, height: size * 1.9)
                .background(Circle().fill(.white.opacity(hovering ? 0.14 : 0)))
                .contentShape(Circle())
        }
        .buttonStyle(PressScaleStyle())
        .onHover { hovering = $0 }
    }
}

struct PressScaleStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.86 : 1)
            .animation(.spring(duration: 0.2), value: configuration.isPressed)
    }
}

/// Petit bouton rond translucide (paroles, fermer…).
struct GlassIconButton: View {
    let systemName: String
    var active = false
    var size: CGFloat = 13
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(active ? .black : .white.opacity(0.85))
                .frame(width: size * 2.4, height: size * 2.4)
                .background(Circle().fill(active ? .white : .white.opacity(0.12)))
                .contentShape(Circle())
        }
        .buttonStyle(PressScaleStyle())
    }
}
