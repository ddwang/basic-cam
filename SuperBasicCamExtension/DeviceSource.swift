import CoreMediaIO
import Foundation
import IOKit.audio

/// One virtual camera with two streams: a source stream that clients read,
/// and a sink stream that the host app writes rotated frames into.
final class DeviceSource: NSObject, CMIOExtensionDeviceSource {
    private(set) var device: CMIOExtensionDevice!
    private var sourceStream: SourceStream!
    private var sinkStream: SinkStream!

    override init() {
        super.init()
        device = CMIOExtensionDevice(
            localizedName: SuperBasicCam.deviceName,
            deviceID: UUID(),
            legacyDeviceID: SuperBasicCam.deviceUID,
            source: self
        )

        let formats = SuperBasicCam.frameSizes.map { StreamFormats.make(width: $0.width, height: $0.height) }
        sourceStream = SourceStream(formats: formats)
        sinkStream = SinkStream(formats: formats) { [weak self] sampleBuffer in
            self?.sourceStream.forward(sampleBuffer)
        }

        do {
            try device.addStream(sourceStream.stream)
            try device.addStream(sinkStream.stream)
        } catch {
            fatalError("SuperBasicCam: failed to add streams: \(error)")
        }
    }

    var availableProperties: Set<CMIOExtensionProperty> {
        [.deviceTransportType, .deviceModel]
    }

    func deviceProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionDeviceProperties {
        let result = CMIOExtensionDeviceProperties(dictionary: [:])
        if properties.contains(.deviceTransportType) {
            result.transportType = kIOAudioDeviceTransportTypeVirtual
        }
        if properties.contains(.deviceModel) {
            result.model = SuperBasicCam.deviceName
        }
        return result
    }

    func setDeviceProperties(_ deviceProperties: CMIOExtensionDeviceProperties) throws {}
}

enum StreamFormats {
    static func make(width: Int32, height: Int32) -> CMIOExtensionStreamFormat {
        var description: CMFormatDescription?
        let status = CMVideoFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            codecType: SuperBasicCam.pixelFormat,
            width: width,
            height: height,
            extensions: nil,
            formatDescriptionOut: &description
        )
        guard status == noErr, let description else {
            fatalError("SuperBasicCam: cannot create format description (\(status))")
        }
        return CMIOExtensionStreamFormat(
            formatDescription: description,
            maxFrameDuration: CMTime(value: 1, timescale: 1),
            minFrameDuration: CMTime(value: 1, timescale: 60),
            validFrameDurations: nil
        )
    }

    static func dimensions(of format: CMIOExtensionStreamFormat) -> CMVideoDimensions {
        CMVideoFormatDescriptionGetDimensions(format.formatDescription)
    }
}

func hostTimeNanoseconds() -> UInt64 {
    clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
}
