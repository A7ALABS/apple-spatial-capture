/// Flutter plugin API for Apple spatial capture features.
///
/// Use [AppleSpatialCapture.platform] to check feature support, launch native
/// capture flows, reconstruct models from photos, and preview local or remote
/// 3D model files on supported Apple platforms.
library;

import 'package:flutter/services.dart';

import 'src/apple_spatial_capture_channel.dart';
import 'src/apple_spatial_capture_models.dart';
import 'src/gaussian_splat.dart';

export 'src/apple_spatial_capture_models.dart';
export 'src/gaussian_splat.dart'
    show
        GaussianSplatApi,
        AppleGaussianSplatViewport,
        kGaussianSplatTrainingOperation;

/// Flutter-facing library for Apple 3D capture and reconstruction features:
/// RoomPlan, photogrammetry (Object Capture), LiDAR mesh scanning, and macOS
/// photo-based reconstruction.
class AppleSpatialCapture {
  AppleSpatialCapture._();

  static AppleSpatialCapturePlatform _platform = AppleSpatialCaptureChannel();

  /// Current platform implementation used by the plugin.
  static AppleSpatialCapturePlatform get platform => _platform;

  /// Cohesive entry point for the Gaussian-splatting workflow (capture,
  /// train, preview, and the embedded editable viewport).
  ///
  /// This facade groups the splat-related operations that are otherwise
  /// spread across [AppleSpatialCapturePlatform]; prefer it in app code. The
  /// flat platform methods remain available for advanced use.
  static GaussianSplatApi get gaussianSplat => GaussianSplatApi(_platform);

  /// Allows replacing platform impl in tests.
  static void setPlatform(AppleSpatialCapturePlatform value) {
    _platform = value;
  }
}

/// Platform interface implemented by the method-channel backed plugin.
abstract class AppleSpatialCapturePlatform {
  /// Emits native photogrammetry progress events for long-running operations.
  Stream<AppleSpatialCaptureProgress> get progressStream;

  /// Returns whether Object Capture or photo photogrammetry is available.
  Future<bool> isPhotogrammetrySupported();

  /// Returns whether LiDAR mesh capture is available on this device.
  Future<bool> isLiDARSupported();

  /// Returns whether RoomPlan room capture is available on this device.
  Future<bool> isRoomPlanSupported();

  /// Returns whether Gaussian-splat dataset capture is available.
  Future<bool> isGaussianSplatCaptureSupported();

  /// Returns support flags for all plugin capture features.
  Future<AppleSpatialCaptureSupport> supportStatus();

  /// Starts native guided Object Capture and returns the generated model path.
  Future<String?> startPhotogrammetryCapture();

  /// Starts photo-based photogrammetry from existing image file paths.
  Future<String?> startPhotogrammetryFromImages(
    List<String> imagePaths, {
    String? operationId,
    ApplePhotogrammetryOptions options = const ApplePhotogrammetryOptions(),
  });

  /// Starts LiDAR mesh capture and returns the generated model path.
  Future<String?> startLiDARCapture();

  /// Starts RoomPlan capture and returns the generated model path.
  Future<String?> startRoomPlanCapture();

  /// Starts a Gaussian-splat dataset capture session.
  ///
  /// Opens a full-screen AR capture flow that automatically takes photos as
  /// the user moves around the subject, then exports a training-ready dataset
  /// (images, nerfstudio `transforms.json` camera poses, and a sparse seed
  /// point cloud). Returns null if the user cancels.
  Future<AppleGaussianSplatDataset?> startGaussianSplatCapture({
    AppleGaussianSplatCaptureOptions options =
        const AppleGaussianSplatCaptureOptions(),
  });

  /// Opens an interactive viewer for a trained Gaussian splat.
  ///
  /// Renders the training checkpoint saved in the dataset folder (see
  /// [AppleGaussianSplatTrainingOptions.saveCheckpoint]) with drag-to-orbit
  /// and pinch/scroll-to-zoom controls. Requires the same device support as
  /// [trainGaussianSplat].
  Future<void> previewGaussianSplat({required String datasetPath});

  /// Opens an embedded viewport render session for a trained dataset.
  ///
  /// Loads the training checkpoint and keeps a renderer alive so the app can
  /// request orbit frames with [renderSplatViewport] and draw them inside its
  /// own UI (with Flutter-side overlays), instead of the full-screen native
  /// viewer. Always pair with [closeSplatViewport].
  Future<AppleSplatViewportSession> openSplatViewport({
    required String datasetPath,
  });

  /// Opens an embedded viewport for a standalone `.ply` splat on disk (e.g.
  /// one downloaded from the cloud), rendered natively without a dataset or
  /// checkpoint. View-only — editing needs a checkpoint-backed session.
  /// Render/close with [renderSplatViewport]/[closeSplatViewport].
  Future<AppleSplatViewportSession> openSplatPlyViewport({
    required String plyPath,
  });

  /// Renders one frame of an open viewport session as encoded JPEG bytes.
  ///
  /// The camera orbits the dataset's estimated subject center: [azimuth] and
  /// [elevation] are radians, [distanceScale] multiplies the estimated orbit
  /// radius. Returns null when the session cannot render. Callers should keep
  /// at most one render in flight and send only the latest pose.
  Future<Uint8List?> renderSplatViewport({
    required int sessionId,
    double azimuth = 0,
    double elevation = 0.35,
    double distanceScale = 1,
  });

  /// Releases an embedded viewport session opened with [openSplatViewport].
  Future<void> closeSplatViewport({required int sessionId});

  /// Removes low-opacity, oversized and non-finite gaussians from an open
  /// viewport session (pass 0 to skip a criterion). Returns the new count.
  Future<int> cleanupSplatViewport({
    required int sessionId,
    double minOpacity = 0,
    double maxWorldScale = 0,
  });

  /// Keeps the [keepFraction] of gaussians closest to the subject center
  /// (median center, percentile radius). Returns the new gaussian count.
  Future<int> cropSplatViewport({
    required int sessionId,
    double keepFraction = 0.85,
  });

  /// Saves an undo snapshot of the session's scene to [path].
  Future<void> snapshotSplatViewport({
    required int sessionId,
    required String path,
  });

  /// Restores an undo snapshot saved with [snapshotSplatViewport]. Returns
  /// the restored gaussian count.
  Future<int> restoreSplatViewport({
    required int sessionId,
    required String path,
  });

  /// Writes the session's edited scene back into the dataset folder
  /// (splat.ply, preview checkpoint, and splat.splat when present).
  Future<void> saveSplatViewportEdits({
    required int sessionId,
    required String datasetPath,
  });

  /// Zips a captured Gaussian-splat dataset folder and opens the native
  /// share sheet (AirDrop, Files, iCloud Drive, …) so it can be transferred
  /// to a computer for training.
  ///
  /// Returns true when the user completed a share action, false when the
  /// sheet was dismissed without sharing.
  Future<bool> shareGaussianSplatDataset({required String datasetPath});

  /// Lists captured Gaussian-splat dataset folders on this device, newest
  /// first (`Documents/GaussianSplatDatasets/`). Useful for offering a
  /// dataset picker for [trainGaussianSplat] or [shareGaussianSplatDataset].
  Future<List<String>> listGaussianSplatDatasets();

  /// Returns whether on-device Gaussian-splat training is available.
  ///
  /// True on Apple-silicon Macs running macOS 14+, and experimentally on
  /// recent iPhones/iPads (iOS 16+, A15/M-class GPU or newer).
  Future<bool> isGaussianSplatTrainingSupported();

  /// Trains a 3D Gaussian Splatting scene on-device from a captured dataset.
  ///
  /// The dataset must contain a nerfstudio `transforms.json` (capture with
  /// [AppleGaussianSplatDatasetFormat.nerfstudio] or `both`). Training runs
  /// on the GPU via the bundled msplat Metal engine and writes `splat.ply`
  /// into the dataset folder. Progress is streamed on [progressStream] with
  /// operation `gaussian_splat_training`.
  Future<AppleGaussianSplatTrainingResult> trainGaussianSplat({
    required String datasetPath,
    String? operationId,
    AppleGaussianSplatTrainingOptions options =
        const AppleGaussianSplatTrainingOptions(),
  });

  /// Requests the active [trainGaussianSplat] run stop at the next
  /// iteration.
  ///
  /// The run still exports everything trained so far and resolves normally
  /// with [AppleGaussianSplatTrainingResult.cancelled] set to true — a
  /// partially trained splat is usually still viewable. Returns false when
  /// no training run is active.
  Future<bool> cancelGaussianSplatTraining();

  /// Opens a local model file in the native Apple preview UI.
  Future<void> previewCapturedModel({
    required String path,
    AppleSpatialCaptureFileType? fileType,
  });

  /// Downloads and previews a remote model file.
  Future<void> previewRemoteModel({
    required String url,
    String? fileName,
    AppleSpatialCaptureFileType? fileType,
  });
}

/// Converts platform and plugin errors to [AppleSpatialCaptureError].
AppleSpatialCaptureError toAppleSpatialCaptureError(Object error) {
  if (error is AppleSpatialCaptureError) {
    return error;
  }
  if (error is PlatformException) {
    return AppleSpatialCaptureError(
      code: error.code,
      message: error.message ?? 'Apple spatial capture failed.',
      details: error.details,
    );
  }
  return AppleSpatialCaptureError(code: 'UNKNOWN', message: error.toString());
}
