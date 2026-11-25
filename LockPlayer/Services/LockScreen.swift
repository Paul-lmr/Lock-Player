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
        // macOS laisse passer les clics sur les pixels totalement transparents : c'est voulu pour
        // les marges d'ombre. Les cartes en verre ont un fond quasi invisible (`.catchesClicks`)
        // pour rester attrapables.
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

    /// Un panneau par widget, placés indépendamment sur les crans.
    private var widgetPanels: [WidgetKind: OverlayPanel] = [:]
    private var sizes: [WidgetKind: CGSize] = [:]
    private var expandedPanel: OverlayPanel?
    private var backdropPanel: OverlayPanel?
    private var guidesPanel: OverlayPanel?
    private var galleryPanel: OverlayPanel?

    private var dragging: WidgetKind?
    private var grabOffset = NSPoint.zero

    init(core: AppCore) {
        self.core = core
    }

    func start() {
        observeChanges({ [core] in
            (core.ui.expanded, core.ui.editingWidgets, core.model.hasTrack,
             core.clock.lockScreenItems.map(\.kind.rawValue), core.shownWorldCities.isEmpty,
             core.layout.placements.map { "\($0.key.rawValue)\($0.value.slot.rawValue)\($0.value.order)\($0.value.enabled)" })
        }) { [weak self] _ in
            self?.refresh()
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.relayout() }
        }
    }

    func show(_ newMode: Mode) {
        teardown()
        mode = newMode
        core.ui.isPreview = newMode == .preview
        refresh()
    }

    func hide() {
        teardown()
    }

    private func teardown() {
        closeWidgets()
        closeExpanded()
        closeBackdrop()
        closeEditChrome()
        core.collapse()
        core.ui.isPreview = false
        core.ui.showcase = false
        core.ui.editingWidgets = false
        core.ui.dropTarget = nil
        core.ui.dropPreview = nil
        dragging = nil
        mode = .hidden
    }

    func relayout() {
        guard mode != .hidden else { return }
        closeWidgets()
        closeExpanded()
        closeBackdrop()
        closeEditChrome()
        refresh()
    }

    private var screen: NSScreen? { NSScreen.screens.first }

    // MARK: - Affichage

    private func shouldShow(_ kind: WidgetKind) -> Bool {
        guard core.layout.isEnabled(kind) else { return false }
        if core.ui.editingWidgets { return true }
        switch kind {
        case .music:
            return core.model.hasTrack || (mode == .preview && !WidgetKind.allCases.contains { $0 != .music && hasContent($0) })
        default:
            return hasContent(kind)
        }
    }

    private func hasContent(_ kind: WidgetKind) -> Bool {
        guard core.layout.isEnabled(kind) else { return false }
        switch kind {
        case .music: return core.model.hasTrack
        case .worldClocks: return !core.shownWorldCities.isEmpty
        default: return kind.activityKind.map { !core.clock.items(of: $0).isEmpty } ?? false
        }
    }

    private func refresh() {
        guard mode != .hidden, let screen else { return }

        if core.ui.showcase, backdropPanel == nil {
            let panel = makePanel(ShowcaseBackdrop { [weak core] in
                // En mode édition, un clic dans le vide ne ferme rien.
                guard let core, !core.ui.editingWidgets else { return }
                core.toggleShowcase()
            }, frame: screen.frame)
            panel.level = NSWindow.Level(rawValue: Int(Int32.max - 4)) // tout au fond
            backdropPanel = panel
        }

        if core.ui.expanded {
            if expandedPanel == nil {
                expandedPanel = makePanel(ExpandedPlayerView(core: core), frame: screen.frame)
            }
            widgetPanels.values.forEach { $0.orderOut(nil) }
            return
        }
        closeExpanded()

        for kind in WidgetKind.allCases {
            if shouldShow(kind) {
                if let panel = widgetPanels[kind] {
                    panel.orderFrontRegardless()
                } else {
                    let host = FirstMouseHostingView(rootView: AnyView(WidgetContainer(core: core, kind: kind).environment(\.colorScheme, .dark)))
                    sizes[kind] = host.fittingSize
                    widgetPanels[kind] = makePanel(host: host, frame: NSRect(origin: .zero, size: host.fittingSize))
                }
            } else if let panel = widgetPanels.removeValue(forKey: kind) {
                panel.close()
                sizes[kind] = nil
            }
        }

        if core.ui.editingWidgets {
            if galleryPanel == nil {
                let host = FirstMouseHostingView(rootView: AnyView(WidgetGalleryBar(core: core)))
                galleryPanel = makePanel(host: host, frame: galleryFrame(size: host.fittingSize, on: screen))
            }
        } else if dragging == nil {
            closeGallery()
        }

        layoutWidgets(animated: false)
    }

    /// Place tous les widgets sur leurs crans (sauf celui qu'on est en train de glisser).
    private func layoutWidgets(animated: Bool) {
        guard let screen else { return }
        let frames = core.layout.frames(sizes: sizes, visible: Array(widgetPanels.keys), in: screen.frame)
        for (kind, panel) in widgetPanels where kind != dragging {
            guard let frame = frames[kind] else { continue }
            let current = panel.frame
            guard abs(current.minX - frame.minX) > 0.5 || abs(current.minY - frame.minY) > 0.5
                || abs(current.width - frame.width) > 0.5 || abs(current.height - frame.height) > 0.5 else { continue }
            if animated {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.28
                    context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                    panel.animator().setFrame(frame, display: true)
                }
            } else {
                panel.setFrame(frame, display: true)
            }
        }
    }

    /// Un widget a changé de taille (une carte de plus, une de moins…).
    func contentSizeChanged(_ size: CGSize, for kind: WidgetKind) {
        guard size.width > 0, size.height > 0 else { return }
        sizes[kind] = size
        if kind == dragging, let panel = widgetPanels[kind] {
            panel.setFrame(NSRect(origin: panel.frame.origin, size: size), display: true)
        }
        layoutWidgets(animated: false)
    }

    // MARK: - Glisser-déposer

    func beginDrag(_ kind: WidgetKind) {
        guard let panel = widgetPanels[kind] else { return }
        dragging = kind
        let mouse = NSEvent.mouseLocation
        grabOffset = NSPoint(x: mouse.x - panel.frame.minX, y: mouse.y - panel.frame.minY)
        panel.orderFrontRegardless()
        showGuides()
    }

    func dragMoved(_ kind: WidgetKind) {
        guard dragging == kind, let panel = widgetPanels[kind], let screen else { return }
        let mouse = NSEvent.mouseLocation
        panel.setFrameOrigin(NSPoint(x: mouse.x - grabOffset.x, y: mouse.y - grabOffset.y))
        let (slot, index) = dropPosition(of: kind, panel: panel, screen: screen)
        if core.ui.dropTarget != slot { core.ui.dropTarget = slot }
        let landing = core.layout.landingFrame(of: kind, slot: slot, index: index, sizes: sizes,
                                               visible: Array(widgetPanels.keys), in: screen.frame)
        if core.ui.dropPreview != landing { core.ui.dropPreview = landing }
    }

    /// Cran le plus proche, et rang dans sa pile selon la hauteur du widget glissé.
    private func dropPosition(of kind: WidgetKind, panel: OverlayPanel, screen: NSScreen) -> (SnapSlot, Int) {
        let center = NSPoint(x: panel.frame.midX, y: panel.frame.midY)
        let slot = core.layout.nearestSlot(to: center, size: panel.frame.size, in: screen.frame)
        let above = widgetPanels.filter { other, otherPanel in
            other != kind && core.layout.placement(other).slot == slot && otherPanel.frame.midY > center.y
        }.count
        return (slot, above)
    }

    func endDrag(_ kind: WidgetKind) {
        guard dragging == kind, let panel = widgetPanels[kind], let screen else {
            dragging = nil
            return
        }
        let (slot, above) = dropPosition(of: kind, panel: panel, screen: screen)
        dragging = nil
        core.ui.dropTarget = nil
        core.ui.dropPreview = nil
        core.layout.move(kind, to: slot, index: above, among: Array(widgetPanels.keys))
        closeGuides()
        layoutWidgets(animated: true)
    }

    // MARK: - Mode édition : guides et galerie

    private func showGuides() {
        guard guidesPanel == nil, let screen else { return }
        let panel = makePanel(SlotGuidesView(core: core, screenFrame: screen.frame), frame: screen.frame)
        panel.ignoresMouseEvents = true
        panel.level = NSWindow.Level(rawValue: Int(Int32.max - 3)) // sous les widgets
        guidesPanel = panel
    }

    func gallerySizeChanged(_ size: CGSize) {
        guard let screen, let panel = galleryPanel, size.width > 0 else { return }
        let frame = galleryFrame(size: size, on: screen)
        if panel.frame != frame { panel.setFrame(frame, display: true) }
    }

    private func galleryFrame(size: NSSize, on screen: NSScreen) -> NSRect {
        let f = screen.frame
        return NSRect(x: f.midX - size.width / 2, y: f.minY + 4, width: size.width, height: size.height)
    }

    private func closeEditChrome() {
        closeGuides()
        closeGallery()
    }

    private func closeGuides() {
        guidesPanel?.close()
        guidesPanel = nil
    }

    private func closeGallery() {
        galleryPanel?.close()
        galleryPanel = nil
    }

    // MARK: - Panneaux

    private func makePanel(_ view: some View, frame: NSRect) -> OverlayPanel {
        let host = FirstMouseHostingView(rootView: AnyView(view.environment(\.colorScheme, .dark)))
        return makePanel(host: host, frame: frame)
    }

    private func makePanel(host: NSView, frame: NSRect) -> OverlayPanel {
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

    private func closeWidgets() {
        widgetPanels.values.forEach { $0.close() }
        widgetPanels.removeAll()
        sizes.removeAll()
    }

    private func closeExpanded() {
        expandedPanel?.close()
        expandedPanel = nil
    }

    private func closeBackdrop() {
        backdropPanel?.close()
        backdropPanel = nil
    }
}
