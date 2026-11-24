import CoreGraphics
import CoreVideo
import Foundation

/// Synthetic animated screen, for trying the UI and the capture pipeline without a phone.
final class DemoSource: FrameSource {
    var onFrame: ((CVPixelBuffer) -> Void)?
    var onEnd: ((String) -> Void)?

    private let queue = DispatchQueue(label: "mirroru.demo")
    private var timer: DispatchSourceTimer?
    private var tick = 0
    private let width = 390, height = 844

    func start() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: 1.0 / 30)
        t.setEventHandler { [weak self] in self?.render() }
        t.resume()
        timer = t
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    private func render() {
        var made: CVPixelBuffer?
        let attributes: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary]
        CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, attributes as CFDictionary, &made)
        guard let buffer = made else { return }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { return }

        let colors = [CGColor(red: 0.21, green: 0.88, blue: 1, alpha: 1), CGColor(red: 0.54, green: 0.30, blue: 1, alpha: 1)]
        let gradient = CGGradient(colorsSpace: space, colors: colors as CFArray, locations: nil)!
        ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: CGFloat(height)), end: CGPoint(x: CGFloat(width), y: 0), options: [])

        let phase = Double(tick) / 30
        let x = CGFloat(width) / 2 + CGFloat(cos(phase * 1.3)) * 120
        let y = CGFloat(height) / 2 + CGFloat(sin(phase * 2.1)) * 280
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.95))
        ctx.fillEllipse(in: CGRect(x: x - 42, y: y - 42, width: 84, height: 84))
        ctx.setFillColor(CGColor(red: 1, green: 0.23, blue: 0.36, alpha: 1))
        ctx.fillEllipse(in: CGRect(x: x - 26, y: y - 26, width: 52, height: 52))
        tick += 1
        onFrame?(buffer)
    }
}
