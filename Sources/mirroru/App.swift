import AppKit
import AVFoundation
import QuartzCore
import SwiftUI

struct AppOptions {
    var deviceFilter: String?
    var demo = false
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let options: AppOptions
    private var controllers: [String: MirrorWindowController] = [:]
    private var dismissed = Set<String>()
    private var waitingWindow: NSWindow?
    private var timer: Timer?
    private var refreshing = false

    init(options: AppOptions) {
        self.options = options
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()
        if let icon = appIcon() { NSApp.applicationIconImage = icon }
        IOSDevices.enableScreenCapture()
        showWaiting()
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.refresh() }
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// Works both inside Mirroru.app (also through a symlink) and from `swift run`.
    private func appIcon() -> NSImage? {
        let executable = URL(fileURLWithPath: Bundle.main.executablePath ?? CommandLine.arguments[0]).resolvingSymlinksInPath()
        let bundled = executable.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources/AppIcon.icns")
        return NSImage(contentsOf: bundled)
    }

    private func refresh() {
        guard !refreshing else { return }
        refreshing = true
        let demo = options.demo
        DispatchQueue.global(qos: .userInitiated).async {
            let android = demo ? [] : ADB.devices().filter(\.ready)
            DispatchQueue.main.async {
                self.refreshing = false
                self.apply(demo ? [Device.demo] : android + IOSDevices.list())
            }
        }
    }

    private func apply(_ all: [Device]) {
        let devices = all.filter { device in options.deviceFilter.map(device.matches) ?? true }
        dismissed.formIntersection(devices.map(\.id))
        for device in devices where controllers[device.id] == nil && !dismissed.contains(device.id) {
            guard let source = makeSource(for: device) else { continue }
            let controller = MirrorWindowController(device: device, source: source)
            controller.onClose = { [weak self] byUser in self?.closed(device.id, byUser: byUser) }
            controllers[device.id] = controller
            controller.show()
        }
        if !controllers.isEmpty {
            waitingWindow?.orderOut(nil)
            waitingWindow = nil
        }
    }

    private func closed(_ id: String, byUser: Bool) {
        controllers[id] = nil
        if byUser {
            dismissed.insert(id)
        } else if controllers.isEmpty {
            showWaiting()
        }
    }

    private func showWaiting() {
        guard waitingWindow == nil else { return }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: 190),
                              styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Mirroru"
        window.isReleasedWhenClosed = false
        let symbol = NSImageView(image: NSImage(systemSymbolName: "cable.connector", accessibilityDescription: nil) ?? NSImage())
        symbol.symbolConfiguration = .init(pointSize: 34, weight: .light)
        symbol.contentTintColor = .secondaryLabelColor
        let title = NSTextField(labelWithString: "Esperando un dispositivo…")
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        let hint = NSTextField(wrappingLabelWithString:
            "Conecta tu teléfono por USB.\niPhone: desbloquéalo y pulsa «Confiar».\nAndroid: activa la depuración USB.")
        hint.alignment = .center
        hint.textColor = .secondaryLabelColor
        hint.font = .systemFont(ofSize: 12)
        let stack = NSStackView(views: [symbol, title, hint])
        stack.orientation = .vertical
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 24, bottom: 20, right: 24)
        window.contentView = stack
        window.center()
        window.makeKeyAndOrderFront(nil)
        waitingWindow = window
    }

    private func buildMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Ocultar Mirroru", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Salir de Mirroru", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        func item(_ title: String, _ action: Selector, _ key: String, shift: Bool = false) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = shift ? [.command, .shift] : [.command]
            return item
        }

        let fileItem = NSMenuItem()
        let fileMenu = NSMenu(title: "Archivo")
        fileMenu.addItem(item("Guardar captura", #selector(MirrorWindowController.takeScreenshot), "s"))
        fileMenu.addItem(item("Grabar video / Detener", #selector(MirrorWindowController.toggleRecording), "r"))
        fileMenu.addItem(item("Grabar GIF / Detener", #selector(MirrorWindowController.toggleGif), "g"))
        fileMenu.addItem(.separator())
        fileMenu.addItem(item("Cerrar ventana", #selector(NSWindow.performClose(_:)), "w"))
        fileItem.submenu = fileMenu
        main.addItem(fileItem)

        let privacyItem = NSMenuItem()
        let privacyMenu = NSMenu(title: "Privacidad")
        privacyMenu.addItem(item("Ocultar / Mostrar todo", #selector(MirrorWindowController.togglePrivacy), "p"))
        privacyMenu.addItem(item("Elegir app…", #selector(MirrorWindowController.chooseApp), "k"))
        privacyMenu.addItem(.separator())
        let startItem = NSMenuItem(title: "Iniciar en modo privado", action: #selector(toggleStartPrivate(_:)), keyEquivalent: "")
        startItem.target = self
        privacyMenu.addItem(startItem)
        privacyItem.submenu = privacyMenu
        main.addItem(privacyItem)

        let deviceItem = NSMenuItem()
        let deviceMenu = NSMenu(title: "Dispositivo")
        deviceMenu.addItem(item("Inicio", #selector(MirrorWindowController.pressHome), "h", shift: true))
        deviceMenu.addItem(item("Atrás", #selector(MirrorWindowController.pressBack), "b", shift: true))
        deviceMenu.addItem(item("Apps recientes", #selector(MirrorWindowController.pressRecents), "a", shift: true))
        deviceMenu.addItem(.separator())
        deviceMenu.addItem(item("Bloquear", #selector(MirrorWindowController.pressPower), "l"))
        deviceMenu.addItem(item("Subir volumen", #selector(MirrorWindowController.pressVolumeUp), String(UnicodeScalar(NSUpArrowFunctionKey)!)))
        deviceMenu.addItem(item("Bajar volumen", #selector(MirrorWindowController.pressVolumeDown), String(UnicodeScalar(NSDownArrowFunctionKey)!)))
        deviceItem.submenu = deviceMenu
        main.addItem(deviceItem)

        NSApp.mainMenu = main
    }
}

extension AppDelegate: NSMenuItemValidation {
    /// New windows start blurred unless the user turned this off.
    static var startPrivate: Bool {
        get { UserDefaults.standard.object(forKey: "startPrivate") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "startPrivate") }
    }

    @objc func toggleStartPrivate(_ sender: NSMenuItem) {
        Self.startPrivate.toggle()
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(toggleStartPrivate(_:)) { menuItem.state = Self.startPrivate ? .on : .off }
        return true
    }
}

// MARK: - Window

private extension NSToolbarItem.Identifier {
    static let title = NSToolbarItem.Identifier("title")
    static let home = NSToolbarItem.Identifier("home")
    static let apps = NSToolbarItem.Identifier("apps")
    static let privacy = NSToolbarItem.Identifier("privacy")
    static let screenshot = NSToolbarItem.Identifier("screenshot")
    static let record = NSToolbarItem.Identifier("record")
    static let gif = NSToolbarItem.Identifier("gif")
}

final class MirrorWindowController: NSResponder, NSWindowDelegate, NSToolbarDelegate, NSMenuItemValidation {
    let device: Device
    /// Argument is true when the user closed the window, false when the device went away.
    var onClose: ((Bool) -> Void)?

    private let window: NSWindow
    private let view = MirrorView()
    private let hub = FrameHub()
    private let source: FrameSource
    private var input: InputControl? { source as? InputControl }
    private var frameSize = CGSize.zero
    private let statusLabel = NSTextField(labelWithString: "")
    private var recordItem: NSToolbarItem?
    private var gifItem: NSToolbarItem?
    private var statusTimer: Timer?
    private var recordingSince: Date?
    private var gifSince: Date?
    private var flashUntil = Date.distantPast
    private var endedByDevice = false
    private var closing = false

    /// Private mode: what of the device's screen is let through.
    private enum Reveal: Equatable {
        case hidden
        case all
        /// Only this app. On Android the picture follows it; on iOS it stays until the phone locks.
        case app(DeviceApp)
    }

    private var reveal = Reveal.hidden
    /// Whether the chosen app is the one in front right now. Android reports it; on iOS it is
    /// deduced from the change-of-app announcements and the picture (see `screenChangedHands`).
    private var appInFront = false
    /// iOS: looks of the chosen app, taken at calm moments while it was known to be in front.
    private var knownLooks: [Fingerprint] = []
    /// iOS: since when the chosen app has been in front (`CACurrentMediaTime`).
    private var frontSince: CFTimeInterval = 0
    private var returnCheck: DispatchWorkItem?
    private var rememberKey: String { "lastApp.\(device.id)" }
    private let companion: Companion
    private let picker: AppPickerModel
    private var popover: NSPopover?
    private var appsItem: NSToolbarItem?
    private var privacyItem: NSToolbarItem?
    private var watchTimer: Timer?
    private var watchBusy = false
    /// iOS: stops the observer that reports when the screen changes hands (see `pick`).
    private var stopObserving: (() -> Void)?
    private var lastTransition = Date.distantPast
    private var ignoreTransitionsUntil = Date.distantPast
    private let watchQueue = DispatchQueue(label: "mirroru.watch")

    /// How long frames wait while one app is followed (see `FrameHub.setHoldback`).
    static let holdback: CFTimeInterval = 0.8

    private var isHidden: Bool {
        switch reveal {
        case .hidden: return true
        case .all: return false
        case .app: return !appInFront
        }
    }

    init(device: Device, source: FrameSource) {
        self.device = device
        self.source = source
        companion = makeCompanion(for: device)
        picker = AppPickerModel(companion: companion)
        reveal = AppDelegate.startPrivate ? .hidden : .all
        let height = min(760, (NSScreen.main?.visibleFrame.height ?? 900) - 140)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: (height * 9 / 19.5).rounded(), height: height),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        super.init()

        window.title = device.name
        // The system title would push the buttons into the overflow menu on a phone-width window,
        // so the name lives in a toolbar item that truncates instead.
        window.titleVisibility = .hidden
        // One line: the device name, temporarily replaced by status ("● REC 0:12", "Captura guardada…").
        statusLabel.stringValue = device.name
        statusLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        window.isReleasedWhenClosed = false
        window.backgroundColor = .black
        window.delegate = self
        window.contentView = view
        window.contentMinSize = NSSize(width: 220, height: 220)
        // Puts this controller in the responder chain so menu shortcuts reach it.
        nextResponder = window.nextResponder
        window.nextResponder = self

        let toolbar = NSToolbar(identifier: "mirroru.\(device.platform.rawValue)")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        window.toolbar = toolbar
        window.toolbarStyle = .unifiedCompact

        picker.remembered = UserDefaults.standard.string(forKey: rememberKey)
        picker.onPick = { [weak self] app in self?.pick(app) }
        picker.onShowAll = { [weak self] in self?.setReveal(.all) }
        picker.onHide = { [weak self] in self?.setReveal(.hidden) }
        applyPrivacy()

        view.input = input
        hub.onFrame = { [weak self] buffer in self?.display(buffer) }
        hub.gifLimitReached = { [weak self] in DispatchQueue.main.async { self?.stopGif() } }
        source.onFrame = { [hub] buffer in hub.push(buffer) }
        source.onEnd = { [weak self] message in DispatchQueue.main.async { self?.sourceEnded(message) } }
    }

    required init?(coder: NSCoder) { fatalError() }

    func show() {
        window.center()
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(view)
        source.start()
        // An iPhone without Developer Mode cannot list or open apps: show its whole screen by default.
        if device.platform == .ios, reveal == .hidden {
            watchQueue.async { [companion] in
                guard companion.unavailableReason() != nil else { return }
                DispatchQueue.main.async {
                    guard self.reveal == .hidden, !self.closing else { return }
                    self.setReveal(.all)
                    self.flash("Sin modo desarrollador")
                }
            }
        }
    }

    // MARK: Private mode

    private func setReveal(_ new: Reveal) {
        reveal = new
        appInFront = false
        knownLooks = []
        returnCheck?.cancel()
        applyPrivacy()
    }

    private func applyPrivacy() {
        let hidden = isHidden
        // Following one app: the news that the user left it comes a few tenths late (an announcement on iOS,
        // the next poll on Android). Frames are held back so that moment never reaches the screen or a capture.
        var following = false
        if case .app = reveal { following = true }
        hub.setHoldback(following ? Self.holdback : 0)
        // Android reports the app as soon as it starts opening, with the previous screen still fading out.
        hub.setHidden(hidden, settle: companion.tracksForeground ? 0.5 : 0)
        var chosen: DeviceApp?
        if case .app(let app) = reveal { chosen = app }
        picker.selected = chosen
        picker.hidden = reveal != .all
        view.setPrivate(hidden, hint: chosen.map { "Esperando a \($0.name)…" } ?? "Elige una app (⌘K) o muestra todo (⌘P)")
        if let privacyItem {
            configure(privacyItem, symbol: reveal == .hidden ? "eye.slash" : "eye",
                      label: reveal == .hidden ? "Mostrar" : "Ocultar",
                      tip: reveal == .hidden ? "Mostrar toda la pantalla (⌘P)" : "Ocultar la pantalla (⌘P)")
        }
        if let appsItem { appsItem.toolTip = chosen.map { "Mostrando solo \($0.name) · elegir otra app (⌘K)" } ?? "Elegir la app que se muestra (⌘K)" }
        updateWatch()
    }

    /// Android: follow the app in front. iOS: go back to private when the phone locks.
    private func updateWatch() {
        var interval: TimeInterval?
        if case .app = reveal, companion.tracksForeground { interval = 0.25 }
        else if reveal != .hidden, device.platform == .ios { interval = 1.5 }
        watchTimer?.invalidate()
        watchTimer = interval.map { Timer.scheduledTimer(withTimeInterval: $0, repeats: true) { [weak self] _ in self?.watch() } }
    }

    private func watch() {
        guard !watchBusy else { return }
        watchBusy = true
        let state = reveal
        watchQueue.async { [companion] in
            var front: String?, locked: Bool?
            if case .app = state, companion.tracksForeground { front = companion.foreground() } else { locked = companion.isLocked() }
            DispatchQueue.main.async {
                self.watchBusy = false
                guard self.reveal == state, !self.closing else { return }
                if case .app(let app) = state, companion.tracksForeground {
                    // Unknown counts as "not in front": when in doubt, stay private.
                    let inFront = front == app.id
                    if inFront != self.appInFront {
                        self.appInFront = inFront
                        self.applyPrivacy()
                    }
                } else if locked == true {
                    if case .app = state {
                        // Keep the app chosen: unlocking back into it shows it again.
                        guard self.appInFront else { return }
                        // The lock is noticed a couple of seconds late: only looks older than that are the app's.
                        let now = CACurrentMediaTime()
                        if let look = self.hub.fingerprint(between: self.frontSince + 1.0, and: now - 3.0) {
                            self.knownLooks.append(look)
                        }
                        self.appInFront = false
                        self.applyPrivacy()
                    } else {
                        self.setReveal(.hidden)
                    }
                    self.flash("Bloqueado: modo privado")
                }
            }
        }
    }

    private func pick(_ app: DeviceApp) {
        popover?.close()
        UserDefaults.standard.set(app.id, forKey: rememberKey)
        picker.remembered = app.id
        flash("Abriendo \(app.name)…")
        // Stay private while the app opens, so the home screen is never shown on the way.
        setReveal(.hidden)
        picker.selected = app
        watchQueue.async { [companion] in
            // iOS cannot say which app is in front, but it does announce every change of app.
            // Listen before opening the app, so nothing that happens afterwards is missed.
            if !companion.tracksForeground, self.stopObserving == nil {
                let stop = companion.observeTransitions { [weak self] in
                    DispatchQueue.main.async { self?.screenChangedHands() }
                }
                DispatchQueue.main.sync { self.stopObserving = stop }
            }
            var failure: String?
            do { try companion.launch(app) } catch { failure = "\(error)" }
            // Opening the app is itself a change: the announcements of the next second are its own.
            let settled = Date().addingTimeInterval(1.0)
            DispatchQueue.main.asyncAfter(deadline: .now() + (companion.tracksForeground ? 0 : 1.2)) {
                guard !self.closing else { return }
                if let failure {
                    self.picker.selected = nil
                    self.flash(failure)
                } else if self.lastTransition > settled {
                    self.flash("Saliste de \(app.name)")
                } else {
                    self.ignoreTransitionsUntil = settled
                    self.setReveal(.app(app))
                    if !companion.tracksForeground {
                        // The app was opened from here a moment ago: it is in front.
                        self.appInFront = true
                        self.frontSince = CACurrentMediaTime()
                        self.applyPrivacy()
                    }
                }
            }
        }
    }

    /// iOS announces every change of app, but not where the user went.
    /// Leaving the chosen app goes private at once. While away, each later change is followed by a look at
    /// the picture: if it shows the app the way it was left, the user is back and it is shown again.
    private func screenChangedHands() {
        lastTransition = Date()
        guard case .app(let app) = reveal, !companion.tracksForeground, lastTransition > ignoreTransitionsUntil else { return }
        if appInFront {
            rememberLook()
            appInFront = false
            applyPrivacy()
            flash("Saliste de \(app.name)")
        }
        // Announcements come in bursts; look once the animation has settled, and once more for slow resumes.
        returnCheck?.cancel()
        let check = DispatchWorkItem { [weak self] in self?.checkReturn(to: app, retry: true) }
        returnCheck = check
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9, execute: check)
    }

    /// Keeps how the app looked before the user left it. Only a calm moment counts: not the first second
    /// after arriving (opening animation) nor the last one (the announcement comes into the closing one).
    /// Going in and out quickly leaves no such moment, and then the looks already known are kept.
    private func rememberLook() {
        let now = CACurrentMediaTime()
        guard let look = hub.fingerprint(between: frontSince + 1.0, and: now - 1.0) else { return }
        knownLooks.removeAll { $0.matches(look) }
        knownLooks.append(look)
        if knownLooks.count > 6 { knownLooks.removeFirst() }
    }

    private func checkReturn(to app: DeviceApp, retry: Bool) {
        guard reveal == .app(app), !appInFront, !closing, !knownLooks.isEmpty else { return }
        if let current = hub.currentFingerprint(), knownLooks.contains(where: { $0.matches(current) }) {
            appInFront = true
            frontSince = CACurrentMediaTime()
            applyPrivacy()
            flash("De vuelta en \(app.name)")
        } else if retry {
            let check = DispatchWorkItem { [weak self] in self?.checkReturn(to: app, retry: false) }
            returnCheck = check
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: check)
        }
    }

    @objc func togglePrivacy() {
        setReveal(reveal == .hidden ? .all : .hidden)
    }

    @objc func chooseApp() {
        if let popover, popover.isShown { return popover.close() }
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: AppPickerView(model: picker))
        self.popover = popover
        picker.query = ""
        if let anchor = appsItem?.view, anchor.window != nil {
            popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
        } else {
            let top = NSRect(x: view.bounds.midX - 1, y: view.bounds.maxY - 2, width: 2, height: 2)
            popover.show(relativeTo: top, of: view, preferredEdge: .minY)
        }
    }

    private func display(_ buffer: CVPixelBuffer) {
        let size = CGSize(width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer))
        if size != frameSize {
            frameSize = size
            fitWindow(to: size)
        }
        view.show(buffer)
    }

    /// Keeps the window's long side and matches the device's aspect ratio (handles rotation too).
    private func fitWindow(to size: CGSize) {
        let content = window.contentLayoutRect.size
        let long = max(content.width, content.height)
        let scale = long / max(size.width, size.height)
        let target = NSSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
        window.contentAspectRatio = size
        var frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: target))
        frame.origin = NSPoint(x: window.frame.midX - frame.width / 2, y: window.frame.maxY - frame.height)
        window.setFrame(frame, display: true, animate: window.isVisible && content != target)
    }

    private func sourceEnded(_ message: String) {
        guard !closing else { return }
        endedByDevice = true
        if hub.isRecording || hub.isRecordingGif {
            finishCaptures { self.window.close() }
        } else {
            FileHandle.standardError.write(Data("mirroru: \(device.name): \(message)\n".utf8))
            window.close()
        }
    }

    // MARK: Toolbar

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.title, .home, .flexibleSpace, .apps, .privacy, .screenshot, .record, .gif]
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.title, .flexibleSpace] + (input != nil ? [.home] : []) + [.apps, .privacy, .screenshot, .record, .gif]
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        let item = NSToolbarItem(itemIdentifier: id)
        if id == .title {
            statusLabel.widthAnchor.constraint(lessThanOrEqualToConstant: input != nil ? 56 : 92).isActive = true
            statusLabel.toolTip = "\(device.name) · \(device.platform.rawValue) · \(device.detail)"
            item.view = statusLabel
            item.label = device.name
            return item
        }
        item.target = self
        item.isBordered = true
        switch id {
        case .home:
            configure(item, symbol: "house", label: "Inicio", tip: "Inicio (⇧⌘H) · clic derecho en la pantalla = Atrás")
            item.action = #selector(pressHome)
        case .apps:
            configure(item, symbol: "square.grid.2x2", label: "Apps", tip: "Elegir la app que se muestra (⌘K)")
            item.action = #selector(chooseApp)
            appsItem = item
        case .privacy:
            configure(item, symbol: "eye.slash", label: "Mostrar", tip: "Mostrar toda la pantalla (⌘P)")
            item.action = #selector(togglePrivacy)
            privacyItem = item
            DispatchQueue.main.async { [weak self] in self?.applyPrivacy() }
        case .screenshot:
            configure(item, symbol: "camera", label: "Captura", tip: "Guardar captura en el Escritorio (⌘S)")
            item.action = #selector(takeScreenshot)
        case .record:
            configure(item, symbol: "record.circle", label: "Grabar", tip: "Grabar video (⌘R)")
            item.action = #selector(toggleRecording)
            recordItem = item
        case .gif:
            configure(item, symbol: "photo.stack", label: "GIF", tip: "Grabar GIF (⌘G)")
            item.action = #selector(toggleGif)
            gifItem = item
        default:
            return nil
        }
        return item
    }

    private func configure(_ item: NSToolbarItem, symbol: String, label: String, tip: String, active: Bool = false) {
        var image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        if active { image = image?.withSymbolConfiguration(.init(paletteColors: [.systemRed])) }
        item.image = image
        item.label = label
        item.toolTip = tip
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(pressHome), #selector(pressBack), #selector(pressRecents),
             #selector(pressPower), #selector(pressVolumeUp), #selector(pressVolumeDown):
            return input != nil
        default:
            return true
        }
    }

    // MARK: Status line (under the device name)

    private func flash(_ message: String) {
        flashUntil = Date().addingTimeInterval(2.5)
        statusLabel.stringValue = message
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.6) { [weak self] in self?.updateStatus() }
    }

    private func updateStatus() {
        guard Date() >= flashUntil else { return }
        func elapsed(_ since: Date) -> String {
            let s = Int(Date().timeIntervalSince(since))
            return String(format: "%d:%02d", s / 60, s % 60)
        }
        if let recordingSince {
            statusLabel.stringValue = "● REC \(elapsed(recordingSince))"
        } else if let gifSince {
            statusLabel.stringValue = "● GIF \(elapsed(gifSince))"
        } else {
            statusLabel.stringValue = device.name
        }
        if recordingSince == nil, gifSince == nil {
            statusTimer?.invalidate()
            statusTimer = nil
        } else if statusTimer == nil {
            statusTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.updateStatus() }
        }
    }

    // MARK: Actions

    @objc func takeScreenshot() {
        let url = Output.url(kind: "Captura", device: device.name, ext: "png")
        // While private only the blurred frame may be saved, never the device's own screenshot.
        let hidden = isHidden
        DispatchQueue.global(qos: .userInitiated).async { [source, hub] in
            // Prefer the device's own lossless screenshot; fall back to the current video frame.
            var saved = false
            if !hidden, let png = source.nativeScreenshot() { saved = (try? png.write(to: url)) != nil }
            if !saved { saved = hub.screenshot(to: url) }
            DispatchQueue.main.async { self.flash(saved ? "Captura guardada" : "Error al guardar") }
        }
    }

    @objc func toggleRecording() {
        if recordingSince != nil {
            stopRecording()
        } else {
            hub.startRecording(to: Output.url(kind: "Video", device: device.name, ext: "mp4"))
            recordingSince = Date()
            if let recordItem { configure(recordItem, symbol: "stop.circle.fill", label: "Detener", tip: "Detener grabación (⌘R)", active: true) }
            updateStatus()
        }
    }

    private func stopRecording(then: (() -> Void)? = nil) {
        recordingSince = nil
        if let recordItem { configure(recordItem, symbol: "record.circle", label: "Grabar", tip: "Grabar video (⌘R)") }
        hub.stopRecording { [weak self] url in
            self?.saved(url, what: "Video")
            then?()
        }
    }

    @objc func toggleGif() {
        if gifSince != nil {
            stopGif()
        } else {
            hub.startGif(to: Output.url(kind: "GIF", device: device.name, ext: "gif"))
            gifSince = Date()
            if let gifItem { configure(gifItem, symbol: "stop.circle.fill", label: "Detener", tip: "Detener GIF (⌘G)", active: true) }
            updateStatus()
        }
    }

    private func stopGif(then: (() -> Void)? = nil) {
        guard gifSince != nil else { then?(); return }
        gifSince = nil
        if let gifItem { configure(gifItem, symbol: "photo.stack", label: "GIF", tip: "Grabar GIF (⌘G)") }
        statusLabel.stringValue = "Creando GIF…"
        hub.stopGif { [weak self] url in
            self?.saved(url, what: "GIF")
            then?()
        }
    }

    private func saved(_ url: URL?, what: String) {
        if let url {
            flash("\(what) guardado")
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            flash("Error al guardar")
        }
    }

    private func finishCaptures(then: @escaping () -> Void) {
        let group = DispatchGroup()
        if recordingSince != nil { group.enter(); stopRecording { group.leave() } }
        if gifSince != nil { group.enter(); stopGif { group.leave() } }
        group.notify(queue: .main, execute: then)
    }

    @objc func pressHome() { input?.key(AndroidKey.home) }
    @objc func pressBack() { input?.key(AndroidKey.back) }
    @objc func pressRecents() { input?.key(AndroidKey.recents) }
    @objc func pressPower() { input?.key(AndroidKey.power) }
    @objc func pressVolumeUp() { input?.key(AndroidKey.volumeUp) }
    @objc func pressVolumeDown() { input?.key(AndroidKey.volumeDown) }

    // MARK: Closing

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        // Never lose a capture in progress: save it first, then close.
        guard recordingSince != nil || gifSince != nil else { return true }
        finishCaptures { sender.close() }
        return false
    }

    func windowWillClose(_ notification: Notification) {
        closing = true
        popover?.close()
        stopObserving?()
        watchTimer?.invalidate()
        statusTimer?.invalidate()
        source.onFrame = nil
        source.stop()
        onClose?(!endedByDevice)
    }
}

// MARK: - Screen view

final class MirrorView: NSView {
    weak var input: InputControl?
    private let screen = CALayer()
    private var videoSize = CGSize.zero
    private var downPoint: CGPoint?
    private var downTime = Date()
    private var scrollDelta = CGSize.zero
    private var scrollOrigin = CGPoint.zero
    private var scrollWork: DispatchWorkItem?
    private let privateBadge = NSStackView()
    private let privateHint = NSTextField(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        screen.contentsGravity = .resizeAspect
        screen.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull()]
        layer?.addSublayer(screen)

        // Shown over the blur. It is part of the window only: captures do not include it.
        let symbol = NSImageView(image: NSImage(systemSymbolName: "eye.slash.fill", accessibilityDescription: nil) ?? NSImage())
        symbol.symbolConfiguration = .init(pointSize: 30, weight: .regular)
        symbol.contentTintColor = .white
        let title = NSTextField(labelWithString: "Modo privado")
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        title.textColor = .white
        privateHint.font = .systemFont(ofSize: 12)
        privateHint.textColor = NSColor.white.withAlphaComponent(0.8)
        privateHint.alignment = .center
        privateHint.lineBreakMode = .byWordWrapping
        privateHint.maximumNumberOfLines = 3
        privateHint.preferredMaxLayoutWidth = 190
        [symbol, title, privateHint].forEach(privateBadge.addArrangedSubview)
        privateBadge.orientation = .vertical
        privateBadge.spacing = 6
        privateBadge.isHidden = true
        privateBadge.shadow = {
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.5)
            shadow.shadowBlurRadius = 6
            return shadow
        }()
        privateBadge.translatesAutoresizingMaskIntoConstraints = false
        addSubview(privateBadge)
        NSLayoutConstraint.activate([
            privateBadge.centerXAnchor.constraint(equalTo: centerXAnchor),
            privateBadge.centerYAnchor.constraint(equalTo: centerYAnchor),
            privateBadge.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -24),
        ])
    }

    func setPrivate(_ on: Bool, hint: String) {
        privateBadge.isHidden = !on
        privateHint.stringValue = hint
    }

    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func layout() {
        super.layout()
        screen.frame = bounds
    }

    func show(_ buffer: CVPixelBuffer) {
        videoSize = CGSize(width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer))
        screen.contents = CVPixelBufferGetIOSurface(buffer)?.takeUnretainedValue() ?? buffer
    }

    /// View point -> normalized device point (origin top-left), nil outside the picture.
    private func devicePoint(_ event: NSEvent, clamp: Bool = false) -> CGPoint? {
        guard videoSize.width > 0, videoSize.height > 0 else { return nil }
        let p = convert(event.locationInWindow, from: nil)
        let rect = AVMakeRect(aspectRatio: videoSize, insideRect: bounds)
        var x = (p.x - rect.minX) / rect.width
        var y = 1 - (p.y - rect.minY) / rect.height
        if clamp {
            x = min(max(x, 0), 1)
            y = min(max(y, 0), 1)
        }
        return (0...1).contains(x) && (0...1).contains(y) ? CGPoint(x: x, y: y) : nil
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        downPoint = devicePoint(event)
        downTime = Date()
    }

    override func mouseUp(with event: NSEvent) {
        guard let input, let start = downPoint, let end = devicePoint(event, clamp: true) else { return }
        downPoint = nil
        let held = Date().timeIntervalSince(downTime)
        let moved = hypot((end.x - start.x) * bounds.width, (end.y - start.y) * bounds.height)
        if moved < 8 {
            held > 0.5 ? input.longPress(start) : input.tap(start)
        } else {
            input.swipe(from: start, to: end, duration: held)
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        input?.key(AndroidKey.back)
    }

    override func scrollWheel(with event: NSEvent) {
        guard let input, let origin = devicePoint(event) else { return }
        // Coalesce the wheel events of one gesture into a single swipe.
        if scrollWork == nil { scrollOrigin = origin; scrollDelta = .zero }
        scrollDelta.width += event.scrollingDeltaX
        scrollDelta.height += event.scrollingDeltaY
        scrollWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.scrollWork = nil
            let dx = max(-0.45, min(0.45, self.scrollDelta.width / self.bounds.width))
            let dy = max(-0.45, min(0.45, self.scrollDelta.height / self.bounds.height))
            let end = CGPoint(x: min(max(self.scrollOrigin.x + dx, 0.02), 0.98), y: min(max(self.scrollOrigin.y + dy, 0.02), 0.98))
            input.swipe(from: self.scrollOrigin, to: end, duration: 0.2)
        }
        scrollWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
    }

    override func keyDown(with event: NSEvent) {
        guard let input, !event.modifierFlags.contains(.command) else { return super.keyDown(with: event) }
        let special: [UInt16: Int] = [36: AndroidKey.enter, 76: AndroidKey.enter, 51: AndroidKey.delete, 53: AndroidKey.back,
                                      48: AndroidKey.tab, 123: AndroidKey.left, 124: AndroidKey.right,
                                      126: AndroidKey.up, 125: AndroidKey.down]
        if let code = special[event.keyCode] {
            input.key(code)
        } else if let characters = event.characters, !characters.isEmpty {
            input.text(characters)
        }
    }
}
