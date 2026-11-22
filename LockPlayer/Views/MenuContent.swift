import SwiftUI

struct MenuContent: View {
    @Bindable var core: AppCore

    var body: some View {
        if core.model.hasTrack {
            Text("\(core.model.isPlaying ? "▶︎" : "❚❚")  \(core.model.title) — \(core.model.artist)")
        } else {
            Text("Aucune musique en cours")
        }
        Text("Source : \(core.model.sourceDescription)")

        Divider()

        Button(core.ui.isPreview ? "Fermer l'aperçu" : "Aperçu de l'écran verrouillé") {
            core.togglePreview()
        }
        .keyboardShortcut("p")

        Button(core.ui.showcase ? "Fermer le mode vitrine" : "Mode vitrine (captures d'écran)") {
            core.toggleShowcase()
        }

        Picker("Position du lecteur", selection: $core.position) {
            ForEach(MiniPosition.allCases) { position in
                Text(position.label).tag(position)
            }
        }

        Picker("Synchro des paroles", selection: $core.lyricsOffset) {
            Text("1 s plus tard").tag(-1.0)
            Text("0,5 s plus tard").tag(-0.5)
            Text("Normal").tag(0.0)
            Text("0,5 s plus tôt").tag(0.5)
            Text("1 s plus tôt").tag(1.0)
        }

        Toggle("Garder l'écran allumé pendant la musique", isOn: $core.keepScreenOn)

        Toggle("Lancer au démarrage", isOn: Binding(
            get: { core.launchAtLogin },
            set: { core.setLaunchAtLogin($0) }
        ))

        Divider()

        Button("Quitter LockPlayer") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}
