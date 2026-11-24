import AVFoundation
import Foundation

/// Mirrors an iPhone/iPad connected by USB. View-only: iOS offers no way to inject touches.
final class IOSSource: NSObject, FrameSource, AVCaptureVideoDataOutputSampleBufferDelegate {
    var onFrame: ((CVPixelBuffer) -> Void)?
    var onEnd: ((String) -> Void)?

    private let device: AVCaptureDevice
    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "mirroru.ios")
    private var gotFrame = false
    private var restarts = 0
    private var stopped = false
    private var observers: [NSObjectProtocol] = []

    init(device: AVCaptureDevice) {
        self.device = device
    }

    func start() {
        AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
            guard let self else { return }
            guard granted else {
                self.end("Sin permiso de cámara. Actívalo en Ajustes del Sistema › Privacidad y seguridad › Cámara.")
                return
            }
            self.queue.async { self.configure() }
        }
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: AVCaptureDevice.wasDisconnectedNotification, object: device, queue: nil) { [weak self] _ in
            self?.end("Dispositivo desconectado")
        })
    }

    private func configure() {
        do {
            let input = try AVCaptureDeviceInput(device: device)
            let output = AVCaptureVideoDataOutput()
            output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
            output.alwaysDiscardsLateVideoFrames = true
            output.setSampleBufferDelegate(self, queue: queue)
            session.beginConfiguration()
            guard session.canAddInput(input), session.canAddOutput(output) else {
                session.commitConfiguration()
                end("No se pudo abrir el dispositivo. Desbloquéalo y pulsa «Confiar» en el teléfono.")
                return
            }
            session.addInput(input)
            session.addOutput(output)
            session.commitConfiguration()
            session.startRunning()
            scheduleWatchdog()
        } catch {
            end("No se pudo abrir el dispositivo: \(error.localizedDescription)")
        }
    }

    /// The first start after plugging in sometimes yields no frames; kick the session a few times.
    private func scheduleWatchdog() {
        queue.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self, !self.stopped, !self.gotFrame else { return }
            guard self.restarts < 3 else {
                self.end("El dispositivo no envía imagen. Desbloquéalo, pulsa «Confiar» y vuelve a conectar el cable.")
                return
            }
            self.restarts += 1
            self.session.stopRunning()
            self.session.startRunning()
            self.scheduleWatchdog()
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        gotFrame = true
        onFrame?(buffer)
    }

    func stop() {
        queue.async {
            self.stopped = true
            if self.session.isRunning { self.session.stopRunning() }
        }
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
    }

    private func end(_ message: String) {
        queue.async {
            guard !self.stopped else { return }
            self.stopped = true
            if self.session.isRunning { self.session.stopRunning() }
            self.onEnd?(message)
        }
    }
}
