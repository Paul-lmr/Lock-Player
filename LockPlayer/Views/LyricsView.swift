import SwiftUI

struct LyricsView: View {
    let core: AppCore

    var body: some View {
        Group {
            switch core.lyrics.state {
            case let .synced(lines):
                TimelineView(.periodic(from: .now, by: 0.2)) { context in
                    SyncedLyricsList(
                        lines: lines,
                        current: LyricsStore.currentIndex(in: lines, at: core.model.elapsed(at: context.date) + core.lyricsOffset)
                    ) { core.seek(to: $0) }
                }
            case let .plain(lines):
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("Paroles non synchronisées")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.5))
                        ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                            Text(line.isEmpty ? " " : line)
                                .font(.system(size: 24, weight: .bold))
                                .foregroundStyle(.white.opacity(0.85))
                        }
                    }
                    .padding(.vertical, 80)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .mask(fadeMask)
            case .loading, .idle:
                message(icon: "text.quote", text: "Recherche des paroles…", spinning: true)
            case .instrumental:
                message(icon: "pianokeys", text: "Morceau instrumental")
            case .notFound:
                message(icon: "text.badge.xmark", text: "Pas de paroles trouvées pour ce morceau")
            case .failed:
                VStack(spacing: 16) {
                    message(icon: "wifi.exclamationmark", text: "Impossible de charger les paroles")
                    Button("Réessayer") {
                        core.lyrics.retry(title: core.model.title, artist: core.model.artist,
                                          album: core.model.album, duration: core.model.duration)
                    }
                    .buttonStyle(.glass)
                }
            }
        }
    }

    private var fadeMask: some View {
        LinearGradient(stops: [
            .init(color: .clear, location: 0),
            .init(color: .black, location: 0.12),
            .init(color: .black, location: 0.88),
            .init(color: .clear, location: 1),
        ], startPoint: .top, endPoint: .bottom)
    }

    private func message(icon: String, text: String, spinning: Bool = false) -> some View {
        VStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 36, weight: .medium))
                .symbolEffect(.pulse, options: .repeating, isActive: spinning)
            Text(text)
                .font(.system(size: 20, weight: .semibold))
        }
        .foregroundStyle(.white.opacity(0.7))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Liste des paroles synchronisées : la ligne en cours est allumée et centrée.
struct SyncedLyricsList: View {
    let lines: [LyricLine]
    let current: Int?
    let onSeek: (Double) -> Void

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 22) {
                    ForEach(lines) { line in
                        let distance = current.map { abs($0 - line.id) } ?? 3
                        Text(line.text.isEmpty ? "♪" : line.text)
                            .font(.system(size: 32, weight: .bold))
                            .foregroundStyle(.white.opacity(line.id == current ? 1 : 0.32))
                            .blur(radius: line.id == current ? 0 : min(Double(distance) * 0.5, 2))
                            .scaleEffect(line.id == current ? 1 : 0.97, anchor: .leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                            .onTapGesture { onSeek(line.time) }
                            .id(line.id)
                            .animation(.easeOut(duration: 0.35), value: current)
                    }
                }
                .padding(.vertical, 260)
            }
            .mask(
                LinearGradient(stops: [
                    .init(color: .clear, location: 0),
                    .init(color: .black, location: 0.18),
                    .init(color: .black, location: 0.82),
                    .init(color: .clear, location: 1),
                ], startPoint: .top, endPoint: .bottom)
            )
            .onAppear {
                if let current { proxy.scrollTo(current, anchor: .center) }
            }
            .onChange(of: current) { _, newValue in
                guard let newValue else { return }
                withAnimation(.spring(duration: 0.6)) { proxy.scrollTo(newValue, anchor: .center) }
            }
        }
    }
}
