import AVFoundation
import Combine
import CoreMedia
import Foundation

enum Resolution: String, CaseIterable, Identifiable {
    case hd720 = "720p"
    case hd1080 = "1080p"

    var id: String { rawValue }
    var label: String { rawValue }

    var preset: AVCaptureSession.Preset {
        switch self {
        case .hd720: .hd1280x720
        case .hd1080: .hd1920x1080
        }
    }

    var size: (width: CGFloat, height: CGFloat) {
        switch self {
        case .hd720: (1280, 720)
        case .hd1080: (1920, 1080)
        }
    }
}

/// Captures the physical camera, rotates each frame, and feeds the virtual camera.
final class CameraPipeline: NSObject, ObservableObject {
    @Published private(set) var cameras: [AVCaptureDevice] = []
    @Published private(set) var cameraAuthorized = true
    @Published private(set) var sinkConnected = false

    @Published var selectedCameraID: String {
        didSet {
            defaults.set(selectedCameraID, forKey: Keys.camera)
            sessionQueue.async { self.configureSession() }
        }
    }

    @Published var rotation: Rotation {
        didSet {
            defaults.set(rotation.rawValue, forKey: Keys.rotation)
            rotator.rotation = rotation
        }
    }

    @Published var squareCrop: Bool {
        didSet {
            defaults.set(squareCrop, forKey: Keys.squareCrop)
            rotator.squareCrop = squareCrop
        }
    }

    @Published var resolution: Resolution {
        didSet {
            defaults.set(resolution.rawValue, forKey: Keys.resolution)
            sessionQueue.async { self.configureSession() }
        }
    }

    let previewLayer = AVSampleBufferDisplayLayer()

    var outputAspectRatio: CGFloat {
        if squareCrop { return 1 }
        let size = resolution.size
        return rotation.swapsDimensions ? size.height / size.width : size.width / size.height
    }

    private enum Keys {
        static let camera = "selectedCameraID"
        static let rotation = "rotation"
        static let resolution = "resolution"
        static let squareCrop = "squareCrop"
    }

    private let defaults = UserDefaults.standard
    private let session = AVCaptureSession()
    private let output = AVCaptureVideoDataOutput()
    private var input: AVCaptureDeviceInput?
    private let sessionQueue = DispatchQueue(label: BasicCam.appBundleID + ".session")
    private let captureQueue = DispatchQueue(label: BasicCam.appBundleID + ".capture", qos: .userInteractive)
    private let rotator = FrameRotator()
    private let sink = SinkWriter()
    private var sinkRetryTimer: DispatchSourceTimer?
    private var started = false

    private let discovery = AVCaptureDevice.DiscoverySession(
        deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera],
        mediaType: .video,
        position: .unspecified
    )
    private var discoveryObservation: NSKeyValueObservation?
    private var disconnectObserver: NSObjectProtocol?

    override init() {
        selectedCameraID = defaults.string(forKey: Keys.camera) ?? ""
        rotation = Rotation(rawValue: defaults.integer(forKey: Keys.rotation)) ?? .degrees0
        resolution = Resolution(rawValue: defaults.string(forKey: Keys.resolution) ?? "") ?? .hd720
        squareCrop = defaults.object(forKey: Keys.squareCrop) as? Bool ?? true
        super.init()

        rotator.rotation = rotation
        rotator.squareCrop = squareCrop
        configurePreviewClock()
        refreshCameras()
        discoveryObservation = discovery.observe(\.devices) { [weak self] _, _ in
            DispatchQueue.main.async { self?.refreshCameras() }
        }
        disconnectObserver = NotificationCenter.default.addObserver(
            forName: AVCaptureDevice.wasDisconnectedNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let device = note.object as? AVCaptureDevice, device.uniqueID == BasicCam.deviceUID else { return }
            self?.captureQueue.async { self?.dropSink() }
        }
    }

    // MARK: Lifecycle

    func start() {
        guard !started else { return }
        started = true
        AVCaptureDevice.requestAccess(for: .video) { granted in
            DispatchQueue.main.async {
                self.cameraAuthorized = granted
                guard granted else { return }
                self.sessionQueue.async {
                    self.configureSession()
                    self.session.startRunning()
                }
                self.captureQueue.async { self.startSinkRetry() }
            }
        }
    }

    private func refreshCameras() {
        let list = discovery.devices.filter { $0.uniqueID != BasicCam.deviceUID }
        cameras = list
        if !list.contains(where: { $0.uniqueID == selectedCameraID }), let first = list.first {
            selectedCameraID = first.uniqueID
        }
    }

    private func configurePreviewClock() {
        var timebase: CMTimebase?
        CMTimebaseCreateWithSourceClock(allocator: kCFAllocatorDefault, sourceClock: CMClockGetHostTimeClock(), timebaseOut: &timebase)
        guard let timebase else { return }
        CMTimebaseSetRate(timebase, rate: 1.0)
        CMTimebaseSetTime(timebase, time: CMClockGetTime(CMClockGetHostTimeClock()))
        previewLayer.controlTimebase = timebase
    }

    // MARK: Capture session (sessionQueue)

    private func configureSession() {
        let cameraID = DispatchQueue.main.sync { selectedCameraID }
        let preset = DispatchQueue.main.sync { resolution.preset }

        session.beginConfiguration()
        defer { session.commitConfiguration() }

        if session.canSetSessionPreset(preset) {
            session.sessionPreset = preset
        } else if session.canSetSessionPreset(.hd1280x720) {
            session.sessionPreset = .hd1280x720
        }

        if let input {
            session.removeInput(input)
            self.input = nil
        }
        guard let device = AVCaptureDevice(uniqueID: cameraID),
              let newInput = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(newInput) else { return }
        session.addInput(newInput)
        input = newInput

        if !session.outputs.contains(output) {
            output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: BasicCam.pixelFormat]
            output.alwaysDiscardsLateVideoFrames = true
            output.setSampleBufferDelegate(self, queue: captureQueue)
            if session.canAddOutput(output) {
                session.addOutput(output)
            }
        }
    }

    // MARK: Sink connection (captureQueue)

    private func startSinkRetry() {
        guard sinkRetryTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: captureQueue)
        timer.schedule(deadline: .now(), repeating: 2.0)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            if self.sink.connect() {
                self.sinkRetryTimer?.cancel()
                self.sinkRetryTimer = nil
                DispatchQueue.main.async { self.sinkConnected = true }
            }
        }
        timer.resume()
        sinkRetryTimer = timer
    }

    private func dropSink() {
        sink.disconnect()
        DispatchQueue.main.async { self.sinkConnected = false }
        startSinkRetry()
    }
}

extension CameraPipeline: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let rotated = rotator.rotate(sampleBuffer) else { return }
        sink.write(rotated)
        if previewLayer.sampleBufferRenderer.isReadyForMoreMediaData {
            previewLayer.sampleBufferRenderer.enqueue(rotated)
        }
    }
}
