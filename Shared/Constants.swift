import CoreVideo
import Foundation

/// Values shared by the host app and the camera extension.
enum BasicCam {
    static let appBundleID = "com.ddwang.BasicCam"
    static let extensionBundleID = "com.ddwang.BasicCam.Extension"

    /// Stable UID of the virtual camera. The host app locates the
    /// extension's device by this value; clients see it as the device's uniqueID.
    static let deviceUID = "com.ddwang.BasicCam.Device"
    static let deviceName = "BasicCam"

    static let pixelFormat = kCVPixelFormatType_32BGRA
    static let frameRate: Int32 = 30

    /// Frame sizes the extension advertises. The host must emit one of these,
    /// so the list holds each capture size in both orientations plus its square crop.
    static let frameSizes: [(width: Int32, height: Int32)] = [
        (1280, 720), (720, 1280), (720, 720),
        (1920, 1080), (1080, 1920), (1080, 1080),
    ]
}
