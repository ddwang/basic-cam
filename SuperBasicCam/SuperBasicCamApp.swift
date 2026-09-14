import SwiftUI

@main
struct SuperBasicCamApp: App {
    @StateObject private var pipeline = CameraPipeline()
    @StateObject private var installer = ExtensionInstaller()

    var body: some Scene {
        WindowGroup("SuperBasicCam") {
            ContentView()
                .environmentObject(pipeline)
                .environmentObject(installer)
        }
        .windowResizability(.contentSize)
        .commands {
            CommandMenu("Extension") {
                Button("Install camera extension") { installer.install() }
                Button("Uninstall camera extension") { installer.uninstall() }
            }
        }
    }
}
