## 0.2.6

- Fixed LiDAR mesh scans exporting without color. Per-vertex colors are now accumulated across the whole scan (keyed by world position so they survive ARKit's continuous re-meshing) and baked into the model as embedded vertex colors (USD `displayColor`), instead of projecting a single final camera frame onto an external texture that ModelIO frequently failed to package into the USDZ. Export failures are now surfaced instead of silently producing an uncolored mesh.

## 0.2.5

- Reverted the iOS detail mapping introduced in 0.2.4. Apple's `PhotogrammetrySession.Request.Detail` only exposes `.reduced` on iOS (`.preview`, `.medium`, `.full`, and `.raw` are macOS / Mac Catalyst only), so 0.2.4 failed to compile on iOS. iOS export again uses reduced detail and reports a fallback progress event when another level is requested. macOS continues to honor all detail levels.

## 0.2.4 (retracted — broken on iOS)

- Attempted to map all `ApplePhotogrammetryDetail` levels on iOS. This referenced `PhotogrammetrySession.Request.Detail` cases that do not exist on iOS and does not build. Use 0.2.5 or, on iOS, 0.2.3.

## 0.2.3

- Added Swift Package Manager manifests for iOS and macOS.

## 0.2.2

- Added dartdoc coverage for the exported public Dart API.

## 0.2.1

- Preserved original photogrammetry input images without sampling, resizing, or JPEG recompression.
- Mapped the example texture quality picker to RealityKit detail levels on macOS.
- Fixed photogrammetry completion handling so model generation returns when RealityKit reports request or processing completion.
- Fixed macOS OBJ generation to use a directory output URL as required by RealityKit.

## 0.2.0

- Added macOS plugin support for photo reconstruction from existing images.
- Added macOS support for local and remote model previews.
- Added a generated macOS example runner with macOS 12.0 deployment target.
- Added macOS screenshots to README and pub.dev metadata.
- Added macOS photogrammetry export timeout and heartbeat progress events.
- Added elapsed-time progress reporting for iOS and macOS photogrammetry.
- Added a realtime elapsed-time badge to the example progress banner.
- Documented iPadOS support alongside iOS support.

## 0.1.4

- Added package-local GitHub Actions workflows for releasing and publishing.
- Updated package publishing metadata.

## 0.1.3

- Added changelog entries required for pub.dev validation.

## 0.1.2

- Added package screenshots for pub.dev.
- Updated package metadata and documentation.

## 0.1.1

- Refined example app documentation and package publishing assets.

## 0.1.0

- Initial release.
- Added iOS RoomPlan, Object Capture, and LiDAR scan methods.
- Added native model preview support for USDZ/OBJ/GLB/GLTF.
