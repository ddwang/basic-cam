import CoreMediaIO
import Foundation
import os

/// The stream the host app writes rotated frames into.
final class SinkStream: NSObject, CMIOExtensionStreamSource {
    private(set) var stream: CMIOExtensionStream!
    let formats: [CMIOExtensionStreamFormat]
    var activeFormatIndex = 0

    private let logger = Logger(subsystem: SuperBasicCam.extensionBundleID, category: "sink")
    private let onFrame: (CMSampleBuffer) -> Void
    private var client: CMIOExtensionClient?
    private var streaming = false

    init(formats: [CMIOExtensionStreamFormat], onFrame: @escaping (CMSampleBuffer) -> Void) {
        self.formats = formats
        self.onFrame = onFrame
        super.init()
        stream = CMIOExtensionStream(
            localizedName: "\(SuperBasicCam.deviceName) Sink",
            streamID: UUID(),
            direction: .sink,
            clockType: .hostTime,
            source: self
        )
    }

    var availableProperties: Set<CMIOExtensionProperty> {
        [
            .streamActiveFormatIndex, .streamFrameDuration,
            .streamSinkBufferQueueSize, .streamSinkBuffersRequiredForStartup,
            .streamSinkBufferUnderrunCount, .streamSinkEndOfData,
        ]
    }

    func streamProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionStreamProperties {
        let result = CMIOExtensionStreamProperties(dictionary: [:])
        if properties.contains(.streamActiveFormatIndex) {
            result.activeFormatIndex = activeFormatIndex
        }
        if properties.contains(.streamFrameDuration) {
            result.frameDuration = CMTime(value: 1, timescale: SuperBasicCam.frameRate)
        }
        // A short queue keeps latency low: the host drops a frame instead of buffering it.
        if properties.contains(.streamSinkBufferQueueSize) {
            result.sinkBufferQueueSize = 3
        }
        if properties.contains(.streamSinkBuffersRequiredForStartup) {
            result.sinkBuffersRequiredForStartup = 1
        }
        if properties.contains(.streamSinkBufferUnderrunCount) {
            result.sinkBufferUnderrunCount = 0
        }
        if properties.contains(.streamSinkEndOfData) {
            result.sinkEndOfData = 0
        }
        return result
    }

    func setStreamProperties(_ streamProperties: CMIOExtensionStreamProperties) throws {
        if let index = streamProperties.activeFormatIndex, formats.indices.contains(index) {
            activeFormatIndex = index
        }
    }

    func authorizedToStartStream(for client: CMIOExtensionClient) -> Bool {
        // Only the SuperBasicCam host app may feed the virtual camera.
        guard client.signingID == SuperBasicCam.appBundleID else {
            logger.error("rejected sink client \(client.signingID ?? "<unsigned>", privacy: .public)")
            return false
        }
        self.client = client
        return true
    }

    func startStream() throws {
        streaming = true
        if let client {
            consume(from: client)
        }
    }

    func stopStream() throws {
        streaming = false
        client = nil
    }

    /// Pulls one buffer from the host, forwards it, and re-arms itself.
    private func consume(from client: CMIOExtensionClient) {
        guard streaming else { return }
        stream.consumeSampleBuffer(from: client) { [weak self] sampleBuffer, sequenceNumber, _, _, error in
            guard let self else { return }
            if let error {
                self.logger.error("consume failed: \(error.localizedDescription, privacy: .public)")
            }
            if let sampleBuffer {
                self.onFrame(sampleBuffer)
                let output = CMIOExtensionScheduledOutput(
                    sequenceNumber: sequenceNumber,
                    hostTimeInNanoseconds: hostTimeNanoseconds()
                )
                self.stream.notifyScheduledOutputChanged(output)
            }
            self.consume(from: client)
        }
    }
}
