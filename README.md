# BasicCam

BasicCam rotates a webcam by 0, 90, 180, or 270 degrees, optionally crops it to
a square, and publishes the result as a virtual camera named **BasicCam**. Any app that lists cameras (Zoom, Meet,
FaceTime, QuickTime) can select it.

## How it works

BasicCam has two parts:

- **BasicCam.app** captures the physical camera with `AVCaptureSession`, crops
  and rotates each BGRA frame with `vImageRotate90_ARGB8888`, and writes the frame into the
  extension's sink stream through the Core Media IO C API.
- **BasicCam Extension** is a Core Media IO camera extension. It exposes one
  device with a source stream (what other apps read) and a sink stream (what
  the app writes). The extension forwards each frame without copying it. When
  the app isn't running, the extension sends black frames so clients keep a
  live picture.

Per-frame cost on Apple silicon is about 1 ms for 720p and 2 to 3 ms for 1080p.
Frames cross the process boundary as IOSurfaces, so the extension adds no copy.
The sink queue holds 3 frames, and the app drops a frame instead of buffering it
when the queue is full.

## Requirements

- macOS 14 or later.
- Xcode 15 or later.
- [XcodeGen](https://github.com/yonaskolb/XcodeGen): `brew install xcodegen`.
- An Apple Developer team. Camera extensions need the
  `com.apple.developer.system-extension.install` entitlement, which requires a
  provisioning profile. Ad hoc signing does not work.

## Set up signing

1. Open `project.yml` and set `DEVELOPMENT_TEAM` to your team ID. Xcode shows
   the ID under **Settings > Accounts** when you select a team.
2. Sign in to that account in Xcode so automatic signing can create the
   provisioning profiles.
3. Make sure the App ID for `com.ddwang.BasicCam` has the **System Extension**
   capability. Xcode adds it on the first build when the account has permission
   to edit App IDs. Otherwise, add it at developer.apple.com.

To use different bundle identifiers, change them in `project.yml`,
`Shared/Constants.swift`, and both `.entitlements` files.

## Build and install

System extensions load only from `/Applications` while System Integrity
Protection is enabled. The install script handles that:

```sh
./scripts/install.sh
```

The script regenerates the Xcode project, builds the Release configuration,
copies `BasicCam.app` to `/Applications`, and opens it.

To build in Xcode instead, run `xcodegen generate`, open `BasicCam.xcodeproj`,
build the **BasicCam** scheme, and copy the product to `/Applications` before
launching it.

## Use

1. Launch BasicCam and allow camera access.
2. Click **Install camera extension**. macOS asks you to approve the extension
   under **System Settings > General > Login Items & Extensions > Camera
   Extensions**.
3. Pick the camera, rotation, and resolution. **Crop to a square** is on by
   default and trims the long edge around the center, so 1280x720 becomes
   720x720. The status dot turns green when frames are flowing to the virtual
   camera.
4. In your video app, select the **BasicCam** camera.

Rotation is clockwise. With the square crop off, a 90 or 270 degree rotation
produces a portrait frame, for example 720x1280 instead of 1280x720. Set the
rotation and crop before joining a call. Some apps don't pick up a frame-size change until you reselect the camera.

Settings persist across launches. BasicCam must stay running for the virtual
camera to show live video.

To remove the extension, choose **Extension > Uninstall camera extension** from
the menu bar.

## Troubleshooting

- **Install failed: … code signature …** The app isn't signed with a
  provisioning profile that includes the System Extension capability. Check the
  signing steps above.
- **The extension never appears.** Confirm the app runs from `/Applications`.
  Run `systemextensionsctl list` to see the extension's state.
- **Black picture in the client app.** BasicCam.app isn't running, or its status
  dot is orange. Launch the app and check the status line.
