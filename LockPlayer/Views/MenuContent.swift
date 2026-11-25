import SwiftUI

struct MenuContent: View {
    @Bindable var core: AppCore

    var body: some View {
        Button(core.ui.editingWidgets ? "Terminer la modification" : "Modifier les widgets…") {
            core.toggleWidgetEditing()
        }
        .keyboardShortcut("e")

        Toggle("Garder l'écran allumé (musique, minuteurs)", isOn: $core.keepScreenOn)

        if core.layout.isEnabled(.worldClocks) && !core.worldClocks.isAvailable {
            Text("Villes d'Horloge inaccessibles : ajoute LockPlayer dans Accès complet au disque")
        }

        Divider()

        Button("Quitter LockPlayer") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}
