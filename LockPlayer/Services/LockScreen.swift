import AppKit
import SwiftUI

/// Détecte le verrouillage / déverrouillage de la session.
@MainActor
final class LockScreenMonitor {
    var onLock: (() -> Void)?
    var onUnlock: (() -> Void)?
    private var tokens: [NSObjectProtocol] = []

    func start() {
        let center = DistributedNotificationCenter.default()
        tokens.append(center.addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.onLock?() }
        })
        tokens.append(center.addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.onUnlock?() }
        })
    }
}

/// Place des fenêtres dans un « space » SkyLight situé au-dessus de l'écran verrouillé.
/// Adapté de SkyLightWindow de Lakr Aream (licence MIT) : https://github.com/Lakr233/SkyLightWindow
@MainActor
final class SkyLight {
    static let shared = SkyLight()

    private typealias MainConnectionID = @convention(c) () -> Int32
    private typealias SpaceCreate = @convention(c) (Int32, Int32, Int32) -> Int32
    private typealias SpaceSetAbsoluteLevel = @convention(c) (Int32, Int32, Int32) -> Int32
    private typealias ShowSpaces = @convention(c) (Int32, CFArray) -> Int32
    private typealias AddWindows = @convention(c) (Int32, Int32, CFArray, Int32) -> Int32

    /// kSLSSpaceAbsoluteLevelNotificationCenterAtScreenLock (au-dessus de ScreenLock = 300).
    private static let levelAboveLockScreen: Int32 = 400

    private let connection: Int32
    private let space: Int32
    private let addWindows: AddWindows?

    private init() {
        let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/SkyLight", RTLD_NOW)
        func load<T>(_ name: String, _: T.Type) -> T? {
            guard let symbol = dlsym(handle, name) else { return nil }
            return unsafeBitCast(symbol, to: T.self)
        }
        guard let mainConnection = load("SLSMainConnectionID", MainConnectionID.self),
              let spaceCreate = load("SLSSpaceCreate", SpaceCreate.self),
              let setLevel = load("SLSSpaceSetAbsoluteLevel", SpaceSetAbsoluteLevel.self),
              let showSpaces = load("SLSShowSpaces", ShowSpaces.self) else {
            NSLog("LockPlayer: SkyLight indisponible")
            connection = 0
            space = 0
            addWindows = nil
            return
        }
        addWindows = load("SLSSpaceAddWindowsAndRemoveFromSpaces", AddWindows.self)
        connection = mainConnection()
        space = spaceCreate(connection, 1, 0)
        _ = setLevel(connection, space, Self.levelAboveLockScreen)
        _ = showSpaces(connection, [space] as CFArray)
    }

    func delegate(_ window: NSWindow) {
        guard let addWindows, space != 0 else { return }
        _ = addWindows(connection, space, [window.windowNumber] as CFArray, 7)
    }
}

/// Panneau transparent qui ne prend jamais le focus clavier :
/// le champ mot de passe de l'écran verrouillé reste utilisable.
final class OverlayPanel: NSPanel {
    init(frame: NSRect) {
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovable = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        canBecomeVisibleWithoutLogin = true
        level = NSWindow.Level(rawValue: Int(Int32.max - 2))
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        animationBehavior = .none
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    // Méthodes privées d'AppKit : dessiner le panneau avec l'apparence « active »
    // (verre transparent) sans jamais lui donner le focus clavier.
    @objc func _hasActiveAppearance() -> Bool { true }
    @objc func _hasActiveAppearanceIgnoringKeyFocus() -> Bool { true }
    @objc func _hasKeyAppearance() -> Bool { true }
}

/// Les clics fonctionnent dès le premier coup, même si la fenêtre n'est pas active.
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

@MainActor
final class OverlayController {
    enum Mode { case hidden, locked, preview }

    private(set) var mode: Mode = .hidden
    private unowned let core: AppCore
    private var miniPanel: OverlayPanel?
    private var expandedPanel: OverlayPanel?

    init(core: AppCore) {
        self.core = core
    }

    func start() {
        observeChanges({ [core] in (core.ui.expanded, core.model.hasTrack) }) { [weak self] _ in
            self?.refresh()
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.relayout() }
        }
    }

    func show(_ newMode: Mode) {
        hide()
        mode = newMode
        core.ui.isPreview = newMode == .preview
        refresh()
    }

    func hide() {
        closeMini()
        closeExpanded()
        closeBackdrop()
        core.collapse()
        core.ui.isPreview = false
        core.ui.showcase = false
        mode = .hidden
    }

    func relayout() {
        guard mode != .hidden else { return }
        closeMini()
        closeExpanded()
        closeBackdrop()
        refresh()
    }

    private var screen: NSScreen? { NSScreen.screens.first }
    private var backdropPanel: OverlayPanel?

    private func closeBackdrop() {
        backdropPanel?.close()
        backdropPanel = nil
    }

    private func refresh() {
        guard mode != .hidden, let screen else { return }

        if core.ui.showcase, backdropPanel == nil {
            let panel = makePanel(ShowcaseBackdrop { [weak core] in core?.toggleShowcase() }, frame: screen.frame)
            panel.level = NSWindow.Level(rawValue: Int(Int32.max - 3)) // sous le lecteur
            backdropPanel = panel
        }

        if core.ui.expanded {
            if expandedPanel == nil {
                expandedPanel = makePanel(ExpandedPlayerView(core: core), frame: screen.frame)
            }
            miniPanel?.orderOut(nil)
            return
        }

        closeExpanded()
        let shouldShowMini = core.model.hasTrack || mode == .preview
        if shouldShowMini {
            if miniPanel == nil {
                miniPanel = makePanel(MiniPlayerView(core: core), frame: .zero, sizeToFit: true, on: screen)
            }
            miniPanel?.orderFrontRegardless()
        } else {
            miniPanel?.orderOut(nil)
        }
    }

    private func makePanel(_ view: some View, frame: NSRect, sizeToFit: Bool = false, on screen: NSScreen? = nil) -> OverlayPanel {
        let host = FirstMouseHostingView(rootView: AnyView(view.environment(\.colorScheme, .dark)))
        var frame = frame
        if sizeToFit, let screen {
            frame = miniFrame(size: host.fittingSize, on: screen)
        }
        let panel = OverlayPanel(frame: frame)
        host.frame = NSRect(origin: .zero, size: frame.size)
        host.autoresizingMask = [.width, .height]
        panel.contentView = host
        if mode == .locked {
            SkyLight.shared.delegate(panel)
        }
        panel.orderFrontRegardless()
        return panel
    }

    private func miniFrame(size: NSSize, on screen: NSScreen) -> NSRect {
        let f = screen.frame
        let margin: CGFloat = 36
        let origin: NSPoint
        switch core.position {
        case .underClock:
            origin = NSPoint(x: f.midX - size.width / 2, y: f.maxY - f.height * 0.30 - size.height)
        case .aboveLogin:
            origin = NSPoint(x: f.midX - size.width / 2, y: f.minY + f.height * 0.24)
        case .bottomLeft:
            origin = NSPoint(x: f.minX + margin, y: f.minY + margin)
        case .bottomRight:
            origin = NSPoint(x: f.maxX - size.width - margin, y: f.minY + margin)
        }
        return NSRect(origin: origin, size: size)
    }

    private func closeMini() {
        miniPanel?.close()
        miniPanel = nil
    }

    private func closeExpanded() {
        expandedPanel?.close()
        expandedPanel = nil
    }
}
