# apple_spatial_capture example

Example Flutter app for the `apple_spatial_capture` plugin.

The app demonstrates:

- Loading support status with `supportStatus()`.
- Starting guided Object Capture.
- Starting LiDAR mesh capture.
- Starting RoomPlan capture.
- Generating a model from selected photos with `startPhotogrammetryFromImages()`.
- Listening to `progressStream`.
- Previewing local models with `previewCapturedModel()`.
- Previewing remote models with `previewRemoteModel()`.
- Configuring `ApplePhotogrammetryOptions`.

## Run the example

This plugin supports iOS, iPadOS, and macOS. Use a physical iPhone or iPad for device capture, or a supported Mac for photo reconstruction.

From this directory:

```sh
flutter create --platforms=ios,macos --project-name apple_spatial_capture_example .
flutter pub get
flutter run
```

The `flutter create` command adds the generated iOS runner files around the
checked-in example Dart app. Set the generated iOS deployment target to `14.0`
or higher, and the generated macOS deployment target to `12.0` or higher.

Add these permission strings to `ios/Runner/Info.plist` after generating the iOS runner:

```xml
<key>NSCameraUsageDescription</key>
<string>Scan objects, rooms, and LiDAR meshes.</string>
<key>NSPhotoLibraryUsageDescription</key>
<string>Select photos to generate a 3D model.</string>
```

Guided Object Capture and iOS/iPadOS photo reconstruction require iOS 17+ or
iPadOS 17+ with supported hardware. macOS photo reconstruction requires macOS
12+ with Object Capture support. RoomPlan requires iOS 16+ or iPadOS 16+ with
supported hardware. LiDAR mesh scanning requires iOS 14+ or iPadOS 14+ with
LiDAR support.
