import AVFoundation
import CoreMediaIO
import Foundation

enum Platform: String {
    case android = "Android"
    case ios = "iOS"
    case demo = "Demo"
}

struct Device {
    let id: String
    let name: String
    let platform: Platform
    let detail: String
    /// false when the device is visible but cannot be mirrored yet (e.g. adb "unauthorized").
    let ready: Bool

    static let demo = Device(id: "demo", name: "Demo", platform: .demo, detail: "fuente sintética", ready: true)

    func matches(_ filter: String) -> Bool {
        let f = filter.lowercased()
        return id.lowercased().hasPrefix(f) || name.lowercased().contains(f) || platform.rawValue.lowercased() == f
    }
}

// MARK: - Sources

/// Something that produces screen frames.
protocol FrameSource: AnyObject {
    var onFrame: ((CVPixelBuffer) -> Void)? { get set }
    /// Called once when the stream cannot continue (device unplugged, permission denied…).
    var onEnd: ((String) -> Void)? { get set }
    func start()
    func stop()
    /// Lossless PNG straight from the device, when the platform offers one.
    func nativeScreenshot() -> Data?
}

extension FrameSource {
    func nativeScreenshot() -> Data? { nil }
}

/// Touch / key injection. Coordinates are normalized (0…1, origin top-left).
protocol InputControl: AnyObject {
    func tap(_ p: CGPoint)
    func longPress(_ p: CGPoint)
    func swipe(from: CGPoint, to: CGPoint, duration: TimeInterval)
    func key(_ code: Int)
    func text(_ s: String)
}

enum AndroidKey {
    static let home = 3, back = 4, up = 19, down = 20, left = 21, right = 22
    static let volumeUp = 24, volumeDown = 25, power = 26, tab = 61, enter = 66, delete = 67, recents = 187
}

func makeSource(for device: Device) -> FrameSource? {
    switch device.platform {
    case .android: return AndroidSource(serial: device.id)
    case .ios: return AVCaptureDevice(uniqueID: device.id).map(IOSSource.init)
    case .demo: return DemoSource()
    }
}

// MARK: - adb

enum ADB {
    static let path: String? = {
        let home = NSHomeDirectory()
        var candidates = (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":").map { "\($0)/adb" }
        if let sdk = ProcessInfo.processInfo.environment["ANDROID_HOME"] { candidates.append("\(sdk)/platform-tools/adb") }
        candidates += ["\(home)/Library/Android/sdk/platform-tools/adb", "/opt/homebrew/bin/adb", "/usr/local/bin/adb"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }()

    static func process(_ args: [String]) -> Process? {
        guard let path else { return nil }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        return p
    }

    /// Runs adb and returns stdout (nil if adb is missing or could not launch).
    static func output(_ args: [String]) -> Data? {
        guard let p = process(args) else { return nil }
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return data
    }

    static func devices() -> [Device] {
        guard let data = output(["devices", "-l"]), let text = String(data: data, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").dropFirst().compactMap { line in
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard parts.count >= 2 else { return nil }
            let serial = parts[0], state = parts[1]
            let model = parts.first { $0.hasPrefix("model:") }?.dropFirst(6).replacingOccurrences(of: "_", with: " ")
            let detail = state == "device" ? serial : "\(serial) (\(state))"
            return Device(id: serial, name: model ?? serial, platform: .android, detail: detail, ready: state == "device")
        }
    }
}

// MARK: - iOS (USB screen capture, same mechanism QuickTime uses; no iCloud involved)

enum IOSDevices {
    /// Opts this process in to seeing iPhones/iPads as capture devices. They show up a moment later.
    static func enableScreenCapture() {
        var address = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyAllowScreenCaptureDevices),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
        var allow: UInt32 = 1
        CMIOObjectSetPropertyData(CMIOObjectID(kCMIOObjectSystemObject), &address, 0, nil,
                                  UInt32(MemoryLayout<UInt32>.size), &allow)
    }

    static func list() -> [Device] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.external], mediaType: .muxed, position: .unspecified)
            .devices.map {
                Device(id: $0.uniqueID, name: $0.localizedName, platform: .ios, detail: $0.modelID, ready: true)
            }
    }
}

/// All currently visible devices. `iosWait` spins the run loop so freshly enabled iOS devices can appear.
func discoverDevices(iosWait: TimeInterval = 0) -> [Device] {
    IOSDevices.enableScreenCapture()
    let android = ADB.devices()
    if iosWait > 0 { RunLoop.current.run(until: Date().addingTimeInterval(iosWait)) }
    return android + IOSDevices.list()
}
