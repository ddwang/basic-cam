import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var pipeline: CameraPipeline
    @EnvironmentObject private var installer: ExtensionInstaller

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            PreviewView(layer: pipeline.previewLayer)
                .aspectRatio(pipeline.outputAspectRatio, contentMode: .fit)
                .frame(maxWidth: .infinity)
                .frame(height: 300)
                .background(Color.black)
                .clipShape(RoundedRectangle(cornerRadius: 8))

            Picker("Camera", selection: $pipeline.selectedCameraID) {
                ForEach(pipeline.cameras, id: \.uniqueID) { camera in
                    Text(camera.localizedName).tag(camera.uniqueID)
                }
            }

            Picker("Rotation", selection: $pipeline.rotation) {
                ForEach(Rotation.allCases) { rotation in
                    Text(rotation.label).tag(rotation)
                }
            }
            .pickerStyle(.segmented)

            Picker("Resolution", selection: $pipeline.resolution) {
                ForEach(Resolution.allCases) { resolution in
                    Text(resolution.label).tag(resolution)
                }
            }
            .pickerStyle(.segmented)

            Toggle("Crop to a square", isOn: $pipeline.squareCrop)

            Divider()

            HStack(spacing: 8) {
                Circle()
                    .fill(pipeline.sinkConnected ? Color.green : Color.orange)
                    .frame(width: 10, height: 10)
                Text(statusText)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Spacer()
                if !pipeline.sinkConnected {
                    Button("Install camera extension") { installer.install() }
                        .disabled(installer.isBusy)
                }
            }
        }
        .padding(16)
        .frame(width: 520)
        .onAppear { pipeline.start() }
    }

    private var statusText: String {
        if !pipeline.cameraAuthorized {
            return "Camera access denied. Allow SuperBasicCam in System Settings > Privacy & Security > Camera."
        }
        if pipeline.sinkConnected {
            return "Streaming to the \"\(SuperBasicCam.deviceName)\" virtual camera."
        }
        return installer.statusText
    }
}
