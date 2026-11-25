import AppKit
import Observation
import ServiceManagement
import SwiftUI

/// État d'affichage partagé par les vues de l'overlay.
@MainActor
@Observable
final class OverlayUIState {
    var expanded = false
    var showLyrics = false
    var isPreview = false
    /// Faux écran verrouillé (fond d'écran + horloge, sans profil) pour faire des captures.
    var showcase = false
    /// Mode « Modifier les widgets » : on glisse les widgets, galerie en bas.
    var editingWidgets = false
    /// Cran visé pendant un glisser.
    var dropTarget: SnapSlot?
    /// Emplacement exact où le widget glissé va atterrir (coordonnées écran) : le « fantôme ».
    var dropPreview: CGRect?
}

@MainActor
@Observable
final class AppCore {
    static let shared = AppCore()

    let model = NowPlaying()
    let lyrics = LyricsStore()
    let ui = OverlayUIState()
    let audio = AudioLevels()
    let clock = ClockStore()
    let worldClocks = WorldClockStore()
    /// Où chaque widget est placé (crans), et lesquels sont affichés.
    let layout = WidgetLayoutStore()

    /// Villes d'Horloge affichées dans le widget (sans celles masquées au clic droit).
    var shownWorldCities: [WorldCity] {
        worldClocks.cities.filter { layout.isCityShown($0.id) }
    }


    /// Garder l'écran allumé tant que la musique ou un minuteur tourne sur l'écran verrouillé.
    var keepScreenOn: Bool {
        didSet { UserDefaults.standard.set(keepScreenOn, forKey: "keepScreenOn") }
    }

    private(set) var isLocked = false
    @ObservationIgnored private let displayAwake = DisplayAwake()

    @ObservationIgnored private(set) var source: PlayerSource?
    @ObservationIgnored lazy var overlay = OverlayController(core: self)
    @ObservationIgnored private let lockMonitor = LockScreenMonitor()

    private init() {
        keepScreenOn = UserDefaults.standard.object(forKey: "keepScreenOn") as? Bool ?? true
    }

    func start() {
        lockMonitor.onLock = { [weak self] in
            self?.isLocked = true
            self?.overlay.show(.locked)
        }
        lockMonitor.onUnlock = { [weak self] in
            guard let self else { return }
            self.isLocked = false
            if self.overlay.mode == .locked { self.overlay.hide() }
        }
        ensureLaunchAtLogin()
        lockMonitor.start()
        overlay.start()

        // Écran allumé seulement : verrouillé + (musique ou activité en cours) + option active.
        observeChanges({ [unowned self] in
            self.isLocked && self.keepScreenOn && (self.model.isPlaying || self.clock.hasRunningTimers)
        }) { [weak self] active in
            self?.displayAwake.set(active)
        }

        // Analyse du son seulement quand le lecteur est visible et que ça joue.
        // (pas en mode vitrine : évite le voyant d'enregistrement audio sur les captures)
        observeChanges({ [unowned self] in (self.isLocked || (self.ui.isPreview && !self.ui.showcase)) && self.model.isPlaying }) { [weak self] active in
            if active { self?.audio.start() } else { self?.audio.stop() }
        }

        // Paroles : préchargées à chaque changement de morceau, seulement si les widgets sont affichés.
        observeChanges({ [model] in model.trackKey }) { [weak self] _ in
            guard let self, self.overlayActive else { return }
            self.prefetchLyrics()
        }

        // Minuteurs, alarmes et chronomètres de l'app Horloge.
        // Quand ça sonne sur l'écran verrouillé : on revient à la vue compacte pour voir la carte.
        clock.onRing = { [weak self] in
            guard let self, self.isLocked else { return }
            self.collapse()
        }
        clock.start()
        worldClocks.start()

        Task { await chooseSource() }

        // App lancée alors que la session est déjà verrouillée.
        if let session = CGSessionCopyCurrentDictionary() as? [String: Any],
           session["CGSSessionScreenIsLocked"] as? Bool == true {
            isLocked = true
            overlay.show(.locked)
            return
        }

        // Pour tester sans verrouiller : open LockPlayer.app --args --preview [--expanded|--lyrics]
        let args = CommandLine.arguments
        if args.contains("--edit-widgets") {
            toggleWidgetEditing()
        } else if args.contains("--showcase") {
            toggleShowcase()
        } else if args.contains("--preview") {
            overlay.show(.preview)
        }
        if args.contains("--preview") || args.contains("--showcase") {
            if args.contains("--expanded") { expand(lyrics: false) }
            if args.contains("--lyrics") { expand(lyrics: true) }
        }
    }

    /// Widgets à l'écran ou non : c'est là qu'on allume ou coupe tout le travail de fond.
    @ObservationIgnored private(set) var overlayActive = false

    func overlayDidChange(active: Bool) {
        guard active != overlayActive else { return }
        overlayActive = active
        clock.setActive(active)
        worldClocks.setActive(active)
        source?.setForeground(active)
        if active { prefetchLyrics() }
    }

    private func prefetchLyrics() {
        lyrics.update(title: model.title, artist: model.artist, album: model.album, duration: model.duration)
    }

    func stop() {
        source?.stop()
        overlay.hide()
    }

    /// MediaRemote (via /usr/bin/perl) si le test passe, sinon AppleScript Spotify.
    private func chooseSource() async {
        if let paths = AdapterPaths.bundled(), await paths.isWorking() {
            source = MediaRemoteSource(paths: paths, model: model)
        } else {
            source = SpotifyScriptSource(model: model)
        }
        source?.start()
        source?.setForeground(overlayActive)
    }

    // MARK: - Commandes

    func togglePlayPause() { source?.togglePlayPause() }
    func next() { source?.next() }
    func previous() { source?.previous() }
    func seek(to seconds: Double) { source?.seek(to: seconds) }

    func expand(lyrics: Bool) {
        withAnimation(.spring(duration: 0.45)) {
            ui.showLyrics = lyrics
            ui.expanded = true
        }
    }

    func collapse() {
        ui.expanded = false
        ui.showLyrics = false
    }

    func toggleShowcase() {
        if ui.showcase {
            overlay.hide()
        } else {
            overlay.show(.preview)
            ui.showcase = true
            overlay.relayout()
        }
    }

    /// Mode « Modifier les widgets » (session ouverte) : faux écran verrouillé, crans visibles, galerie.
    func toggleWidgetEditing() {
        if ui.editingWidgets {
            overlay.hide()
        } else {
            collapse()
            overlay.show(.preview)
            ui.showcase = true
            ui.editingWidgets = true
            overlay.relayout()
        }
    }

    func togglePreview() {
        if overlay.mode == .preview {
            overlay.hide()
        } else {
            overlay.show(.preview)
        }
    }

    /// Toujours lancée à l'ouverture de session (plus d'interrupteur dans le menu).
    /// Seulement pour la version installée dans /Applications, pas pour les compilations de test.
    private func ensureLaunchAtLogin() {
        guard Bundle.main.bundlePath.hasPrefix("/Applications/"),
              SMAppService.mainApp.status != .enabled else { return }
        do {
            try SMAppService.mainApp.register()
        } catch {
            NSLog("LockPlayer: lancement au démarrage impossible: \(error)")
        }
    }
}

/// Rappelle `onChange` à chaque modification observée de `value`.
@MainActor
func observeChanges<T>(_ value: @escaping @MainActor () -> T, onChange: @escaping @MainActor (T) -> Void) {
    withObservationTracking {
        _ = value()
    } onChange: {
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                onChange(value())
                observeChanges(value, onChange: onChange)
            }
        }
    }
}
