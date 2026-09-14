import CoreMedia
import CoreMediaIO
import Foundation
import os

/// Pushes frames into the extension's sink stream through the Core Media IO C API.
/// Call every method from one serial queue.
final class SinkWriter {
    private let logger = Logger(subsystem: SuperBasicCam.appBundleID, category: "sink")
    private var deviceID: CMIODeviceID = 0
    private var streamID: CMIOStreamID = 0
    private var queue: CMSimpleQueue?

    var isConnected: Bool { queue != nil }

    /// Looks up the virtual camera and starts its sink stream. Returns false when the
    /// extension is not installed yet.
    @discardableResult
    func connect() -> Bool {
        guard !isConnected else { return true }
        guard let device = Self.findDevice(uid: SuperBasicCam.deviceUID),
              let stream = Self.findSinkStream(on: device) else {
            return false
        }

        var unmanagedQueue: Unmanaged<CMSimpleQueue>?
        let copyStatus = CMIOStreamCopyBufferQueue(stream, { _, _, _ in }, nil, &unmanagedQueue)
        guard copyStatus == noErr, let unmanagedQueue else {
            logger.error("CMIOStreamCopyBufferQueue failed: \(copyStatus)")
            return false
        }
        let startStatus = CMIODeviceStartStream(device, stream)
        guard startStatus == noErr else {
            logger.error("CMIODeviceStartStream failed: \(startStatus)")
            unmanagedQueue.release()
            return false
        }

        queue = unmanagedQueue.takeRetainedValue()
        deviceID = device
        streamID = stream
        logger.info("connected to sink stream \(stream)")
        return true
    }

    func disconnect() {
        guard isConnected else { return }
        CMIODeviceStopStream(deviceID, streamID)
        queue = nil
        deviceID = 0
        streamID = 0
    }

    /// Enqueues one frame. Drops the frame when the extension has not drained the queue.
    func write(_ sampleBuffer: CMSampleBuffer) {
        guard let queue else { return }
        let retained = Unmanaged.passRetained(sampleBuffer)
        let status = CMSimpleQueueEnqueue(queue, element: retained.toOpaque())
        if status != noErr {
            retained.release()
        }
    }

    // MARK: Core Media IO lookups

    private static func address(_ selector: Int) -> CMIOObjectPropertyAddress {
        CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(selector),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
        )
    }

    private static func findDevice(uid: String) -> CMIODeviceID? {
        let devices: [CMIODeviceID] = arrayProperty(of: CMIOObjectID(kCMIOObjectSystemObject), selector: kCMIOHardwarePropertyDevices)
        return devices.first { stringProperty(of: $0, selector: kCMIODevicePropertyDeviceUID) == uid }
    }

    private static func findSinkStream(on device: CMIODeviceID) -> CMIOStreamID? {
        let streams: [CMIOStreamID] = arrayProperty(of: device, selector: kCMIODevicePropertyStreams)
        // Direction 1 means the host sends data to the device.
        return streams.first { scalarProperty(of: $0, selector: kCMIOStreamPropertyDirection) == UInt32(1) }
    }

    private static func arrayProperty<T>(of object: CMIOObjectID, selector: Int) -> [T] {
        var address = address(selector)
        var size: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(object, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        let count = Int(size) / MemoryLayout<T>.stride
        let buffer = UnsafeMutablePointer<T>.allocate(capacity: count)
        defer { buffer.deallocate() }
        var used: UInt32 = 0
        guard CMIOObjectGetPropertyData(object, &address, 0, nil, size, &used, buffer) == noErr else { return [] }
        return Array(UnsafeBufferPointer(start: buffer, count: Int(used) / MemoryLayout<T>.stride))
    }

    private static func scalarProperty<T>(of object: CMIOObjectID, selector: Int) -> T? {
        var address = address(selector)
        var used: UInt32 = 0
        let buffer = UnsafeMutablePointer<T>.allocate(capacity: 1)
        defer { buffer.deallocate() }
        let size = UInt32(MemoryLayout<T>.size)
        guard CMIOObjectGetPropertyData(object, &address, 0, nil, size, &used, buffer) == noErr else { return nil }
        return buffer.pointee
    }

    private static func stringProperty(of object: CMIOObjectID, selector: Int) -> String? {
        var address = address(selector)
        var used: UInt32 = 0
        var value: Unmanaged<CFString>?
        let size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard CMIOObjectGetPropertyData(object, &address, 0, nil, size, &used, &value) == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }
}
