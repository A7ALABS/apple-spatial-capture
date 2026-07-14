## 0.3.0

- Added a cohesive `AppleSpatialCapture.gaussianSplat` facade (`GaussianSplatApi`) that groups the whole splat workflow — `capture`, `listDatasets`, `shareDataset`, `train`, `cancelTraining`, `trainingProgress`, `preview`, `openViewport`, `openPlyViewport` — instead of spreading ~17 methods across the platform interface. The embedded viewport is now a stateful `AppleGaussianSplatViewport` handle with instance methods (`renderFrame`, `crop`, `cleanup`, `snapshot`, `restore`, `saveEdits`, `close`) that tracks its own gaussian count, distinguishes editable dataset sessions from view-only `.ply` sessions (edit calls on a `.ply` throw `NOT_EDITABLE` rather than reaching native), stores its dataset path for `saveEdits`, and closes idempotently. The flat `AppleSpatialCapturePlatform` methods are unchanged for backward compatibility. Native dispatch for all splat methods is consolidated into a single router (`handleGaussianSplatMethod`) on each platform plugin.
- Fixed iPhone crashes on long training runs (e.g. 7000 iterations). The memory planner only budgeted training *images*, but msplat's densification keeps splitting/cloning gaussians until iteration `iterations/2` with no cap, and each live gaussian also carries Adam optimizer moments, gradients and densification scratch (allocated at up to 2x the active count) — so the growing model, not the images, exceeded the jetsam limit late in the run. Two mitigations: on iOS densification is slowed (higher gradient threshold, earlier screen-size-split cutoff) so long runs refine instead of ballooning, and a hard gaussian ceiling derived from the memory left after images stops the run before it can OOM, exporting the partially trained (still valid) splat. The result reports `hitGaussianLimit` and emits an explanatory progress event; train on a Mac for a denser result.
- Added `cancelGaussianSplatTraining()`: stops the active on-device training run at the next iteration; the run still exports everything trained so far and resolves normally with `AppleGaussianSplatTrainingResult.cancelled` set, so apps no longer have to block navigation for the whole run.
- Training now automatically closes any open embedded viewport sessions before it starts — a live viewport plus a trainer is two full engine instances, which jetsams iPhones. Apps no longer need to unmount their viewport manually (its render calls report `INVALID_SESSION` after training begins).
- Memory-planner failures now surface a typed `OUT_OF_MEMORY` error code (via `AppleSpatialCaptureError.code`) instead of requiring apps to string-match error messages.
- Fixed the embedded viewport's undo/restore path re-inflating memory: restoring a snapshot reloads the engine's optimizer buffers (~3× per-gaussian memory), which are now released again immediately — previously the first undo on a large splat could jetsam an iPhone.
- `openSplatPlyViewport` now validates the PLY magic header instead of relying on the file extension, so downloaded splats with temporary file names load without a rename, and corrupt files fail with a readable error instead of crashing in the engine.

- Added an interactive trained-splat viewer (`previewGaussianSplat`): drag to orbit, pinch/scroll to zoom, on both iOS and macOS. Reuses the vendored msplat engine as the renderer — training now saves a reloadable checkpoint in the dataset folder by default (`saveCheckpoint` option, ~700 bytes per gaussian), which the viewer reloads through a lightweight 3-frame manifest so no full image set is loaded. The orbit centers on the captured subject by least-squares triangulation of the camera view rays. Verified end-to-end on macOS (checkpoint save → reload → full-resolution pose render).
- Added `listGaussianSplatDatasets()`: returns captured dataset folders (`Documents/GaussianSplatDatasets/`, newest first) so apps can offer a dataset picker instead of a typed sandbox path. The example app's training section now shows a "Captured datasets" dropdown (auto-selecting the newest) alongside the manual path field.
- Added an iOS memory planner for on-device training: the run is sized against the process's real jetsam headroom (`os_proc_available_memory`) by raising the image downscale factor first (long side kept ≥ ~480 px) and then evenly subsampling frames (floor of 30) via a temporary trimmed `transforms.json` that references the original images by absolute path (no copies). The engine keeps every training image resident as float32 plus pyramid/GPU caches, so full-resolution multi-hundred-frame captures previously exceeded the ~3 GB per-app limit and were jetsam-killed. The chosen plan is emitted as an `info` progress event and reported in the result (`totalImageCount`, `downscaleFactor`); a `maxImages` training option adds an explicit cap on any platform.
- Added on-device 3D Gaussian Splatting training (`trainGaussianSplat`, `isGaussianSplatTrainingSupported`) powered by a vendored build of the msplat Metal engine (https://github.com/rayanht/msplat, Apache 2.0; license included). Training reads a captured dataset's nerfstudio `transforms.json`, initializes from the captured seed point cloud, streams progress over the existing event channel (`gaussian_splat_training` operation), and writes a standard `splat.ply` into the dataset folder. Supported on Apple-silicon Macs (macOS 14+); experimental on iOS 16+ with A15/M-class GPUs (cross-compiled iOS slice, gated at runtime — memory limits on phones are unproven). Verified end-to-end on macOS: dataset load, point-cloud seeding, GPU training steps, and PLY export. Added `AppleGaussianSplatTrainingOptions`/`AppleGaussianSplatTrainingResult` and a `gaussianSplatTraining` support flag; the example app gained a training section with iteration presets.

- Added Gaussian splatting dataset capture (`startGaussianSplatCapture`, iOS 14+). A Scaniverse/RealityScan-style full-screen AR flow automatically captures keyframe photos as the device moves (translation/rotation thresholds, motion-blur and tracking-quality gating), with live guidance, a photo counter, capture-pose markers, and a last-shot thumbnail.
- Each capture exports a training-ready dataset folder: `images/` (sensor-oriented JPEGs), a nerfstudio-format `transforms.json` with per-frame ARKit camera poses and intrinsics (no COLMAP/SfM step needed), a colored `sparse_pc.ply` seed point cloud built from ARKit feature points, and optional 16-bit millimeter depth PNGs on LiDAR devices (`includeDepthMaps`). The output trains directly in nerfstudio/gsplat, Brush, and other `transforms.json`-compatible Gaussian-splatting trainers.
- Datasets are now written to `Documents/GaussianSplatDatasets/<timestamped-folder>/` (instead of the purgeable temporary directory) so they persist between launches and are visible in the Files app / Finder when the host app enables `UIFileSharingEnabled` + `LSSupportsOpeningDocumentsInPlace` (the example app now does).
- Added `shareGaussianSplatDataset(datasetPath:)`: zips the dataset folder (no archiving dependency — coordinated `.forUploading` read) and presents the system share sheet for AirDrop / Files / iCloud Drive transfer to a computer. The example app gained a "Share dataset" button on the capture result card.
- Added assisted capture quality controls: auto-exposure (ISO + shutter) and white balance are locked after convergence when recording starts (`lockCameraSettings`, iOS 16+, with optional `lockFocus`) so all frames share consistent brightness and color; per-frame motion blur is predicted from exposure duration × camera velocity and smeared frames are skipped with a "hold steadier" prompt; a measured Laplacian sharpness check rejects outlier-blurry frames against the scan's own baseline before they are written; and too-dark / clipped-highlight scenes raise on-screen warnings. Rejected-frame counts are shown live and reported via `AppleGaussianSplatDataset.rejectedImageCount`.
- Added a selectable dataset layout (`AppleGaussianSplatDatasetFormat`): nerfstudio `transforms.json` (default), a COLMAP text model under `sparse/0/` for LichtFeld Studio and the reference 3DGS implementation (poses converted to COLMAP's world-to-camera OpenCV convention), or both side by side.
- Added `AppleGaussianSplatCaptureOptions` (max images, capture thresholds, depth maps, JPEG quality, dataset format), `AppleGaussianSplatDataset`, `isGaussianSplatCaptureSupported`, and a `gaussianSplat` flag on `AppleSpatialCaptureSupport`.

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
