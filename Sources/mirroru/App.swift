import AppKit
import AVFoundation

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

// MARK: - Window

private extension NSToolbarItem.Identifier {
    static let title = NSToolbarItem.Identifier("title")
    static let home = NSToolbarItem.Identifier("home")
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

    init(device: Device, source: FrameSource) {
        self.device = device
        self.source = source
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
        [.title, .home, .flexibleSpace, .screenshot, .record, .gif]
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.title, .flexibleSpace] + (input != nil ? [.home] : []) + [.screenshot, .record, .gif]
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        let item = NSToolbarItem(itemIdentifier: id)
        if id == .title {
            statusLabel.widthAnchor.constraint(lessThanOrEqualToConstant: input != nil ? 104 : 148).isActive = true
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
        DispatchQueue.global(qos: .userInitiated).async { [source, hub] in
            // Prefer the device's own lossless screenshot; fall back to the current video frame.
            var saved = false
            if let png = source.nativeScreenshot() { saved = (try? png.write(to: url)) != nil }
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

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        screen.contentsGravity = .resizeAspect
        screen.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull()]
        layer?.addSublayer(screen)
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
