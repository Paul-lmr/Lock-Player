import SwiftUI

/// Enveloppe d'un widget : contenu + déplacement.
/// • Mode édition : on le glisse directement, il tremble un peu, badge « − » pour le retirer.
/// • Écran verrouillé : appui long (0,5 s) pour le soulever, puis on le glisse.
struct WidgetContainer: View {
    let core: AppCore
    let kind: WidgetKind

    @State private var lifted = false
    @State private var dragging = false

    private var editing: Bool { core.ui.editingWidgets }

    var body: some View {
        content
            .catchesClicks(cornerRadius: 24)
            .allowsHitTesting(!editing)
            .overlay(alignment: .topLeading) {
                if editing {
                    Button {
                        withAnimation(.spring(duration: 0.3)) { core.layout.setEnabled(kind, false) }
                    } label: {
                        Image(systemName: "minus")
                            .font(.system(size: 12, weight: .heavy))
                            .foregroundStyle(.black)
                            .frame(width: 24, height: 24)
                            .background(Circle().fill(.white))
                            .shadow(color: .black.opacity(0.3), radius: 4, y: 1)
                    }
                    .buttonStyle(.plain)
                    .offset(x: -8, y: -8)
                    .help("Retirer le widget")
                }
            }
            .phaseAnimator([false, true]) { view, phase in
                view.rotationEffect(.degrees(editing && !lifted ? (phase ? 0.45 : -0.45) : 0))
            } animation: { _ in .easeInOut(duration: 0.13) }
            .scaleEffect(lifted ? 1.04 : 1)
            // Ombre du widget soulevé : s'étale sur ~2 × rayon + décalage (16 × 2 + 8 = 40 pt), dans la marge de 64 pt.
            .shadow(color: .black.opacity(lifted ? 0.32 : 0), radius: 16, y: 8)
            .animation(.spring(duration: 0.3, bounce: 0.35), value: lifted)
            .contentShape(Rectangle())
            .contextMenu { WidgetSettingsMenu(core: core, kind: kind) }
            .gesture(editDrag, including: editing ? .all : .subviews)
            .simultaneousGesture(longPressDrag, including: editing ? .subviews : .all)
            // Marge transparente autour du widget : assez large pour que l'ombre du widget soulevé
            // ne soit jamais coupée par le bord de sa fenêtre (sinon : rectangle sombre aux bords durs).
            .padding(WidgetLayoutStore.shadowMargin)
            .fixedSize()
            .onGeometryChange(for: CGSize.self) { $0.size } action: { size in
                core.overlay.contentSizeChanged(size, for: kind)
            }
    }

    @ViewBuilder
    private var content: some View {
        switch kind {
        case .music:
            if core.layout.size(of: .music) == .small {
                CompactPlayerView(core: core)
            } else {
                MiniPlayerView(core: core)
            }
        case .timers, .alarms, .stopwatch:
            ClockKindWidget(core: core, kind: kind)
        case .worldClocks:
            if core.shownWorldCities.isEmpty {
                PlaceholderCard(kind: kind, text: !core.worldClocks.isAvailable
                                ? "Autorise LockPlayer dans Accès complet au disque"
                                : (core.worldClocks.cities.isEmpty ? "Aucune autre ville dans Horloge" : "Toutes les villes sont masquées"))
            } else {
                WorldClockCard(cities: core.shownWorldCities, size: core.layout.size(of: .worldClocks))
            }
        }
    }

    // Mode édition : glisser direct.
    private var editDrag: some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { _ in
                if !dragging { start() }
                core.overlay.dragMoved(kind)
            }
            .onEnded { _ in finish() }
    }

    // Écran verrouillé : appui long, puis glisser.
    private var longPressDrag: some Gesture {
        LongPressGesture(minimumDuration: 0.5)
            .sequenced(before: DragGesture(minimumDistance: 0))
            .onChanged { value in
                switch value {
                case .first(true):
                    lifted = true
                case .second(true, let drag?):
                    if !dragging { start() }
                    if drag.translation != .zero { core.overlay.dragMoved(kind) }
                default:
                    break
                }
            }
            .onEnded { _ in finish() }
    }

    private func start() {
        dragging = true
        lifted = true
        core.overlay.beginDrag(kind)
    }

    private func finish() {
        if dragging { core.overlay.endDrag(kind) }
        dragging = false
        lifted = false
    }
}

/// Minuteurs, alarmes ou chronomètre d'Horloge : les cartes de ce type, empilées.
struct ClockKindWidget: View {
    let core: AppCore
    let kind: WidgetKind

    var body: some View {
        let items = kind.activityKind.map { core.clock.items(of: $0) } ?? []
        if items.isEmpty {
            PlaceholderCard(kind: kind, text: placeholder)
        } else {
            VStack(spacing: 12) {
                ForEach(items) { ActivityCardView(activity: $0) }
            }
            .animation(.spring(duration: 0.4), value: items.map(\.id))
        }
    }

    private var placeholder: String {
        switch kind {
        case .timers: "Aucun minuteur en cours"
        case .alarms: "Aucune alarme activée"
        default: "Chronomètre arrêté"
        }
    }
}

/// Aperçu d'un widget vide (mode édition seulement).
struct PlaceholderCard: View {
    let kind: WidgetKind
    let text: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: kind.symbol)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(kind.activityKind?.tint ?? .white)
                .frame(width: 42, height: 42)
                .background(Circle().fill(.white.opacity(0.12)))
            VStack(alignment: .leading, spacing: 1) {
                Text(kind.title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                Text(text)
                    .font(.system(size: 12.5))
                    .foregroundStyle(.white.opacity(0.65))
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(width: 380)
        .shadow(color: .black.opacity(0.4), radius: 4, y: 1)
        .glassEffect(.clear, in: .rect(cornerRadius: 24))
    }
}

/// Le « fantôme » : pendant un glisser, une forme vide apparaît exactement là où le widget va se poser.
/// Rien d'autre n'est dessiné (pas de crans permanents, pas de texte).
struct SlotGuidesView: View {
    let core: AppCore
    let screenFrame: NSRect

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let r = core.ui.dropPreview {
                RoundedRectangle(cornerRadius: 26, style: .continuous)
                    .fill(.white.opacity(0.10))
                    .overlay(
                        RoundedRectangle(cornerRadius: 26, style: .continuous)
                            .strokeBorder(.white.opacity(0.45), lineWidth: 1.5)
                    )
                    .padding(WidgetLayoutStore.shadowMargin) // même marge que les widgets
                    .frame(width: r.width, height: r.height)
                    // Coordonnées écran (origine en bas) → vue (origine en haut).
                    .offset(x: r.minX - screenFrame.minX, y: screenFrame.maxY - r.maxY)
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
            }
        }
        .frame(width: screenFrame.width, height: screenFrame.height, alignment: .topLeading)
        .animation(.spring(duration: 0.3, bounce: 0.2), value: core.ui.dropPreview)
        .allowsHitTesting(false)
    }
}

/// Barre du mode édition : widgets retirés à rajouter, et « Terminé ».
struct WidgetGalleryBar: View {
    let core: AppCore

    var body: some View {
        HStack(spacing: 10) {
            let hidden = core.layout.disabledKinds
            if hidden.isEmpty {
                Text("Glisse un widget pour le déplacer")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white.opacity(0.75))
                    .padding(.horizontal, 8)
            } else {
                ForEach(hidden) { kind in
                    Button {
                        withAnimation(.spring(duration: 0.3)) { core.layout.setEnabled(kind, true) }
                    } label: {
                        Label(kind.title, systemImage: "plus")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 14)
                            .frame(height: 34)
                            .glassEffect(.regular.interactive(), in: .capsule)
                    }
                    .buttonStyle(.plain)
                    .help("Ajouter le widget \(kind.title)")
                }
            }

            Button {
                core.toggleWidgetEditing()
            } label: {
                Text("Terminé")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 18)
                    .frame(height: 34)
                    .background(Capsule().fill(.white))
            }
            .buttonStyle(PressScaleStyle())
        }
        .padding(8)
        .catchesClicks(cornerRadius: 30)
        .glassEffect(.regular, in: .capsule)
        .padding(24)
        .fixedSize()
        .onGeometryChange(for: CGSize.self) { $0.size } action: { size in
            core.overlay.gallerySizeChanged(size)
        }
        .environment(\.colorScheme, .dark)
    }
}

extension View {
    /// Fond quasi invisible (opacité ~1 %) : la fenêtre reçoit alors les clics sur toute la carte,
    /// même là où le verre est totalement transparent, sans toucher aux marges autour.
    func catchesClicks(cornerRadius: CGFloat) -> some View {
        background(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).fill(.black.opacity(0.012)))
    }
}

/// Menu du clic droit (ou clic à deux doigts) sur un widget : ses réglages.
struct WidgetSettingsMenu: View {
    let core: AppCore
    let kind: WidgetKind

    var body: some View {
        Text(kind.title)

        if !kind.availableSizes.isEmpty {
            Picker("Taille", selection: Binding(
                get: { core.layout.size(of: kind) },
                set: { core.layout.setSize($0, for: kind) }
            )) {
                ForEach(kind.availableSizes, id: \.self) { size in
                    Text(size.title).tag(size)
                }
            }
            .pickerStyle(.inline)
        }

        if kind == .worldClocks {
            Menu("Villes affichées") {
                if core.worldClocks.cities.isEmpty {
                    Text("Aucune ville disponible")
                }
                ForEach(core.worldClocks.cities) { city in
                    Toggle(city.name, isOn: Binding(
                        get: { core.layout.isCityShown(city.id) },
                        set: { core.layout.setCity(city.id, shown: $0) }
                    ))
                }
            }
            Button("Ajouter des villes dans Horloge…") { ClockStore.openClockApp() }
        }

        if kind.activityKind != nil {
            Button("Ouvrir Horloge") { ClockStore.openClockApp() }
        }

        Divider()

        Button(core.ui.editingWidgets ? "Terminer la modification" : "Modifier les widgets…") {
            core.toggleWidgetEditing()
        }
        Button("Retirer le widget", role: .destructive) {
            core.layout.setEnabled(kind, false)
        }
    }
}
