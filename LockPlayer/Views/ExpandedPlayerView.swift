import SwiftUI

/// « 21:58  dim. 22 nov. » en haut, comme sur l'écran verrouillé de l'iPhone :
/// l'heure en blanc, la date teintée de la couleur de la pochette.
struct ClockHeader: View {
    let accent: Color

    var body: some View {
        TimelineView(.everyMinute) { context in
            HStack(alignment: .firstTextBaseline, spacing: 14) {
                Text(context.date, format: .dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))
                    .foregroundStyle(.white)
                Text(context.date, format: .dateTime.weekday(.abbreviated).day().month(.abbreviated))
                    .foregroundStyle(
                        LinearGradient(colors: [.white.opacity(0.9), accent.mix(with: .white, by: 0.55)],
                                       startPoint: .leading, endPoint: .trailing)
                    )
            }
            .font(.system(size: 30, weight: .bold, design: .rounded).monospacedDigit())
            .shadow(color: .black.opacity(0.25), radius: 6, y: 2)
            .environment(\.locale, Locale(identifier: "fr_FR"))
        }
    }
}

/// Plein écran : pochette en grand (façon iPhone) ou paroles synchronisées.
struct ExpandedPlayerView: View {
    let core: AppCore
    private var model: NowPlaying { core.model }
    @State private var appeared = false
    @State private var artTop: CGFloat?
    @Namespace private var namespace

    /// Bas de la notch (ou de la barre des menus sur un écran sans notch).
    private var notchBottom: CGFloat {
        let screen = NSScreen.screens.first
        let inset = screen?.safeAreaInsets.top ?? 0
        return inset > 0 ? inset : 28
    }

    var body: some View {
        GeometryReader { geo in
            let artSize = min(geo.size.height * 0.5, geo.size.width * 0.42, 560)
            ZStack {
                background(size: geo.size)
                    .onTapGesture { close() }

                if core.ui.showLyrics {
                    lyricsLayout(size: geo.size)
                } else {
                    artworkLayout(artSize: artSize)
                }

                // Heure : à mi-chemin entre le bas de la notch et le haut de la pochette.
                ClockHeader(accent: model.accent)
                    // Position fixe, calée sur le mode pochette (même quand on passe aux paroles).
                    .position(x: geo.size.width / 2,
                              y: (notchBottom + (artTop ?? estimatedArtTop(size: geo.size, artSize: artSize))) / 2)

                VStack {
                    HStack {
                        Spacer()
                        GlassIconButton(systemName: "chevron.down", size: 15) { close() }
                            .help("Réduire")
                    }
                    Spacer()
                }
                .padding(.horizontal, 36)
                .padding(.top, notchBottom + 16)
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .coordinateSpace(name: "root")
        }
        .ignoresSafeArea() // coordonnées = celles de l'écran, notch comprise
        .opacity(appeared ? 1 : 0)
        .scaleEffect(appeared ? 1 : 1.04)
        .onAppear {
            withAnimation(.easeOut(duration: 0.35)) { appeared = true }
        }
    }

    /// Haut de la pochette en mode pochette, quand on ouvre directement les paroles
    /// (pochette + 34 pt + carte ≈ 200 pt, centrés verticalement).
    private func estimatedArtTop(size: CGSize, artSize: CGFloat) -> CGFloat {
        (size.height - (artSize + 34 + 200)) / 2
    }

    private func close() {
        withAnimation(.easeIn(duration: 0.2)) { appeared = false }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            core.collapse()
        }
    }

    // MARK: - Fond flouté aux couleurs de la pochette

    private func background(size: CGSize) -> some View {
        ZStack {
            model.accent
            if let artwork = model.artwork {
                Image(nsImage: artwork)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .blur(radius: 90)
                    .saturation(1.5)
                    .scaleEffect(1.3)
            }
            LinearGradient(colors: [.black.opacity(0.15), .black.opacity(0.5)], startPoint: .top, endPoint: .bottom)
        }
        // Sans taille fixe, l'image en « fill » déborde et pousse le haut (heure, ⌄) hors de l'écran.
        .frame(width: size.width, height: size.height)
        .clipped()
        .ignoresSafeArea()
        .animation(.easeInOut(duration: 0.6), value: model.artwork)
    }

    // MARK: - Pochette en grand

    private func artworkLayout(artSize: CGFloat) -> some View {
        VStack(spacing: 34) {
            ArtworkView(image: model.artwork, size: artSize, cornerRadius: 28)
                .matchedGeometryEffect(id: "art", in: namespace)
                .onGeometryChange(for: CGFloat.self) { $0.frame(in: .named("root")).minY } action: { artTop = $0 }
                .shadow(color: .black.opacity(0.45), radius: 40, y: 20)
                .scaleEffect(model.isPlaying ? 1 : 0.9)
                .animation(.spring(duration: 0.5, bounce: 0.3), value: model.isPlaying)
                .contentShape(Rectangle())
                .onTapGesture { close() } // re-clic sur la pochette = retour au mini-lecteur
                .help("Revenir au mini-lecteur")

            playerCard(width: max(artSize, 460))
        }
    }

    private func playerCard(width: CGFloat) -> some View {
        VStack(spacing: 16) {
            ZStack {
                VStack(spacing: 4) {
                    Text(model.title)
                        .font(.system(size: 24, weight: .bold))
                        .foregroundStyle(.white)
                    Text(model.artist)
                        .font(.system(size: 19))
                        .foregroundStyle(.white.opacity(0.65))
                }
                .lineLimit(1)
                .padding(.horizontal, 50)

                HStack {
                    EqualizerView(core: core, barWidth: 3.5, spacing: 3, height: 22)
                    Spacer()
                    GlassIconButton(systemName: "quote.bubble", active: core.ui.showLyrics, size: 14) {
                        withAnimation(.spring(duration: 0.5)) { core.ui.showLyrics.toggle() }
                    }
                    .help("Paroles")
                }
            }

            TimelineView(.periodic(from: .now, by: 0.5)) { context in
                ProgressRow(elapsed: model.elapsed(at: context.date), duration: model.duration, compact: false) {
                    core.seek(to: $0)
                }
            }

            TransportControls(core: core, iconSize: 28, spacing: 50)
        }
        .padding(26)
        .frame(width: width)
        .shadow(color: .black.opacity(0.3), radius: 3, y: 1)
        .glassEffect(.clear.interactive(), in: .rect(cornerRadius: 32))
    }

    // MARK: - Paroles

    private func lyricsLayout(size: CGSize) -> some View {
        HStack(spacing: 70) {
            VStack(spacing: 28) {
                ArtworkView(image: model.artwork, size: min(360, size.height * 0.38), cornerRadius: 22)
                    .matchedGeometryEffect(id: "art", in: namespace)
                    .shadow(color: .black.opacity(0.4), radius: 30, y: 16)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        // depuis les paroles, clic sur la pochette = retour à la pochette en grand
                        withAnimation(.spring(duration: 0.5)) { core.ui.showLyrics = false }
                    }
                playerCard(width: 440)
            }

            LyricsView(core: core)
                .frame(width: min(640, size.width * 0.42), height: size.height * 0.78)
        }
    }
}
