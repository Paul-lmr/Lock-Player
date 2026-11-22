import AppKit
import Observation
import ServiceManagement
import SwiftUI

/// Où le mini-lecteur apparaît sur l'écran verrouillé.
enum MiniPosition: String, CaseIterable, Identifiable {
    case underClock
    case aboveLogin
    case bottomLeft
    case bottomRight

    var id: String { rawValue }

    var label: String {
        switch self {
        case .underClock: "Sous l'horloge"
        case .aboveLogin: "Au-dessus du mot de passe"
        case .bottomLeft: "En bas à gauche"
        case .bottomRight: "En bas à droite"
        }
    }
}

/// État d'affichage partagé par les vues de l'overlay.
@MainActor
@Observable
final class OverlayUIState {
    var expanded = false
    var showLyrics = false
    var isPreview = false
}

@MainActor
@Observable
final class AppCore {
    static let shared = AppCore()

    let model = NowPlaying()
    let lyrics = LyricsStore()
    let ui = OverlayUIState()
    let audio = AudioLevels()

    var position: MiniPosition {
        didSet {
            UserDefaults.standard.set(position.rawValue, forKey: "miniPosition")
            overlay.relayout()
        }
    }

    var launchAtLogin: Bool = SMAppService.mainApp.status == .enabled

    /// Garder l'écran allumé tant que la musique joue sur l'écran verrouillé.
    var keepScreenOn: Bool {
        didSet { UserDefaults.standard.set(keepScreenOn, forKey: "keepScreenOn") }
    }

    /// Avance (s) appliquée aux paroles : positif = les paroles arrivent plus tôt.
    var lyricsOffset: Double {
        didSet { UserDefaults.standard.set(lyricsOffset, forKey: "lyricsOffset") }
    }

    private(set) var isLocked = false
    @ObservationIgnored private let displayAwake = DisplayAwake()

    @ObservationIgnored private(set) var source: PlayerSource?
    @ObservationIgnored lazy var overlay = OverlayController(core: self)
    @ObservationIgnored private let lockMonitor = LockScreenMonitor()

    private init() {
        let saved = UserDefaults.standard.string(forKey: "miniPosition")
        position = saved.flatMap(MiniPosition.init(rawValue:)) ?? .underClock
        keepScreenOn = UserDefaults.standard.object(forKey: "keepScreenOn") as? Bool ?? true
        lyricsOffset = UserDefaults.standard.double(forKey: "lyricsOffset")
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
        lockMonitor.start()
        overlay.start()

        // Écran allumé seulement : verrouillé + musique en lecture + option active.
        observeChanges({ [unowned self] in self.isLocked && self.model.isPlaying && self.keepScreenOn }) { [weak self] active in
            self?.displayAwake.set(active)
        }

        // Analyse du son seulement quand le lecteur est visible et que ça joue.
        observeChanges({ [unowned self] in (self.isLocked || self.ui.isPreview) && self.model.isPlaying }) { [weak self] active in
            if active { self?.audio.start() } else { self?.audio.stop() }
        }

        // Paroles : on précharge à chaque changement de morceau.
        observeChanges({ [model] in model.trackKey }) { [weak self] _ in
            guard let self else { return }
            self.lyrics.update(
                title: self.model.title,
                artist: self.model.artist,
                album: self.model.album,
                duration: self.model.duration
            )
        }

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
        if args.contains("--preview") {
            overlay.show(.preview)
            if args.contains("--expanded") { expand(lyrics: false) }
            if args.contains("--lyrics") { expand(lyrics: true) }
        }
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
        model.sourceDescription = source?.name ?? "Aucune source"
        source?.start()
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

    func togglePreview() {
        if overlay.mode == .preview {
            overlay.hide()
        } else {
            overlay.show(.preview)
        }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            NSLog("LockPlayer: launch at login error \(error)")
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
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
