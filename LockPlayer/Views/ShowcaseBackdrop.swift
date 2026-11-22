import AppKit
import SwiftUI

/// Faux écran verrouillé pour les captures : fond d'écran + horloge, sans nom ni photo de profil.
/// Un clic sur le fond referme le mode vitrine.
struct ShowcaseBackdrop: View {
    let onClose: () -> Void

    private let wallpaper: NSImage? = NSScreen.screens.first
        .flatMap { NSWorkspace.shared.desktopImageURL(for: $0) }
        .flatMap(NSImage.init(contentsOf:))

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .top) {
                Group {
                    if let wallpaper {
                        Image(nsImage: wallpaper)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    } else {
                        LinearGradient(colors: [Color(red: 0.11, green: 0.16, blue: 0.31), Color(red: 0.03, green: 0.05, blue: 0.11)],
                                       startPoint: .top, endPoint: .bottom)
                    }
                }
                .frame(width: geo.size.width, height: geo.size.height)
                .clipped()
                .contentShape(Rectangle())
                .onTapGesture(perform: onClose)

                TimelineView(.everyMinute) { context in
                    VStack(spacing: -6) {
                        Text(context.date, format: .dateTime.weekday(.wide).day().month(.wide))
                            .font(.system(size: 24, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.85))
                        Text(context.date, format: .dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))
                            .font(.system(size: 118, weight: .bold, design: .rounded).monospacedDigit())
                            .foregroundStyle(.white.opacity(0.72))
                    }
                    .shadow(color: .black.opacity(0.15), radius: 10, y: 2)
                    .environment(\.locale, Locale(identifier: "fr_FR"))
                    .allowsHitTesting(false)
                }
                .padding(.top, geo.size.height * 0.07)
            }
        }
        .ignoresSafeArea()
    }
}
