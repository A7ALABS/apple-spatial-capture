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

This plugin is iOS-only. Use a physical iPhone or iPad with supported hardware.

From this directory:

```sh
flutter create --platforms=ios --project-name apple_spatial_capture_example .
flutter pub get
flutter run
```

The `flutter create` command adds the generated iOS runner files around the
checked-in example Dart app. Set the generated iOS deployment target to `14.0`
or higher.

Add these permission strings to `ios/Runner/Info.plist` after generating the iOS runner:

```xml
<key>NSCameraUsageDescription</key>
<string>Scan objects, rooms, and LiDAR meshes.</string>
<key>NSPhotoLibraryUsageDescription</key>
<string>Select photos to generate a 3D model.</string>
```

Object Capture and photo reconstruction require iOS 17+ with supported
hardware. RoomPlan requires iOS 16+ with supported hardware. LiDAR mesh scanning
requires iOS 14+ with LiDAR support.
