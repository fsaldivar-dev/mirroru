import CoreMedia
import Foundation
import VideoToolbox

/// Mirrors an Android device through adb: H.264 from `screenrecord`, input through `input`.
/// Needs nothing installed on the phone beyond USB debugging.
final class AndroidSource: FrameSource, InputControl {
    var onFrame: ((CVPixelBuffer) -> Void)?
    var onEnd: ((String) -> Void)?

    private let serial: String
    private let queue = DispatchQueue(label: "mirroru.android")
    private let decoder = H264Decoder()
    private var stream: Process?
    private var shell: Process?
    private var shellInput: FileHandle?
    private var running = false
    private var quickFailures = 0
    private var physicalSize = CGSize.zero
    private var frameSize = CGSize.zero

    init(serial: String) {
        self.serial = serial
        decoder.onFrame = { [weak self] buffer in
            guard let self else { return }
            self.frameSize = CGSize(width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer))
            self.onFrame?(buffer)
        }
    }

    func start() {
        queue.async {
            self.running = true
            self.readPhysicalSize()
            self.openShell()
            self.launchStream()
        }
    }

    func stop() {
        queue.async {
            self.running = false
            self.stream?.terminate()
            self.shell?.terminate()
            self.stream = nil
            self.shell = nil
            self.shellInput = nil
        }
    }

    func nativeScreenshot() -> Data? {
        guard let data = ADB.output(["-s", serial, "exec-out", "screencap", "-p"]), data.count > 8 else { return nil }
        return data
    }

    // MARK: Video

    private func launchStream() {
        // screenrecord stops by itself after 180 s at most, so it is simply relaunched.
        guard running, let p = ADB.process(["-s", serial, "exec-out", "screenrecord", "--output-format=h264",
                                            "--bit-rate", "8000000", "--time-limit", "180", "-"]) else {
            if running { finish("No se encontró adb. Instala Android platform-tools.") }
            return
        }
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        let started = Date()
        decoder.reset()
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            self?.queue.async { self?.decoder.feed(data, on: self!.queue) }
        }
        p.terminationHandler = { [weak self] _ in
            self?.queue.async {
                guard let self, self.running else { return }
                self.quickFailures = Date().timeIntervalSince(started) < 2 ? self.quickFailures + 1 : 0
                if self.quickFailures >= 3 {
                    self.finish("Dispositivo desconectado")
                } else {
                    self.queue.asyncAfter(deadline: .now() + 0.3) { self.launchStream() }
                }
            }
        }
        do {
            try p.run()
            stream = p
        } catch {
            finish("No se pudo ejecutar adb: \(error.localizedDescription)")
        }
    }

    private func finish(_ message: String) {
        running = false
        shell?.terminate()
        onEnd?(message)
    }

    // MARK: Input

    private func readPhysicalSize() {
        guard let data = ADB.output(["-s", serial, "shell", "wm", "size"]),
              let text = String(data: data, encoding: .utf8) else { return }
        // "Physical size: 1080x2400" and optionally "Override size: …" (the override wins).
        for line in text.split(separator: "\n") {
            guard let dims = line.split(separator: ":").last?.trimmingCharacters(in: .whitespaces).split(separator: "x"),
                  dims.count == 2, let w = Double(dims[0]), let h = Double(dims[1]) else { continue }
            physicalSize = CGSize(width: w, height: h)
        }
    }

    /// One long-lived `adb shell` so each gesture does not pay adb's startup cost.
    private func openShell() {
        guard let p = ADB.process(["-s", serial, "shell"]) else { return }
        let pipe = Pipe()
        p.standardInput = pipe
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do {
            try p.run()
            shell = p
            shellInput = pipe.fileHandleForWriting
        } catch {}
    }

    private func send(_ command: String) {
        queue.async {
            guard self.running, let handle = self.shellInput, self.shell?.isRunning == true else { return }
            try? handle.write(contentsOf: Data((command + "\n").utf8))
        }
    }

    /// Normalized point -> pixels in the device's current orientation.
    private func pixels(_ p: CGPoint) -> (Int, Int) {
        var size = physicalSize == .zero ? frameSize : physicalSize
        let frameIsLandscape = frameSize.width > frameSize.height
        if frameSize != .zero, frameIsLandscape != (size.width > size.height) {
            size = CGSize(width: size.height, height: size.width)
        }
        return (Int(p.x * size.width), Int(p.y * size.height))
    }

    func tap(_ p: CGPoint) {
        let (x, y) = pixels(p)
        send("input tap \(x) \(y)")
    }

    func longPress(_ p: CGPoint) {
        let (x, y) = pixels(p)
        send("input swipe \(x) \(y) \(x) \(y) 600")
    }

    func swipe(from: CGPoint, to: CGPoint, duration: TimeInterval) {
        let (x1, y1) = pixels(from), (x2, y2) = pixels(to)
        send("input swipe \(x1) \(y1) \(x2) \(y2) \(Int(max(0.05, min(duration, 2)) * 1000))")
    }

    func key(_ code: Int) {
        send("input keyevent \(code)")
    }

    func text(_ s: String) {
        // `input text` only handles printable ASCII; %s is its escape for a space.
        let ascii = s.unicodeScalars.filter { $0.value >= 0x20 && $0.value < 0x7F }.map(Character.init)
        guard !ascii.isEmpty else { return }
        let escaped = String(ascii)
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: " ", with: "%s")
            .replacingOccurrences(of: "'", with: "'\\''")
        send("input text '\(escaped)'")
    }
}

// MARK: - H.264 Annex B -> CVPixelBuffer

final class H264Decoder {
    var onFrame: ((CVPixelBuffer) -> Void)?

    private var buffer = [UInt8]()
    private var sps: [UInt8]?
    private var pps: [UInt8]?
    private var format: CMVideoFormatDescription?
    private var session: VTDecompressionSession?
    private var sawKeyframe = false
    private var flush: DispatchWorkItem?

    func reset() {
        flush?.cancel()
        buffer.removeAll(keepingCapacity: true)
        sps = nil
        pps = nil
        invalidate()
    }

    private func invalidate() {
        if let session { VTDecompressionSessionInvalidate(session) }
        session = nil
        format = nil
        sawKeyframe = false
    }

    /// `queue` is the serial queue this decoder is used on.
    func feed(_ data: Data, on queue: DispatchQueue) {
        buffer.append(contentsOf: data)
        drain(final: false)
        // A NAL unit is only known to be complete when the next start code shows up. On a static
        // screen nothing follows, so after a short quiet period treat what we have as complete.
        flush?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.drain(final: true) }
        flush = work
        queue.asyncAfter(deadline: .now() + 0.04, execute: work)
    }

    private func drain(final: Bool) {
        var consumed = 0
        var units: [[UInt8]] = []
        buffer.withUnsafeBufferPointer { b in
            let n = b.count
            func startCode(from: Int) -> Int? {
                var i = from
                while i + 2 < n {
                    if b[i + 2] > 1 { i += 3 }
                    else if b[i] == 0, b[i + 1] == 0, b[i + 2] == 1 { return i }
                    else { i += 1 }
                }
                return nil
            }
            guard var start = startCode(from: 0) else {
                consumed = max(0, n - 3)
                return
            }
            while true {
                let payload = start + 3
                if let next = startCode(from: payload) {
                    var end = next
                    while end > payload, b[end - 1] == 0 { end -= 1 }
                    if end > payload { units.append(Array(b[payload..<end])) }
                    start = next
                    consumed = next
                } else {
                    if final {
                        if n > payload { units.append(Array(b[payload..<n])) }
                        consumed = n
                    } else {
                        consumed = start
                    }
                    break
                }
            }
        }
        if consumed > 0 { buffer.removeFirst(consumed) }
        units.forEach(handle)
    }

    private func handle(_ nal: [UInt8]) {
        switch nal[0] & 0x1F {
        case 7:
            if sps != nal { sps = nal; invalidate() }
        case 8:
            if pps != nal { pps = nal; invalidate() }
        case 5:
            sawKeyframe = true
            decode(nal)
        case 1:
            if sawKeyframe { decode(nal) }
        default:
            break
        }
    }

    private func prepareSession() -> Bool {
        if session != nil { return true }
        guard let sps, let pps else { return false }
        var description: CMVideoFormatDescription?
        sps.withUnsafeBufferPointer { s in
            pps.withUnsafeBufferPointer { p in
                let pointers = [s.baseAddress!, p.baseAddress!]
                let sizes = [s.count, p.count]
                CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault, parameterSetCount: 2, parameterSetPointers: pointers,
                    parameterSetSizes: sizes, nalUnitHeaderLength: 4, formatDescriptionOut: &description)
            }
        }
        guard let description else { return false }
        let attributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        ]
        var created: VTDecompressionSession?
        VTDecompressionSessionCreate(allocator: kCFAllocatorDefault, formatDescription: description,
                                     decoderSpecification: nil, imageBufferAttributes: attributes as CFDictionary,
                                     outputCallback: nil, decompressionSessionOut: &created)
        guard let created else { return false }
        format = description
        session = created
        return true
    }

    private func decode(_ nal: [UInt8]) {
        guard prepareSession(), let session, let format else { return }
        let length = nal.count + 4
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: length, blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil, offsetToData: 0, dataLength: length, flags: kCMBlockBufferAssureMemoryNowFlag,
            blockBufferOut: &block) == noErr, let block else { return }
        var header = UInt32(nal.count).bigEndian
        CMBlockBufferReplaceDataBytes(with: &header, blockBuffer: block, offsetIntoDestination: 0, dataLength: 4)
        nal.withUnsafeBytes { bytes in
            _ = CMBlockBufferReplaceDataBytes(with: bytes.baseAddress!, blockBuffer: block,
                                              offsetIntoDestination: 4, dataLength: nal.count)
        }
        var sample: CMSampleBuffer?
        var sizes = [length]
        guard CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format, sampleCount: 1,
            sampleTimingEntryCount: 0, sampleTimingArray: nil, sampleSizeEntryCount: 1, sampleSizeArray: &sizes,
            sampleBufferOut: &sample) == noErr, let sample else { return }
        let status = VTDecompressionSessionDecodeFrame(session, sampleBuffer: sample, flags: [], infoFlagsOut: nil) {
            [weak self] status, _, image, _, _ in
            if status == noErr, let image { self?.onFrame?(image) }
        }
        if status == kVTInvalidSessionErr { invalidate() }
    }
}
