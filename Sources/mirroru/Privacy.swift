import AppKit
import CoreImage
import SwiftUI

// MARK: - Blur

/// Turns a frame into an unreadable blur. Used by the hub, so the screen, screenshots, video and GIF
/// all get the same picture: nothing private can leak through a capture.
final class Blurrer {
    private let context = CIContext()
    private var pool: CVPixelBufferPool?
    private var size = (width: 0, height: 0)

    func blur(_ buffer: CVPixelBuffer) -> CVPixelBuffer? {
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        if pool == nil || size != (width, height) {
            let attributes: [CFString: Any] = [
                kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey: width,
                kCVPixelBufferHeightKey: height,
                kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            ]
            pool = nil
            CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attributes as CFDictionary, &pool)
            size = (width, height)
        }
        var made: CVPixelBuffer?
        guard let pool, CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &made) == kCVReturnSuccess,
              let output = made else { return nil }

        // Blur a small copy (cheap) and scale it back: text and icons become colour blobs.
        let full = CGRect(x: 0, y: 0, width: width, height: height)
        let shrink = 96 / CGFloat(max(width, height))
        // Whole-pixel size: a fractional edge would be half transparent and smear a dark band when clamped.
        let extent = CGRect(x: 0, y: 0, width: max(1, (full.width * shrink).rounded()), height: max(1, (full.height * shrink).rounded()))
        let small = CIImage(cvPixelBuffer: buffer)
            .transformed(by: CGAffineTransform(scaleX: extent.width / full.width, y: extent.height / full.height))
            .cropped(to: extent)
        let blurred = small.clampedToExtent().applyingGaussianBlur(sigma: 5).cropped(to: extent)
        let image = blurred
            .transformed(by: CGAffineTransform(scaleX: full.width / extent.width, y: full.height / extent.height))
            .applyingFilter("CIColorControls", parameters: [kCIInputBrightnessKey: -0.06, kCIInputSaturationKey: 0.85])
        context.render(image, to: output, bounds: full, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        return output
    }
}

// MARK: - Fingerprint

/// A tiny copy of a frame, used to recognise a screen seen before. iOS only says *that* the user changed
/// app, never to which one; but an app comes back looking the way it was left, so comparing the picture
/// with the one taken just before leaving tells whether the chosen app is in front again.
struct Fingerprint {
    static let width = 40, height = 80
    private static let context = CIContext()
    /// RGBA, row by row.
    private let pixels: [UInt8]

    init?(_ buffer: CVPixelBuffer) {
        let image = CIImage(cvPixelBuffer: buffer)
        guard image.extent.width > 0, image.extent.height > 0 else { return nil }
        let small = image.transformed(by: CGAffineTransform(scaleX: CGFloat(Self.width) / image.extent.width,
                                                            y: CGFloat(Self.height) / image.extent.height))
        var pixels = [UInt8](repeating: 0, count: Self.width * Self.height * 4)
        Self.context.render(small, toBitmap: &pixels, rowBytes: Self.width * 4,
                            bounds: CGRect(x: 0, y: 0, width: Self.width, height: Self.height),
                            format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        self.pixels = pixels
    }

    private func channel(_ x: Int, _ y: Int, _ c: Int) -> Int { Int(pixels[(y * Self.width + x) * 4 + c]) }

    /// A cell with an edge in it: text, an icon, a border. Blank areas say nothing about which screen this is.
    private func hasDetail(_ x: Int, _ y: Int) -> Bool {
        var change = 0
        for c in 0..<3 {
            change = max(change, abs(channel(x, y, c) - channel(x + 1, y, c)), abs(channel(x, y, c) - channel(x, y + 1, c)))
        }
        return change > 14
    }

    /// True when `other` shows the same screen. Deliberately strict: a doubtful match stays private.
    func matches(_ other: Fingerprint) -> Bool {
        var cells = 0, same = 0, detailed = 0, detailedSame = 0, ownDetail = 0
        // The status bar and the home indicator change on their own, so the top and bottom strips are skipped.
        for y in 5..<(Self.height - 4) {
            for x in 0..<(Self.width - 1) {
                var difference = 0
                for c in 0..<3 { difference = max(difference, abs(channel(x, y, c) - other.channel(x, y, c))) }
                let equal = difference < 26
                cells += 1
                if equal { same += 1 }
                let mine = hasDetail(x, y)
                if mine { ownDetail += 1 }
                if mine || other.hasDetail(x, y) {
                    detailed += 1
                    if equal { detailedSame += 1 }
                }
            }
        }
        // A nearly blank screen (a white page, a black one) looks like any other blank screen: never trust it.
        guard ownDetail >= 80, detailed > 0 else { return false }
        return Double(same) / Double(cells) >= 0.93 && Double(detailedSame) / Double(detailed) >= 0.82
    }
}

// MARK: - Apps on the device

struct DeviceApp: Identifiable, Hashable {
    /// Bundle identifier (iOS) or package name (Android).
    let id: String
    let name: String
    /// Came with the system (sorted after the apps the user installed).
    let system: Bool
    /// A development build (installed from Xcode, or debuggable on Android), not a store release.
    var development = false
}

struct CompanionError: Error, CustomStringConvertible {
    let description: String
}

/// What the device can tell us beyond its picture. All calls block: use them off the main thread.
protocol Companion: AnyObject {
    /// True when the device reports which app is in front, so the picture can follow one app.
    var tracksForeground: Bool { get }
    /// nil when ready; otherwise why the app list is unavailable (shown to the user).
    func unavailableReason() -> String?
    func apps() throws -> [DeviceApp]
    func icon(for app: DeviceApp) -> NSImage?
    func launch(_ app: DeviceApp) throws
    /// Identifier of the app in front, "" for none (launcher, notifications…), nil if unknown.
    func foreground() -> String?
    /// nil if unknown.
    func isLocked() -> Bool?
    /// For devices that cannot say which app is in front: calls `handler` (on any thread) every time the
    /// device moves between apps or to the home screen. Returns a way to stop, or nil if unsupported.
    func observeTransitions(_ handler: @escaping () -> Void) -> (() -> Void)?
}

extension Companion {
    func observeTransitions(_ handler: @escaping () -> Void) -> (() -> Void)? { nil }
}

func makeCompanion(for device: Device) -> Companion {
    switch device.platform {
    case .android: return AndroidCompanion(serial: device.id)
    case .ios: return IOSCompanion(captureID: device.id, name: device.name)
    case .demo: return DemoCompanion()
    }
}

private func runTool(_ path: String, _ arguments: [String]) -> (status: Int32, output: String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = arguments
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    do { try process.run() } catch { return (-1, "\(error.localizedDescription)") }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
}

// MARK: iOS (Xcode's devicectl; needs Developer Mode on the phone)

final class IOSCompanion: Companion {
    let tracksForeground = false
    private let captureID: String
    private let name: String
    private var identifier: String?
    private var problem: String?
    private var resolved = false
    private let lock = NSLock()

    init(captureID: String, name: String) {
        self.captureID = captureID
        self.name = name
    }

    /// Runs devicectl and returns the "result" object of its JSON output.
    private func devicectl(_ arguments: [String]) -> [String: Any]? {
        let json = FileManager.default.temporaryDirectory.appendingPathComponent("mirroru-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: json) }
        let run = runTool("/usr/bin/xcrun", ["devicectl"] + arguments + ["--quiet", "--timeout", "20", "--json-output", json.path])
        guard run.status == 0, let data = try? Data(contentsOf: json),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return root["result"] as? [String: Any]
    }

    /// Finds this phone among Xcode's devices and checks Developer Mode. Done once.
    private func resolve() {
        lock.lock()
        defer { lock.unlock() }
        guard !resolved else { return }
        resolved = true
        guard let devices = devicectl(["list", "devices"])?["devices"] as? [[String: Any]] else {
            problem = "Hace falta Xcode en esta Mac para ver las apps del iPhone."
            return
        }
        func flat(_ s: String) -> String { s.replacingOccurrences(of: "-", with: "").lowercased() }
        let physical = devices.filter { ($0["hardwareProperties"] as? [String: Any])?["reality"] as? String == "physical" }
        let match = physical.first { flat(($0["hardwareProperties"] as? [String: Any])?["udid"] as? String ?? "") == flat(captureID) }
            ?? physical.first { ($0["deviceProperties"] as? [String: Any])?["name"] as? String == name }
        guard let match, let id = match["identifier"] as? String else {
            problem = "Xcode no reconoce este dispositivo. Desbloquéalo y pulsa «Confiar»."
            return
        }
        guard (match["deviceProperties"] as? [String: Any])?["developerModeStatus"] as? String == "enabled" else {
            problem = "Activa el modo de desarrollador en el iPhone:\nAjustes › Privacidad y seguridad › Modo de desarrollador.\nDespués vuelve a abrir Mirroru."
            return
        }
        identifier = id
    }

    func unavailableReason() -> String? {
        resolve()
        return problem
    }

    func apps() throws -> [DeviceApp] {
        resolve()
        guard let identifier else { throw CompanionError(description: problem ?? "No disponible") }
        guard let list = devicectl(["device", "info", "apps", "--device", identifier, "--include-all-apps"])?["apps"] as? [[String: Any]]
        else { throw CompanionError(description: "No se pudo leer la lista de apps. Desbloquea el iPhone e inténtalo de nuevo.") }
        return list.compactMap { app in
            guard let id = app["bundleIdentifier"] as? String, let name = app["name"] as? String,
                  app["hidden"] as? Bool != true, app["appClip"] as? Bool != true else { return nil }
            // Some names carry invisible direction marks ("\u{200E}WhatsApp"), which break search and sorting.
            let clean = name.unicodeScalars.filter { !$0.properties.isDefaultIgnorableCodePoint }
            // UI-test runners are installed by Xcode too, but they are not apps anyone wants to show.
            let development = app["builtByDeveloper"] as? Bool == true && !name.hasSuffix("-Runner")
            return DeviceApp(id: id, name: String(String.UnicodeScalarView(clean)), system: app["defaultApp"] as? Bool == true,
                             development: development)
        }
    }

    func icon(for app: DeviceApp) -> NSImage? {
        guard let identifier else { return nil }
        let folder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("mirroru/icons/\(identifier)", isDirectory: true)
        let file = folder.appendingPathComponent("\(app.id).png")
        if let cached = NSImage(contentsOf: file) { return cached }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        _ = devicectl(["device", "info", "appIcon", "--device", identifier, "--app-bundle-id", app.id,
                       "--width", "60", "--height", "60", "--scale", "2", "--destination", file.path])
        return NSImage(contentsOf: file)
    }

    func launch(_ app: DeviceApp) throws {
        guard let identifier else { throw CompanionError(description: problem ?? "No disponible") }
        guard devicectl(["device", "process", "launch", "--device", identifier, app.id]) != nil else {
            throw CompanionError(description: "No se pudo abrir \(app.name). Desbloquea el iPhone.")
        }
    }

    func foreground() -> String? { nil }

    /// iOS posts these system-wide notifications whenever an app opens, closes or is left for the home
    /// screen or another app. They do not say where the user went, only that the screen changed hands.
    func observeTransitions(_ handler: @escaping () -> Void) -> (() -> Void)? {
        guard let identifier else { return nil }
        let observer = TransitionObserver(device: identifier, handler: handler)
        observer.start()
        return { observer.stop() }
    }

    func isLocked() -> Bool? {
        guard let identifier else { return nil }
        return devicectl(["device", "info", "lockState", "--device", identifier])?["passcodeRequired"] as? Bool
    }
}

/// Keeps a `devicectl device notification observe` process running and reports each notification it prints.
private final class TransitionObserver {
    private let device: String
    private let handler: () -> Void
    private let queue = DispatchQueue(label: "mirroru.transitions")
    private var process: Process?
    private var stopped = false

    init(device: String, handler: @escaping () -> Void) {
        self.device = device
        self.handler = handler
    }

    func start() {
        queue.async { self.launch() }
    }

    func stop() {
        queue.async {
            self.stopped = true
            self.process?.terminate()
            self.process = nil
        }
    }

    private func launch() {
        guard !stopped else { return }
        let process = Process()
        // devicectl buffers its output when it is not writing to a terminal, so the notifications would
        // only arrive when it exits. `script` gives it a pseudo-terminal and each line comes at once.
        // It also ends an observation after its session timeout, so it is simply started again.
        process.executableURL = URL(fileURLWithPath: "/usr/bin/script")
        process.arguments = ["-q", "/dev/null", "/usr/bin/xcrun", "devicectl", "device", "notification", "observe", "--device", device,
                             "--name", "com.apple.mobile.SubstantialTransition",
                             "--name", "com.apple.springboard.homescreenunlocked",
                             "--session-timeout", "280", "--timeout", "300"]
        let pipe = Pipe()
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = pipe
        process.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { [handler] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil; return }
            if String(decoding: data, as: UTF8.self).contains("Observed '") { handler() }
        }
        let started = Date()
        process.terminationHandler = { [weak self] _ in
            pipe.fileHandleForReading.readabilityHandler = nil
            // Back off if it dies at once (device unplugged), so this never spins.
            let delay: TimeInterval = Date().timeIntervalSince(started) < 5 ? 3 : 0
            self?.queue.asyncAfter(deadline: .now() + delay) { self?.launch() }
        }
        do { try process.run() } catch { return }
        self.process = process
    }
}

// MARK: Android (adb)

final class AndroidCompanion: Companion {
    let tracksForeground = true
    private let serial: String

    init(serial: String) {
        self.serial = serial
    }

    private func shell(_ command: String) -> String? {
        ADB.output(["-s", serial, "shell", command]).flatMap { String(data: $0, encoding: .utf8) }
    }

    func unavailableReason() -> String? {
        ADB.path == nil ? "No se encontró adb en esta Mac." : nil
    }

    func apps() throws -> [DeviceApp] {
        // Only apps with a launcher icon: what the user can actually open.
        guard let launchable = shell("cmd package query-activities --brief -a android.intent.action.MAIN -c android.intent.category.LAUNCHER")
        else { throw CompanionError(description: "No se pudo leer la lista de apps.") }
        let user = Set((shell("pm list packages -3") ?? "").split(separator: "\n").map { $0.replacingOccurrences(of: "package:", with: "").trimmingCharacters(in: .whitespaces) })
        let debuggable = Self.parseDebuggable(shell("dumpsys package packages | grep -E 'Package \\[|flags=\\['") ?? "")
        var seen = Set<String>()
        let apps = launchable.split(separator: "\n").compactMap { line -> DeviceApp? in
            let entry = line.trimmingCharacters(in: .whitespaces)
            guard let slash = entry.firstIndex(of: "/"), !entry.contains(" ") else { return nil }
            let package = String(entry[..<slash])
            guard seen.insert(package).inserted else { return nil }
            return DeviceApp(id: package, name: Self.displayName(package), system: !user.contains(package),
                             development: debuggable.contains(package))
        }
        guard !apps.isEmpty else { throw CompanionError(description: "El dispositivo no devolvió ninguna app.") }
        return apps
    }

    /// Packages whose flags include DEBUGGABLE, from lines like
    /// "Package [com.example] (1a2b3c):" followed by "flags=[ DEBUGGABLE HAS_CODE ]".
    static func parseDebuggable(_ dump: String) -> Set<String> {
        var result = Set<String>(), current: String?
        for line in dump.split(separator: "\n") {
            if let open = line.range(of: "Package ["), let close = line.range(of: "]", range: open.upperBound..<line.endIndex) {
                current = String(line[open.upperBound..<close.lowerBound])
            } else if let current, line.contains("flags=["), line.contains("DEBUGGABLE") {
                result.insert(current)
            }
        }
        return result
    }

    /// adb does not expose app labels, so a readable name is derived from the package:
    /// "com.whatsapp" -> "Whatsapp", "com.google.android.youtube" -> "Youtube".
    static func displayName(_ package: String) -> String {
        let generic: Set<String> = ["com", "org", "net", "android", "app", "apps", "mobile", "client", "lite", "main"]
        let parts = package.split(separator: ".").map(String.init)
        let word = parts.last { !generic.contains($0.lowercased()) } ?? parts.last ?? package
        return word.prefix(1).uppercased() + word.dropFirst()
    }

    func icon(for app: DeviceApp) -> NSImage? { nil }

    func launch(_ app: DeviceApp) throws {
        guard shell("monkey -p \(app.id) -c android.intent.category.LAUNCHER 1") != nil else {
            throw CompanionError(description: "No se pudo abrir \(app.name).")
        }
    }

    func foreground() -> String? {
        shell("dumpsys window | grep -E 'mCurrentFocus|mDreamingLockscreen|isKeyguardShowing'").flatMap(Self.parseFocus)
    }

    /// "mCurrentFocus=Window{9f3 u0 com.whatsapp/com.whatsapp.HomeActivity}" -> "com.whatsapp".
    /// Windows without a package (NotificationShade, StatusBar) and the lock screen give "".
    static func parseFocus(_ dump: String) -> String? {
        if dump.contains("mDreamingLockscreen=true") || dump.contains("isKeyguardShowing=true") { return "" }
        guard let line = dump.split(separator: "\n").first(where: { $0.contains("mCurrentFocus=") }) else { return nil }
        guard let token = line.split(separator: " ").last?.trimmingCharacters(in: CharacterSet(charactersIn: "}")),
              let slash = token.firstIndex(of: "/") else { return "" }
        return String(token[..<slash])
    }

    func isLocked() -> Bool? { nil }
}

// MARK: Demo

final class DemoCompanion: Companion {
    let tracksForeground = false
    func unavailableReason() -> String? { nil }
    func apps() throws -> [DeviceApp] {
        [("Calculadora", true), ("Mapas", true), ("Mi App", false), ("Notas", true), ("WhatsApp", false)].map {
            DeviceApp(id: "demo.\($0.0.lowercased().replacingOccurrences(of: " ", with: ""))", name: $0.0, system: $0.1,
                      development: $0.0 == "Mi App")
        }
    }
    func icon(for app: DeviceApp) -> NSImage? { nil }
    func launch(_ app: DeviceApp) throws {}
    func foreground() -> String? { nil }
    func isLocked() -> Bool? { nil }
}

// MARK: - App picker

final class AppPickerModel: ObservableObject {
    @Published var apps: [DeviceApp] = []
    @Published var loading = false
    @Published var message: String?
    @Published var query = ""
    @Published var icons: [String: NSImage] = [:]
    @Published var selected: DeviceApp?
    /// False when everything is shown.
    @Published var hidden = true

    var onPick: ((DeviceApp) -> Void)?
    var onShowAll: (() -> Void)?
    var onHide: (() -> Void)?

    let companion: Companion
    private let work = DispatchQueue(label: "mirroru.companion")
    private let iconWork = DispatchQueue(label: "mirroru.icons")
    private var requested = Set<String>()

    init(companion: Companion) {
        self.companion = companion
    }

    /// Optional filter: only development builds, so store apps stay out of sight while sharing.
    @Published var developmentOnly = UserDefaults.standard.bool(forKey: "developmentOnly") {
        didSet { UserDefaults.standard.set(developmentOnly, forKey: "developmentOnly") }
    }

    /// The app chosen last time on this device: listed first, so ⌘K + Return brings it back.
    @Published var remembered: String?

    var filtered: [DeviceApp] {
        var apps = developmentOnly ? self.apps.filter(\.development) : self.apps
        let needle = query.trimmingCharacters(in: .whitespaces)
        if needle.isEmpty, let index = self.apps.firstIndex(where: { $0.id == remembered }) {
            apps.removeAll { $0.id == remembered }
            apps.insert(self.apps[index], at: 0)
        }
        guard !needle.isEmpty else { return apps }
        return apps.filter { $0.name.localizedCaseInsensitiveContains(needle) || $0.id.localizedCaseInsensitiveContains(needle) }
    }

    func load() {
        guard apps.isEmpty, !loading else { return }
        loading = true
        message = nil
        work.async { [companion] in
            var apps: [DeviceApp] = []
            var message = companion.unavailableReason()
            if message == nil {
                do { apps = try companion.apps() } catch { message = "\(error)" }
            }
            apps.sort {
                $0.system != $1.system ? !$0.system : $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
            DispatchQueue.main.async {
                self.apps = apps
                self.message = message
                self.loading = false
            }
        }
    }

    /// Icons are fetched one by one, only for rows that scroll into view, and cached on disk.
    func needIcon(_ app: DeviceApp) {
        guard requested.insert(app.id).inserted else { return }
        iconWork.async { [companion] in
            guard let image = companion.icon(for: app) else { return }
            DispatchQueue.main.async { self.icons[app.id] = image }
        }
    }
}

struct AppPickerView: View {
    @ObservedObject var model: AppPickerModel
    @FocusState private var searching: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Buscar app", text: $model.query)
                    .textFieldStyle(.plain)
                    .focused($searching)
                    .onSubmit { if let first = model.filtered.first { model.onPick?(first) } }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            Divider()
            Toggle("Solo en desarrollo", isOn: $model.developmentOnly)
                .toggleStyle(.switch)
                .controlSize(.mini)
                .font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .help("Muestra solo las apps instaladas desde Xcode o depurables, no las de la tienda")
            Divider()
            content
            Divider()
            HStack {
                Button(model.hidden ? "Mostrar todo" : "Ocultar todo") { model.hidden ? model.onShowAll?() : model.onHide?() }
                Spacer()
                if let selected = model.selected {
                    Text(selected.name).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .controlSize(.small)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
        }
        .frame(width: 300, height: 380)
        .onAppear {
            model.load()
            searching = true
        }
    }

    @ViewBuilder
    private var content: some View {
        if model.loading {
            VStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Leyendo apps del dispositivo…").font(.callout).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let message = model.message {
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(20)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.filtered.isEmpty {
            Text(model.developmentOnly && model.query.isEmpty ? "No hay apps en desarrollo en este dispositivo" : "Sin resultados")
                .font(.callout).multilineTextAlignment(.center).padding(.horizontal, 20).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List(model.filtered) { app in
                Button { model.onPick?(app) } label: { row(app) }
                    .buttonStyle(.plain)
                    .onAppear { model.needIcon(app) }
            }
            .listStyle(.plain)
        }
    }

    private func row(_ app: DeviceApp) -> some View {
        HStack(spacing: 9) {
            Group {
                if let icon = model.icons[app.id] {
                    Image(nsImage: icon).resizable().interpolation(.high)
                } else {
                    RoundedRectangle(cornerRadius: 7, style: .continuous).fill(.quaternary)
                        .overlay(Image(systemName: "app.dashed").foregroundStyle(.secondary))
                }
            }
            .frame(width: 30, height: 30)
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text(app.name).lineLimit(1)
                Text(app.id).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 0)
            if model.selected == app {
                Image(systemName: "checkmark").foregroundStyle(.tint)
            } else if model.remembered == app.id, model.query.isEmpty {
                Text("Última").font(.caption).foregroundStyle(.secondary)
            }
        }
        .contentShape(Rectangle())
    }
}
