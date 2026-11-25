import AppKit
import Foundation

let version = "0.2.0"

let usage = """
Mirroru \(version) — espejo de Android e iOS por USB, sin cuentas.

USO
  mirroru [open] [-d <dispositivo>]      Abre la ventana de espejo (una por dispositivo)
  mirroru devices                        Lista los dispositivos conectados
  mirroru screenshot [-d …] [-o a.png]   Guarda una captura y termina
  mirroru record [-d …] [-o a.mp4] [-t s] Graba video; Ctrl-C (o -t segundos) para terminar
  mirroru gif [-d …] [-o a.gif] [-t s]   Igual que record, pero genera un GIF

OPCIONES
  -d, --device <texto>   Serial, nombre (o parte) o plataforma: android / ios
  -o, --output <ruta>    Archivo de salida (por defecto, el Escritorio)
  -t, --time <segundos>  Duración de record / gif
      --demo             Fuente sintética, para probar sin teléfono
  -h, --help             Esta ayuda
  -v, --version          Versión

EN LA VENTANA
  ⌘S captura · ⌘R video · ⌘G GIF
  Android: clic = toque, arrastrar = deslizar, clic derecho = Atrás, teclado = texto
  iOS: solo visualización y captura (iOS no permite control externo)
"""

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("mirroru: \(message)\n".utf8))
    exit(1)
}

// MARK: Arguments

var command = "open"
var deviceFilter: String?
var outputPath: String?
var seconds: Double?
var demo = false

var arguments = Array(CommandLine.arguments.dropFirst())
if let first = arguments.first, !first.hasPrefix("-") {
    command = first
    arguments.removeFirst()
}
while !arguments.isEmpty {
    let flag = arguments.removeFirst()
    func value() -> String {
        guard !arguments.isEmpty else { fail("falta el valor de \(flag)") }
        return arguments.removeFirst()
    }
    switch flag {
    case "-d", "--device": deviceFilter = value()
    case "-o", "--output": outputPath = value()
    case "-t", "--time":
        guard let t = Double(value()), t > 0 else { fail("-t espera un número de segundos") }
        seconds = t
    case "--demo": demo = true
    case "-h", "--help": command = "help"
    case "-v", "--version": command = "version"
    default: fail("opción desconocida: \(flag)\n\n\(usage)")
    }
}

// MARK: Headless helpers

func pickDevice() -> Device {
    if demo { return .demo }
    let all = discoverDevices(iosWait: 1.5)
    let candidates = all.filter { d in deviceFilter.map(d.matches) ?? true }
    guard let device = candidates.first(where: \.ready) else {
        if let blocked = candidates.first {
            fail("\(blocked.name) no está autorizado (\(blocked.detail)). Acepta la depuración USB en el teléfono.")
        }
        fail(all.isEmpty ? "no hay dispositivos conectados" : "ningún dispositivo coincide con «\(deviceFilter ?? "")»")
    }
    return device
}

func outputURL(kind: String, device: Device, ext: String) -> URL {
    if let outputPath { return URL(fileURLWithPath: (outputPath as NSString).expandingTildeInPath) }
    return Output.url(kind: kind, device: device.name, ext: ext)
}

func startHeadless(_ device: Device, hub: FrameHub) -> FrameSource {
    guard let source = makeSource(for: device) else { fail("no se pudo abrir \(device.name)") }
    source.onFrame = { hub.push($0) }
    source.onEnd = { fail($0) }
    source.start()
    DispatchQueue.main.asyncAfter(deadline: .now() + 15) {
        if !hub.hasFrame { fail("\(device.name) no envió imagen en 15 s (¿está desbloqueado?)") }
    }
    return source
}

// MARK: Commands

switch command {
case "help":
    print(usage)

case "version":
    print(version)

case "devices":
    let devices = discoverDevices(iosWait: 1.5)
    if devices.isEmpty {
        print("No hay dispositivos. Conecta por USB (iPhone: «Confiar»; Android: depuración USB).")
    }
    for d in devices {
        let platform = d.platform.rawValue.padding(toLength: 8, withPad: " ", startingAt: 0)
        print("\(platform) \(d.name.padding(toLength: 26, withPad: " ", startingAt: 0)) \(d.detail)")
    }

case "screenshot":
    let device = pickDevice()
    let url = outputURL(kind: "Captura", device: device, ext: "png")
    let hub = FrameHub()
    let source = makeSource(for: device)
    // Android can hand over a lossless PNG without starting a video stream.
    if let png = source?.nativeScreenshot() {
        do { try png.write(to: url) } catch { fail("no se pudo escribir \(url.path)") }
        print(url.path)
        exit(0)
    }
    var taken = false
    hub.onFrame = { _ in
        guard !taken else { return }
        taken = true
        // Let a couple of frames through: the very first iOS frame can be blank.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            guard hub.screenshot(to: url) else { fail("no se pudo escribir \(url.path)") }
            print(url.path)
            exit(0)
        }
    }
    let running = startHeadless(device, hub: hub)
    withExtendedLifetime(running) { dispatchMain() }

case "record", "gif":
    let device = pickDevice()
    let isGif = command == "gif"
    let url = outputURL(kind: isGif ? "GIF" : "Video", device: device, ext: isGif ? "gif" : "mp4")
    let hub = FrameHub()
    var started = false
    var finishing = false
    func finish() {
        guard !finishing else { return }
        finishing = true
        let done: (URL?) -> Void = { saved in
            guard let saved else { fail("no se grabó nada") }
            print(saved.path)
            exit(0)
        }
        isGif ? hub.stopGif(completion: done) : hub.stopRecording(completion: done)
    }
    hub.gifLimitReached = { DispatchQueue.main.async { finish() } }
    hub.onFrame = { _ in
        guard !started else { return }
        started = true
        isGif ? hub.startGif(to: url) : hub.startRecording(to: url)
        FileHandle.standardError.write(Data("Grabando \(device.name)… Ctrl-C para terminar\n".utf8))
        if let seconds { DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { finish() } }
    }
    signal(SIGINT, SIG_IGN)
    let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
    interrupt.setEventHandler { if started { finish() } else { exit(130) } }
    interrupt.resume()
    let running = startHeadless(device, hub: hub)
    withExtendedLifetime((running, interrupt)) { dispatchMain() }

case "open":
    // From a terminal, relaunch through LaunchServices so macOS treats Mirroru as its own app:
    // the camera permission iOS mirroring needs is then requested by (and granted to) Mirroru itself.
    let executable = URL(fileURLWithPath: Bundle.main.executablePath ?? CommandLine.arguments[0]).resolvingSymlinksInPath()
    let bundle = executable.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    if bundle.pathExtension == "app", ProcessInfo.processInfo.environment["MIRRORU_APP"] == nil {
        var forwarded = ["open"]
        if let deviceFilter { forwarded += ["-d", deviceFilter] }
        if demo { forwarded.append("--demo") }
        let launcher = Process()
        launcher.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        launcher.arguments = ["-n", "-a", bundle.path, "--env", "MIRRORU_APP=1", "--args"] + forwarded
        do { try launcher.run() } catch { fail("no se pudo abrir \(bundle.path)") }
        launcher.waitUntilExit()
        exit(launcher.terminationStatus)
    }
    let app = NSApplication.shared
    let delegate = AppDelegate(options: AppOptions(deviceFilter: deviceFilter, demo: demo))
    app.delegate = delegate
    app.setActivationPolicy(.regular)
    app.run()

default:
    fail("comando desconocido: \(command)\n\n\(usage)")
}
