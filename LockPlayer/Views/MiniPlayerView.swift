import SwiftUI

/// Le petit lecteur en verre affiché sur l'écran verrouillé.
struct MiniPlayerView: View {
    let core: AppCore
    private var model: NowPlaying { core.model }

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                Button {
                    core.expand(lyrics: false)
                } label: {
                    ArtworkView(image: model.artwork, size: 52, cornerRadius: 10)
                        .shadow(color: .black.opacity(0.25), radius: 6, y: 2)
                }
                .buttonStyle(PressScaleStyle())
                .help("Afficher la pochette en grand")

                VStack(alignment: .leading, spacing: 2) {
                    Text(model.hasTrack ? model.title : "Aucune musique")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                    Text(model.hasTrack ? model.artist : "Lance un morceau dans Spotify")
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.65))
                }
                .lineLimit(1)

                Spacer(minLength: 8)

                EqualizerView(core: core)
            }

            TimelineView(.periodic(from: .now, by: 0.5)) { context in
                ProgressRow(elapsed: model.elapsed(at: context.date), duration: model.duration) { core.seek(to: $0) }
            }

            ZStack {
                TransportControls(core: core, iconSize: 20, spacing: 26)
                HStack {
                    if core.ui.isPreview && !core.ui.showcase {
                        GlassIconButton(systemName: "xmark", size: 11) { core.togglePreview() }
                            .help("Fermer l'aperçu")
                    }
                    Spacer()
                    GlassIconButton(systemName: "quote.bubble", size: 12) { core.expand(lyrics: true) }
                        .help("Paroles")
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 16)
        .padding(.bottom, 12)
        .frame(width: 380)
        .shadow(color: .black.opacity(0.5), radius: 4, y: 1) // lisibilité sur verre clair
        .shadow(color: .black.opacity(0.25), radius: 12)
        .glassEffect(.clear.interactive(), in: .rect(cornerRadius: 26))
    }
}

/// Version compacte du lecteur (clic droit › Taille › Petit) : pochette, titre, lecture / suivant.
struct CompactPlayerView: View {
    let core: AppCore
    private var model: NowPlaying { core.model }

    var body: some View {
        HStack(spacing: 11) {
            Button {
                core.expand(lyrics: false)
            } label: {
                ArtworkView(image: model.artwork, size: 42, cornerRadius: 9)
                    .shadow(color: .black.opacity(0.25), radius: 5, y: 2)
            }
            .buttonStyle(PressScaleStyle())
            .help("Afficher la pochette en grand")

            VStack(alignment: .leading, spacing: 1) {
                Text(model.hasTrack ? model.title : "Aucune musique")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                Text(model.hasTrack ? model.artist : "Lance un morceau")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.65))
            }
            .lineLimit(1)

            Spacer(minLength: 4)

            ControlButton(systemName: model.isPlaying ? "pause.fill" : "play.fill", size: 17) {
                core.togglePlayPause()
            }
            .contentTransition(.symbolEffect(.replace))
            ControlButton(systemName: "forward.fill", size: 14) { core.next() }
        }
        .padding(.leading, 12)
        .padding(.trailing, 8)
        .padding(.vertical, 10)
        .frame(width: 300)
        .shadow(color: .black.opacity(0.5), radius: 4, y: 1)
        .shadow(color: .black.opacity(0.25), radius: 12)
        .glassEffect(.clear.interactive(), in: .rect(cornerRadius: 22))
    }
}
