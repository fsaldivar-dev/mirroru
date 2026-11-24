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
    private var latest: CVPixelBuffer?
    private var recorder: Recorder?
    private var gif: GifRecorder?

    var hasFrame: Bool { queue.sync { latest != nil } }
    var isRecording: Bool { queue.sync { recorder != nil } }
    var isRecordingGif: Bool { queue.sync { gif != nil } }

    func push(_ buffer: CVPixelBuffer) {
        queue.async {
            self.latest = buffer
            self.recorder?.append(buffer)
            if self.gif?.append(buffer) == false { self.gifLimitReached?() }
            DispatchQueue.main.async { self.onFrame?(buffer) }
        }
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
