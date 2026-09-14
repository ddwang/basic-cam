import Accelerate
import CoreMedia
import CoreVideo
import os

enum Rotation: Int, CaseIterable, Identifiable {
    case degrees0 = 0
    case degrees90 = 90
    case degrees180 = 180
    case degrees270 = 270

    var id: Int { rawValue }

    var label: String { "\(rawValue)°" }

    /// True when the output frame has swapped width and height.
    var swapsDimensions: Bool { self == .degrees90 || self == .degrees270 }

    /// vImage rotation constant. vImage measures clockwise for these named values.
    var vImageConstant: UInt8 {
        switch self {
        case .degrees0: UInt8(kRotate0DegreesClockwise)
        case .degrees90: UInt8(kRotate90DegreesClockwise)
        case .degrees180: UInt8(kRotate180DegreesClockwise)
        case .degrees270: UInt8(kRotate270DegreesClockwise)
        }
    }
}

/// Crops and rotates BGRA frames with vImage. A 720p rotation takes about 1 ms on Apple silicon.
final class FrameRotator {
    struct Settings {
        var rotation: Rotation = .degrees0
        var squareCrop = false
    }

    private let state = OSAllocatedUnfairLock<Settings>(initialState: Settings())

    var rotation: Rotation {
        get { state.withLock { $0.rotation } }
        set { state.withLock { $0.rotation = newValue } }
    }

    var squareCrop: Bool {
        get { state.withLock { $0.squareCrop } }
        set { state.withLock { $0.squareCrop = newValue } }
    }

    private var pool: CVPixelBufferPool?
    private var poolSize = (width: 0, height: 0)
    private var formatDescription: CMVideoFormatDescription?

    /// Returns a cropped and rotated copy of the frame, or the frame itself when no work is needed.
    func rotate(_ sampleBuffer: CMSampleBuffer) -> CMSampleBuffer? {
        let settings = state.withLock { $0 }
        guard let source = CMSampleBufferGetImageBuffer(sampleBuffer) else { return nil }

        // Frames must be IOSurface-backed to cross into the extension process.
        if settings.rotation == .degrees0, !settings.squareCrop, CVPixelBufferGetIOSurface(source) != nil {
            return sampleBuffer
        }

        let width = CVPixelBufferGetWidth(source)
        let height = CVPixelBufferGetHeight(source)

        // The crop is a view into the source buffer, so it costs nothing.
        let side = min(width, height)
        let cropWidth = settings.squareCrop ? side : width
        let cropHeight = settings.squareCrop ? side : height
        let cropX = (width - cropWidth) / 2
        let cropY = (height - cropHeight) / 2

        let outWidth = settings.rotation.swapsDimensions ? cropHeight : cropWidth
        let outHeight = settings.rotation.swapsDimensions ? cropWidth : cropHeight
        guard let destination = makeBuffer(width: outWidth, height: outHeight) else { return nil }

        CVPixelBufferLockBaseAddress(source, .readOnly)
        CVPixelBufferLockBaseAddress(destination, [])
        defer {
            CVPixelBufferUnlockBaseAddress(destination, [])
            CVPixelBufferUnlockBaseAddress(source, .readOnly)
        }
        guard let sourceBase = CVPixelBufferGetBaseAddress(source) else { return nil }

        let sourceRowBytes = CVPixelBufferGetBytesPerRow(source)
        var src = vImage_Buffer(
            data: sourceBase + cropY * sourceRowBytes + cropX * 4,
            height: vImagePixelCount(cropHeight),
            width: vImagePixelCount(cropWidth),
            rowBytes: sourceRowBytes
        )
        var dst = vImage_Buffer(
            data: CVPixelBufferGetBaseAddress(destination),
            height: vImagePixelCount(outHeight),
            width: vImagePixelCount(outWidth),
            rowBytes: CVPixelBufferGetBytesPerRow(destination)
        )
        let background: [UInt8] = [0, 0, 0, 255]
        let error = vImageRotate90_ARGB8888(&src, &dst, settings.rotation.vImageConstant, background, vImage_Flags(kvImageNoFlags))
        guard error == kvImageNoError else { return nil }

        return wrap(destination, timingFrom: sampleBuffer)
    }

    private func wrap(_ pixelBuffer: CVPixelBuffer, timingFrom original: CMSampleBuffer) -> CMSampleBuffer? {
        var timing = CMSampleTimingInfo()
        CMSampleBufferGetSampleTimingInfo(original, at: 0, timingInfoOut: &timing)

        if formatDescription == nil
            || CMVideoFormatDescriptionGetDimensions(formatDescription!).width != Int32(CVPixelBufferGetWidth(pixelBuffer))
            || CMVideoFormatDescriptionGetDimensions(formatDescription!).height != Int32(CVPixelBufferGetHeight(pixelBuffer)) {
            var description: CMVideoFormatDescription?
            CMVideoFormatDescriptionCreateForImageBuffer(
                allocator: kCFAllocatorDefault,
                imageBuffer: pixelBuffer,
                formatDescriptionOut: &description
            )
            formatDescription = description
        }
        guard let formatDescription else { return nil }

        var result: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescription: formatDescription,
            sampleTiming: &timing,
            sampleBufferOut: &result
        )
        return result
    }

    private func makeBuffer(width: Int, height: Int) -> CVPixelBuffer? {
        if pool == nil || poolSize != (width, height) {
            let attributes: [CFString: Any] = [
                kCVPixelBufferPixelFormatTypeKey: SuperBasicCam.pixelFormat,
                kCVPixelBufferWidthKey: width,
                kCVPixelBufferHeightKey: height,
                kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            ]
            let poolAttributes: [CFString: Any] = [kCVPixelBufferPoolMinimumBufferCountKey: 6]
            var newPool: CVPixelBufferPool?
            CVPixelBufferPoolCreate(kCFAllocatorDefault, poolAttributes as CFDictionary, attributes as CFDictionary, &newPool)
            pool = newPool
            poolSize = (width, height)
        }
        guard let pool else { return nil }
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &buffer)
        return buffer
    }
}
