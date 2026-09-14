import CoreMediaIO
import Foundation
import os

/// The stream that camera clients (Zoom, FaceTime, QuickTime) read from.
/// Frames normally arrive from the sink stream. When the host app is not
/// sending, a timer emits black frames so clients keep a live picture.
final class SourceStream: NSObject, CMIOExtensionStreamSource {
    private(set) var stream: CMIOExtensionStream!
    let formats: [CMIOExtensionStreamFormat]

    /// Index of the format that matches the frames currently being forwarded.
    /// Read from the client queue, the sink queue, and the placeholder timer.
    var activeFormatIndex: Int {
        get { formatIndex.withLock { $0 } }
        set { formatIndex.withLock { $0 = newValue } }
    }

    private let formatIndex = OSAllocatedUnfairLock<Int>(initialState: 0)

    private let logger = Logger(subsystem: BasicCam.extensionBundleID, category: "source")
    private let timerQueue = DispatchQueue(label: BasicCam.extensionBundleID + ".placeholder")
    private var placeholderTimer: DispatchSourceTimer?
    private let lastLiveFrame = OSAllocatedUnfairLock<UInt64>(initialState: 0)
    private var placeholderBuffers: [Int: CVPixelBuffer] = [:]

    /// The sink is considered silent after this many nanoseconds without a frame.
    private let liveTimeout: UInt64 = 500_000_000

    init(formats: [CMIOExtensionStreamFormat]) {
        self.formats = formats
        super.init()
        stream = CMIOExtensionStream(
            localizedName: "\(BasicCam.deviceName) Video",
            streamID: UUID(),
            direction: .source,
            clockType: .hostTime,
            source: self
        )
    }

    // MARK: Forwarding

    /// Forwards a frame received on the sink stream. Called on the sink's queue.
    func forward(_ sampleBuffer: CMSampleBuffer) {
        updateActiveFormat(for: sampleBuffer)
        lastLiveFrame.withLock { $0 = hostTimeNanoseconds() }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        stream.send(
            sampleBuffer,
            discontinuity: [],
            hostTimeInNanoseconds: UInt64(pts.seconds * Double(NSEC_PER_SEC))
        )
    }

    private func updateActiveFormat(for sampleBuffer: CMSampleBuffer) {
        guard let description = CMSampleBufferGetFormatDescription(sampleBuffer) else { return }
        let dims = CMVideoFormatDescriptionGetDimensions(description)
        let current = StreamFormats.dimensions(of: formats[activeFormatIndex])
        if current.width == dims.width && current.height == dims.height { return }
        guard let index = formats.firstIndex(where: {
            let d = StreamFormats.dimensions(of: $0)
            return d.width == dims.width && d.height == dims.height
        }) else { return }
        activeFormatIndex = index
        stream.notifyPropertiesChanged([
            .streamActiveFormatIndex: CMIOExtensionPropertyState<AnyObject>(value: index as NSNumber),
        ])
    }

    // MARK: CMIOExtensionStreamSource

    var availableProperties: Set<CMIOExtensionProperty> {
        [.streamActiveFormatIndex, .streamFrameDuration]
    }

    func streamProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionStreamProperties {
        let result = CMIOExtensionStreamProperties(dictionary: [:])
        if properties.contains(.streamActiveFormatIndex) {
            result.activeFormatIndex = activeFormatIndex
        }
        if properties.contains(.streamFrameDuration) {
            result.frameDuration = CMTime(value: 1, timescale: BasicCam.frameRate)
        }
        return result
    }

    func setStreamProperties(_ streamProperties: CMIOExtensionStreamProperties) throws {
        if let index = streamProperties.activeFormatIndex, formats.indices.contains(index) {
            activeFormatIndex = index
        }
    }

    func authorizedToStartStream(for client: CMIOExtensionClient) -> Bool {
        true
    }

    func startStream() throws {
        timerQueue.async { self.startPlaceholderTimer() }
    }

    func stopStream() throws {
        timerQueue.async { self.stopPlaceholderTimer() }
    }

    // MARK: Placeholder frames

    private func startPlaceholderTimer() {
        guard placeholderTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: timerQueue)
        timer.schedule(deadline: .now(), repeating: 1.0 / Double(BasicCam.frameRate), leeway: .milliseconds(2))
        timer.setEventHandler { [weak self] in self?.placeholderTick() }
        timer.resume()
        placeholderTimer = timer
    }

    private func stopPlaceholderTimer() {
        placeholderTimer?.cancel()
        placeholderTimer = nil
    }

    private func placeholderTick() {
        let now = hostTimeNanoseconds()
        let last = lastLiveFrame.withLock { $0 }
        guard now - last > liveTimeout else { return }
        guard let sampleBuffer = makePlaceholderSampleBuffer() else { return }
        stream.send(sampleBuffer, discontinuity: [], hostTimeInNanoseconds: now)
    }

    private func makePlaceholderSampleBuffer() -> CMSampleBuffer? {
        let index = activeFormatIndex
        let format = formats[index]
        guard let pixelBuffer = placeholderPixelBuffer(for: index) else { return nil }
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: BasicCam.frameRate),
            presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
            decodeTimeStamp: .invalid
        )
        var sampleBuffer: CMSampleBuffer?
        let status = CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescription: format.formatDescription,
            sampleTiming: &timing,
            sampleBufferOut: &sampleBuffer
        )
        if status != noErr {
            logger.error("placeholder sample buffer failed: \(status)")
        }
        return sampleBuffer
    }

    private func placeholderPixelBuffer(for index: Int) -> CVPixelBuffer? {
        if let cached = placeholderBuffers[index] { return cached }
        let dims = StreamFormats.dimensions(of: formats[index])
        var pixelBuffer: CVPixelBuffer?
        let attributes: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary]
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            Int(dims.width),
            Int(dims.height),
            BasicCam.pixelFormat,
            attributes as CFDictionary,
            &pixelBuffer
        )
        guard status == kCVReturnSuccess, let pixelBuffer else {
            logger.error("placeholder pixel buffer failed: \(status)")
            return nil
        }
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        if let base = CVPixelBufferGetBaseAddress(pixelBuffer) {
            // Opaque black in BGRA.
            var black: UInt32 = 0xFF00_0000
            let length = CVPixelBufferGetBytesPerRow(pixelBuffer) * Int(dims.height)
            memset_pattern4(base, &black, length)
        }
        CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
        placeholderBuffers[index] = pixelBuffer
        return pixelBuffer
    }
}
