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
