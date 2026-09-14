import Foundation
import SystemExtensions

/// Installs and removes the camera extension through OSSystemExtensionManager.
final class ExtensionInstaller: NSObject, ObservableObject, OSSystemExtensionRequestDelegate {
    enum State: Equatable {
        case idle
        case requesting
        case needsApproval
        case installed
        case rebootRequired
        case failed(String)
    }

    @Published private(set) var state: State = .idle

    var isBusy: Bool { state == .requesting }

    var statusText: String {
        switch state {
        case .idle:
            return "Virtual camera not found. Install the camera extension to start."
        case .requesting:
            return "Installing the camera extension…"
        case .needsApproval:
            return "Approve BasicCam in System Settings > General > Login Items & Extensions > Camera Extensions."
        case .installed:
            return "Extension installed. Waiting for the virtual camera to appear…"
        case .rebootRequired:
            return "Extension installed. Restart your Mac to finish."
        case .failed(let message):
            return "Install failed: \(message)"
        }
    }

    func install() {
        submit(OSSystemExtensionRequest.activationRequest(forExtensionWithIdentifier: BasicCam.extensionBundleID, queue: .main))
    }

    func uninstall() {
        submit(OSSystemExtensionRequest.deactivationRequest(forExtensionWithIdentifier: BasicCam.extensionBundleID, queue: .main))
    }

    private func submit(_ request: OSSystemExtensionRequest) {
        request.delegate = self
        state = .requesting
        OSSystemExtensionManager.shared.submitRequest(request)
    }

    // MARK: OSSystemExtensionRequestDelegate

    func request(
        _ request: OSSystemExtensionRequest,
        actionForReplacingExtension existing: OSSystemExtensionProperties,
        withExtension ext: OSSystemExtensionProperties
    ) -> OSSystemExtensionRequest.ReplacementAction {
        .replace
    }

    func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        state = .needsApproval
    }

    func request(_ request: OSSystemExtensionRequest, didFinishWithResult result: OSSystemExtensionRequest.Result) {
        state = result == .completed ? .installed : .rebootRequired
    }

    func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
        state = .failed(error.localizedDescription)
    }
}
