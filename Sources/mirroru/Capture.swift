import AVFoundation
import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers

private let ciContext = CIContext()

private func hostTime() -> CMTime {
    CMClockGetTime(CMClockGetHostTimeClock())
}

private func cgImage(from buffer: CVPixelBuffer, maxWidth: CGFloat? = nil) -> CGImage? {
    var image = CIImage(cvPixelBuffer: buffer)
    if let maxWidth, image.extent.width > maxWidth {
        let scale = maxWidth / image.extent.width
        image = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
    }
    return ciContext.createCGImage(image, from: image.extent.integral)
}

enum Output {
    /// "~/Desktop/Mirroru Captura - Pixel 7 - 2026-11-24 14.30.12.png"
    static func url(kind: String, device: String, ext: String) -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let safe = device.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())
        return desktop.appendingPathComponent("Mirroru \(kind) - \(safe) - \(formatter.string(from: Date())).\(ext)")
    }
}

/// Receives every frame and fans it out to the screen, the video recorder and the GIF recorder.
final class FrameHub {
    /// Called on the main queue for every frame.
    var onFrame: ((CVPixelBuffer) -> Void)?

    private let queue = DispatchQueue(label: "mirroru.hub")
    /// What is shown and captured: the device frame, or its blur while hidden.
    private var latest: CVPixelBuffer?
    private var raw: CVPixelBuffer?
    private var hidden = false
    private let blurrer = Blurrer()
    /// Small copies of the last few seconds of device frames (see `Fingerprint`).
    private var recent: [(time: CFTimeInterval, print: Fingerprint)] = []
    private var recorder: Recorder?
    private var gif: GifRecorder?
    /// Seconds each frame waits before it is shown or captured (0 = no wait). See `setHoldback`.
    private var holdback: CFTimeInterval = 0
    /// Frames taken before this moment are never shown clear.
    private var clearSince: CFTimeInterval = 0
    /// Bumped to throw away the frames that are still waiting.
    private var generation = 0
    private var lastHeld: CFTimeInterval = 0

    var hasFrame: Bool { queue.sync { latest != nil } }
    var isRecording: Bool { queue.sync { recorder != nil } }
    var isRecordingGif: Bool { queue.sync { gif != nil } }

    func push(_ buffer: CVPixelBuffer) {
        queue.async {
            self.raw = buffer
            let now = CACurrentMediaTime()
            if now - (self.recent.last?.time ?? 0) >= 0.2, let print = Fingerprint(buffer) {
                self.recent.append((now, print))
                self.recent.removeAll { now - $0.time > 5 }
            }
            self.submit(buffer, at: now)
        }
    }

    /// The news that the user left the app arrives a few tenths of a second late. With a holdback, frames
    /// wait that long before reaching the screen and the captures, so the ones taken in the meantime are
    /// still in hand when the news comes and go out blurred: the other app is never seen, live or recorded.
    func setHoldback(_ seconds: CFTimeInterval) {
        queue.sync { holdback = seconds }
    }

    private func submit(_ buffer: CVPixelBuffer, at time: CFTimeInterval) {
        guard holdback > 0 else { return process(buffer, takenAt: time) }
        // Waiting frames stay in memory, so half the frame rate is enough while they are held.
        guard time - lastHeld >= 1.0 / 31 else { return }
        lastHeld = time
        let generation = generation
        queue.asyncAfter(deadline: .now() + holdback) {
            guard generation == self.generation else { return }
            self.process(buffer, takenAt: time)
        }
    }

    /// How the device screen looked `seconds` ago (the real picture, also while private).
    func fingerprint(secondsAgo seconds: CFTimeInterval) -> Fingerprint? {
        queue.sync {
            let moment = CACurrentMediaTime() - seconds
            return (recent.last { $0.time <= moment } ?? recent.first)?.print
        }
    }

    /// The latest look of the device screen taken between two moments (`CACurrentMediaTime`), if any.
    func fingerprint(between start: CFTimeInterval, and end: CFTimeInterval) -> Fingerprint? {
        queue.sync { recent.last { $0.time >= start && $0.time <= end }?.print }
    }

    /// How the device screen looks now.
    func currentFingerprint() -> Fingerprint? {
        queue.sync { raw.flatMap(Fingerprint.init) }
    }

    /// Private mode: while hidden, every consumer (screen, screenshot, video, GIF) gets a blur.
    /// `settle`: when showing again with a holdback, how much longer the picture stays private, for devices
    /// that report the new app before its opening animation (still showing the previous screen) is over.
    func setHidden(_ hidden: Bool, settle: CFTimeInterval = 0) {
        queue.sync {
            guard hidden != self.hidden else { return }
            self.hidden = hidden
            let now = CACurrentMediaTime()
            // Whatever was waiting belongs to the previous state: drop it.
            generation += 1
            if hidden {
                if let raw { process(raw, takenAt: now) }
            } else if holdback > 0 {
                // Frames from before this moment may still show the app the user is coming back from.
                clearSince = now + settle
                // A still screen sends no more frames, so the current one is sent again once it may be shown.
                let generation = generation
                queue.asyncAfter(deadline: .now() + settle + 0.02) {
                    guard generation == self.generation, let raw = self.raw else { return }
                    self.lastHeld = 0
                    self.submit(raw, at: CACurrentMediaTime())
                }
            } else if let raw {
                // Sources like Android only send frames when the screen changes: redo the current one now.
                clearSince = 0
                process(raw, takenAt: now)
            }
        }
    }

    private func process(_ source: CVPixelBuffer, takenAt time: CFTimeInterval) {
        // If the blur fails the frame is dropped: a private frame is never passed on as is.
        guard let buffer = hidden || time < clearSince ? blurrer.blur(source) : source else { return }
        latest = buffer
        recorder?.append(buffer)
        if gif?.append(buffer) == false { gifLimitReached?() }
        DispatchQueue.main.async { self.onFrame?(buffer) }
    }

    /// Called (on the hub queue) when a GIF hits its frame cap and should be stopped.
    var gifLimitReached: (() -> Void)?

    func screenshot(to url: URL) -> Bool {
        guard let buffer = queue.sync(execute: { latest }), let image = cgImage(from: buffer),
              let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { return false }
        CGImageDestinationAddImage(dest, image, nil)
        return CGImageDestinationFinalize(dest)
    }

    func startRecording(to url: URL) {
        queue.async {
            guard self.recorder == nil else { return }
            self.recorder = Recorder(url: url)
            // Sources like Android only send frames when the screen changes: seed with what is on screen now.
            if let latest = self.latest { self.recorder?.append(latest) }
        }
    }

    func stopRecording(completion: @escaping (URL?) -> Void) {
        queue.async {
            guard let recorder = self.recorder else { return DispatchQueue.main.async { completion(nil) } }
            self.recorder = nil
            recorder.finish { url in DispatchQueue.main.async { completion(url) } }
        }
    }

    func startGif(to url: URL) {
        queue.async {
            guard self.gif == nil else { return }
            self.gif = GifRecorder(url: url)
            if let latest = self.latest { _ = self.gif?.append(latest) }
        }
    }

    func stopGif(completion: @escaping (URL?) -> Void) {
        queue.async {
            guard let gif = self.gif else { return DispatchQueue.main.async { completion(nil) } }
            self.gif = nil
            let url = gif.finish()
            DispatchQueue.main.async { completion(url) }
        }
    }
}

// MARK: - Video (.mp4, H.264)

final class Recorder {
    let url: URL
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var lastBuffer: CVPixelBuffer?
    private var lastTime = CMTime.invalid

    init(url: URL) {
        self.url = url
    }

    private func begin(with buffer: CVPixelBuffer, at time: CMTime) -> Bool {
        try? FileManager.default.removeItem(at: url)
        guard let writer = try? AVAssetWriter(outputURL: url, fileType: .mp4) else { return false }
        let width = CVPixelBufferGetWidth(buffer) & ~1, height = CVPixelBufferGetHeight(buffer) & ~1
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
        ])
        input.expectsMediaDataInRealTime = true
        guard writer.canAdd(input) else { return false }
        writer.add(input)
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
        guard writer.startWriting() else { return false }
        writer.startSession(atSourceTime: time)
        self.writer = writer
        self.input = input
        self.adaptor = adaptor
        return true
    }

    func append(_ buffer: CVPixelBuffer) {
        append(buffer, at: hostTime())
    }

    private func append(_ buffer: CVPixelBuffer, at time: CMTime) {
        if writer == nil, !begin(with: buffer, at: time) { return }
        guard let input, let adaptor, input.isReadyForMoreMediaData else { return }
        if lastTime.isValid, time <= lastTime { return }
        if adaptor.append(buffer, withPresentationTime: time) {
            lastTime = time
            lastBuffer = buffer
        }
    }

    func finish(completion: @escaping (URL?) -> Void) {
        guard let writer, let input else { return completion(nil) }
        // Hold the last frame until now, so a static ending keeps its real duration.
        let now = hostTime()
        if let lastBuffer { append(lastBuffer, at: now) }
        input.markAsFinished()
        writer.endSession(atSourceTime: now)
        let url = self.url
        writer.finishWriting {
            completion(writer.status == .completed ? url : nil)
        }
    }
}

// MARK: - GIF

final class GifRecorder {
    let url: URL
    private var frames: [(image: CGImage, time: CFTimeInterval)] = []
    private let interval: CFTimeInterval = 1.0 / 12
    private let maxFrames = 600
    private let maxWidth: CGFloat = 360

    init(url: URL) {
        self.url = url
    }

    /// Returns false once the frame cap is reached.
    func append(_ buffer: CVPixelBuffer) -> Bool {
        guard frames.count < maxFrames else { return false }
        let now = CACurrentMediaTime()
        if let last = frames.last, now - last.time < interval { return true }
        if let image = cgImage(from: buffer, maxWidth: maxWidth) { frames.append((image, now)) }
        return true
    }

    func finish() -> URL? {
        guard !frames.isEmpty,
              let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString, frames.count, nil)
        else { return nil }
        let end = CACurrentMediaTime()
        CGImageDestinationSetProperties(dest, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        for (index, frame) in frames.enumerated() {
            let next = index + 1 < frames.count ? frames[index + 1].time : end
            let delay = max(0.04, min(next - frame.time, 5))
            let properties = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFUnclampedDelayTime: delay,
                                                             kCGImagePropertyGIFDelayTime: delay]]
            CGImageDestinationAddImage(dest, frame.image, properties as CFDictionary)
        }
        return CGImageDestinationFinalize(dest) ? url : nil
    }
}
