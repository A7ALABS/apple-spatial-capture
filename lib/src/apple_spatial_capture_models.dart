/// Supported 3D model file types for native preview.
enum AppleSpatialCaptureFileType {
  /// Binary glTF model.
  glb,

  /// Text glTF model.
  gltf,

  /// Universal Scene Description ZIP model.
  usdz,

  /// Wavefront OBJ model.
  obj,
}

/// RealityKit photogrammetry reconstruction detail level.
enum ApplePhotogrammetryDetail {
  /// Fastest low-detail reconstruction.
  preview,

  /// Reduced-detail reconstruction.
  reduced,

  /// Medium-detail reconstruction.
  medium,

  /// Full-detail reconstruction.
  full,

  /// Raw reconstruction detail when supported by the platform.
  raw,
}

/// Serialized values for [ApplePhotogrammetryDetail].
extension ApplePhotogrammetryDetailValue on ApplePhotogrammetryDetail {
  /// Native method-channel value for this detail level.
  String get value {
    switch (this) {
      case ApplePhotogrammetryDetail.preview:
        return 'preview';
      case ApplePhotogrammetryDetail.reduced:
        return 'reduced';
      case ApplePhotogrammetryDetail.medium:
        return 'medium';
      case ApplePhotogrammetryDetail.full:
        return 'full';
      case ApplePhotogrammetryDetail.raw:
        return 'raw';
    }
  }
}

/// Feature matching sensitivity used by RealityKit photogrammetry.
enum ApplePhotogrammetryFeatureSensitivity {
  /// Default feature sensitivity.
  normal,

  /// Higher sensitivity for low-texture or difficult subjects.
  high,
}

/// Serialized values for [ApplePhotogrammetryFeatureSensitivity].
extension ApplePhotogrammetryFeatureSensitivityValue
    on ApplePhotogrammetryFeatureSensitivity {
  /// Native method-channel value for this feature sensitivity.
  String get value {
    switch (this) {
      case ApplePhotogrammetryFeatureSensitivity.normal:
        return 'normal';
      case ApplePhotogrammetryFeatureSensitivity.high:
        return 'high';
    }
  }
}

/// Ordering hint for selected photo samples.
enum ApplePhotogrammetrySampleOrdering {
  /// Photos are ordered around the subject.
  sequential,

  /// Photos may be in arbitrary order.
  unordered,
}

/// Serialized values for [ApplePhotogrammetrySampleOrdering].
extension ApplePhotogrammetrySampleOrderingValue
    on ApplePhotogrammetrySampleOrdering {
  /// Native method-channel value for this sample ordering.
  String get value {
    switch (this) {
      case ApplePhotogrammetrySampleOrdering.sequential:
        return 'sequential';
      case ApplePhotogrammetrySampleOrdering.unordered:
        return 'unordered';
    }
  }
}

/// User-facing reconstruction quality preset.
enum ApplePhotogrammetryTextureQuality {
  /// Lower quality and faster processing.
  low,

  /// Balanced quality and processing time.
  medium,

  /// Higher quality and slower processing.
  high,
}

/// Serialized values for [ApplePhotogrammetryTextureQuality].
extension ApplePhotogrammetryTextureQualityValue
    on ApplePhotogrammetryTextureQuality {
  /// Native method-channel value for this texture quality.
  String get value {
    switch (this) {
      case ApplePhotogrammetryTextureQuality.low:
        return 'low';
      case ApplePhotogrammetryTextureQuality.medium:
        return 'medium';
      case ApplePhotogrammetryTextureQuality.high:
        return 'high';
    }
  }
}

/// Output format requested from photo photogrammetry.
enum ApplePhotogrammetryOutputFormat {
  /// Generate a USDZ file.
  usdz,

  /// Generate OBJ assets.
  obj,
}

/// Serialized values for [ApplePhotogrammetryOutputFormat].
extension ApplePhotogrammetryOutputFormatValue
    on ApplePhotogrammetryOutputFormat {
  /// Native method-channel value for this output format.
  String get value {
    switch (this) {
      case ApplePhotogrammetryOutputFormat.usdz:
        return 'usdz';
      case ApplePhotogrammetryOutputFormat.obj:
        return 'obj';
    }
  }
}

/// Options used for photo-based photogrammetry reconstruction.
class ApplePhotogrammetryOptions {
  /// Creates photogrammetry options with platform-safe defaults.
  const ApplePhotogrammetryOptions({
    this.detail = ApplePhotogrammetryDetail.reduced,
    this.featureSensitivity = ApplePhotogrammetryFeatureSensitivity.normal,
    this.sampleOrdering = ApplePhotogrammetrySampleOrdering.unordered,
    this.textureQuality = ApplePhotogrammetryTextureQuality.low,
    this.outputFormat = ApplePhotogrammetryOutputFormat.obj,
    this.useObjectMasking = false,
  });

  /// Requested RealityKit reconstruction detail.
  final ApplePhotogrammetryDetail detail;

  /// Feature matching sensitivity for the reconstruction.
  final ApplePhotogrammetryFeatureSensitivity featureSensitivity;

  /// Hint describing whether photos are ordered around the subject.
  final ApplePhotogrammetrySampleOrdering sampleOrdering;

  /// User-facing quality preset used by the example and native layer.
  final ApplePhotogrammetryTextureQuality textureQuality;

  /// Requested model output format.
  final ApplePhotogrammetryOutputFormat outputFormat;

  /// Whether object masking should be enabled when supported.
  final bool useObjectMasking;

  /// Converts this options object to a method-channel payload.
  Map<String, Object?> toMap() {
    return {
      'detail': detail.value,
      'featureSensitivity': featureSensitivity.value,
      'sampleOrdering': sampleOrdering.value,
      'textureQuality': textureQuality.value,
      'outputFormat': outputFormat.value,
      'useObjectMasking': useObjectMasking,
    };
  }
}

/// On-disk layout(s) written for a captured Gaussian-splat dataset.
enum AppleGaussianSplatDatasetFormat {
  /// nerfstudio-style `transforms.json` plus a `sparse_pc.ply` seed point
  /// cloud. Compatible with nerfstudio/gsplat, Brush, and other
  /// `transforms.json` trainers.
  nerfstudio,

  /// COLMAP text model (`sparse/0/cameras.txt`, `images.txt`,
  /// `points3D.txt`). Compatible with LichtFeld Studio and the reference
  /// 3D Gaussian Splatting implementation.
  colmap,

  /// Write both layouts side by side in the same dataset folder.
  both,
}

/// Serialized values for [AppleGaussianSplatDatasetFormat].
extension AppleGaussianSplatDatasetFormatValue
    on AppleGaussianSplatDatasetFormat {
  /// Native method-channel value for this dataset format.
  String get value {
    switch (this) {
      case AppleGaussianSplatDatasetFormat.nerfstudio:
        return 'nerfstudio';
      case AppleGaussianSplatDatasetFormat.colmap:
        return 'colmap';
      case AppleGaussianSplatDatasetFormat.both:
        return 'both';
    }
  }
}

/// Options for Gaussian-splat dataset capture.
///
/// Capture runs Scaniverse/RealityScan style: photos are taken automatically
/// while the user moves, whenever the camera has translated or rotated far
/// enough from the previous keyframe.
class AppleGaussianSplatCaptureOptions {
  /// Creates capture options with sensible defaults for object/room scans.
  const AppleGaussianSplatCaptureOptions({
    this.maxImages = 250,
    this.translationThresholdMeters = 0.08,
    this.rotationThresholdDegrees = 10,
    this.includeDepthMaps = false,
    this.jpegQuality = 0.85,
    this.format = AppleGaussianSplatDatasetFormat.nerfstudio,
    this.lockCameraSettings = true,
    this.lockFocus = false,
  });

  /// Maximum number of keyframes captured before recording auto-pauses.
  ///
  /// Clamped to `10..1000` by the native layer.
  final int maxImages;

  /// Camera translation (meters) from the last keyframe that triggers a new
  /// capture. Clamped to `0.01..1.0`.
  final double translationThresholdMeters;

  /// Camera rotation (degrees) from the last keyframe that triggers a new
  /// capture. Clamped to `1..90`.
  final double rotationThresholdDegrees;

  /// Whether LiDAR depth maps are saved alongside each image (16-bit PNG,
  /// millimeters). Ignored on devices without a LiDAR/scene-depth sensor.
  final bool includeDepthMaps;

  /// JPEG compression quality for saved keyframes. Clamped to `0.3..1.0`.
  final double jpegQuality;

  /// Dataset layout(s) to write. Use
  /// [AppleGaussianSplatDatasetFormat.colmap] (or `both`) for LichtFeld
  /// Studio compatibility.
  final AppleGaussianSplatDatasetFormat format;

  /// Locks auto-exposure (ISO + shutter speed) and white balance once
  /// recording starts, after letting them converge, so every frame in the
  /// dataset shares the same brightness and color rendition. This reduces
  /// floaters and color patchiness in the trained splat. Requires iOS 16+;
  /// ignored (auto settings) on earlier versions.
  final bool lockCameraSettings;

  /// Also locks focus when [lockCameraSettings] applies. Off by default so
  /// close-up passes stay sharp; enable it for scans at a constant distance
  /// to keep intrinsics perfectly stable.
  final bool lockFocus;

  /// Converts this options object to a method-channel payload.
  Map<String, Object?> toMap() {
    return {
      'maxImages': maxImages,
      'translationThresholdMeters': translationThresholdMeters,
      'rotationThresholdDegrees': rotationThresholdDegrees,
      'includeDepthMaps': includeDepthMaps,
      'jpegQuality': jpegQuality,
      'format': format.value,
      'lockCameraSettings': lockCameraSettings,
      'lockFocus': lockFocus,
    };
  }
}

/// A captured Gaussian-splat training dataset on disk.
///
/// The dataset folder always contains `images/` (and optionally `depth/`).
/// Depending on [AppleGaussianSplatCaptureOptions.format] it additionally
/// contains a nerfstudio-format `transforms.json` plus `sparse_pc.ply`
/// (for nerfstudio/gsplat, Brush), a COLMAP text model under `sparse/0/`
/// (for LichtFeld Studio, reference 3DGS), or both.
class AppleGaussianSplatDataset {
  /// Creates a dataset summary.
  const AppleGaussianSplatDataset({
    required this.datasetPath,
    required this.imageCount,
    required this.pointCount,
    this.rejectedImageCount = 0,
    this.transformsPath,
    this.pointCloudPath,
    this.colmapPath,
  });

  /// Root folder of the captured dataset.
  final String datasetPath;

  /// Path to the nerfstudio-format `transforms.json` file, when the
  /// nerfstudio layout was requested.
  final String? transformsPath;

  /// Path to the sparse seed point cloud PLY, when the nerfstudio layout was
  /// requested and points were accumulated.
  final String? pointCloudPath;

  /// Path to the COLMAP text model folder (`sparse/0`), when the COLMAP
  /// layout was requested (LichtFeld Studio compatible).
  final String? colmapPath;

  /// Number of keyframe images saved.
  final int imageCount;

  /// Number of sparse points in the seed point cloud.
  final int pointCount;

  /// Number of frames rejected by the assisted-quality checks (motion blur)
  /// during capture. High values suggest scanning slower or adding light.
  final int rejectedImageCount;

  /// Creates a dataset summary from a native method-channel map.
  factory AppleGaussianSplatDataset.fromMap(Map<Object?, Object?> map) {
    final imageCountRaw = map['imageCount'];
    final pointCountRaw = map['pointCount'];
    final rejectedRaw = map['rejectedImageCount'];
    return AppleGaussianSplatDataset(
      datasetPath: (map['datasetPath'] as String? ?? '').trim(),
      transformsPath: (map['transformsPath'] as String?)?.trim(),
      pointCloudPath: (map['pointCloudPath'] as String?)?.trim(),
      colmapPath: (map['colmapPath'] as String?)?.trim(),
      imageCount: imageCountRaw is num ? imageCountRaw.toInt() : 0,
      pointCount: pointCountRaw is num ? pointCountRaw.toInt() : 0,
      rejectedImageCount: rejectedRaw is num ? rejectedRaw.toInt() : 0,
    );
  }
}

/// Options for on-device Gaussian-splat training (msplat engine).
class AppleGaussianSplatTrainingOptions {
  /// Creates training options with mobile-friendly defaults.
  const AppleGaussianSplatTrainingOptions({
    this.iterations = 3000,
    this.shDegree = 3,
    this.downscaleFactor = 1.0,
    this.maxImages = 0,
    this.exportSplatFile = false,
    this.saveCheckpoint = true,
  });

  /// Number of optimization iterations. Clamped to `100..30000`.
  ///
  /// 3000 gives a quick usable result; 7000+ approaches reference quality
  /// but takes proportionally longer, especially on iPhone.
  final int iterations;

  /// Maximum spherical-harmonics degree (view-dependent color detail).
  /// Clamped to `0..3`.
  final int shDegree;

  /// Training image downscale factor (1.0 = full resolution). Clamped to
  /// `1..8`.
  ///
  /// This is a minimum: on iOS the trainer plans against the process's
  /// actual memory headroom and automatically raises the factor (and, if
  /// needed, evenly subsamples frames) so the run fits without being killed.
  final double downscaleFactor;

  /// Maximum number of dataset images to train on (0 = no explicit cap).
  ///
  /// Frames are subsampled evenly across the capture. On iOS an automatic
  /// memory-based cap applies as well.
  final int maxImages;

  /// Also export a `.splat` file next to the `.ply`.
  final bool exportSplatFile;

  /// Save a reloadable engine checkpoint in the dataset folder so the
  /// trained splat can be previewed later with `previewGaussianSplat`.
  /// Costs disk space (roughly 700 bytes per gaussian).
  final bool saveCheckpoint;

  /// Converts this options object to a method-channel payload.
  Map<String, Object?> toMap() {
    return {
      'iterations': iterations,
      'shDegree': shDegree,
      'downscaleFactor': downscaleFactor,
      'maxImages': maxImages,
      'exportSplatFile': exportSplatFile,
      'saveCheckpoint': saveCheckpoint,
    };
  }
}

/// Result of an on-device Gaussian-splat training run.
class AppleGaussianSplatTrainingResult {
  /// Creates a training result.
  const AppleGaussianSplatTrainingResult({
    required this.splatPath,
    required this.iterations,
    required this.splatCount,
    required this.cameraCount,
    required this.elapsedSeconds,
    this.totalImageCount = 0,
    this.downscaleFactor = 1.0,
    this.cancelled = false,
    this.hitGaussianLimit = false,
    this.splatFilePath,
  });

  /// Path to the trained splat `.ply` file (written into the dataset folder).
  final String splatPath;

  /// Path to the `.splat` file, when requested via
  /// [AppleGaussianSplatTrainingOptions.exportSplatFile].
  final String? splatFilePath;

  /// Iterations actually run.
  final int iterations;

  /// Final number of gaussians in the trained scene.
  final int splatCount;

  /// Number of training cameras loaded from the dataset.
  final int cameraCount;

  /// Total images in the dataset before any memory-based subsampling.
  final int totalImageCount;

  /// Downscale factor actually used (may exceed the requested value on iOS
  /// when the memory planner reduces resolution to fit).
  final double downscaleFactor;

  /// Whether the run was stopped early via `cancelGaussianSplatTraining`.
  /// The exported splat reflects the iterations completed before the stop.
  final bool cancelled;

  /// Whether the run stopped early because it reached the device's memory
  /// budget for gaussians (iOS only). The splat is still valid, just less
  /// dense — train on a Mac for a fuller result.
  final bool hitGaussianLimit;

  /// Wall-clock training time in seconds.
  final int elapsedSeconds;

  /// Creates a training result from a native method-channel map.
  factory AppleGaussianSplatTrainingResult.fromMap(Map<Object?, Object?> map) {
    int intOf(Object? value) => value is num ? value.toInt() : 0;
    final downscaleRaw = map['downscaleFactor'];
    return AppleGaussianSplatTrainingResult(
      splatPath: (map['splatPath'] as String? ?? '').trim(),
      splatFilePath: (map['splatFilePath'] as String?)?.trim(),
      iterations: intOf(map['iterations']),
      splatCount: intOf(map['splatCount']),
      cameraCount: intOf(map['cameraCount']),
      totalImageCount: intOf(map['totalImageCount']),
      downscaleFactor: downscaleRaw is num ? downscaleRaw.toDouble() : 1.0,
      cancelled: map['cancelled'] as bool? ?? false,
      hitGaussianLimit: map['hitGaussianLimit'] as bool? ?? false,
      elapsedSeconds: intOf(map['elapsedSeconds']),
    );
  }
}

/// An open embedded-viewport render session for a trained splat dataset,
/// created with `openSplatViewport`.
class AppleSplatViewportSession {
  /// Creates a viewport session summary.
  const AppleSplatViewportSession({
    required this.sessionId,
    required this.splatCount,
    required this.orbitRadius,
  });

  /// Native session handle for render/close calls.
  final int sessionId;

  /// Number of gaussians in the loaded checkpoint.
  final int splatCount;

  /// Estimated orbit radius (mean camera distance from the subject center).
  /// `distanceScale` in `renderSplatViewport` multiplies this value.
  final double orbitRadius;

  /// Creates a session summary from a native method-channel map.
  factory AppleSplatViewportSession.fromMap(Map<Object?, Object?> map) {
    final sessionIdRaw = map['sessionId'];
    final splatCountRaw = map['splatCount'];
    final orbitRadiusRaw = map['orbitRadius'];
    return AppleSplatViewportSession(
      sessionId: sessionIdRaw is num ? sessionIdRaw.toInt() : -1,
      splatCount: splatCountRaw is num ? splatCountRaw.toInt() : 0,
      orbitRadius: orbitRadiusRaw is num ? orbitRadiusRaw.toDouble() : 1.0,
    );
  }
}

/// Serialized values for [AppleSpatialCaptureFileType].
extension AppleSpatialCaptureFileTypeValue on AppleSpatialCaptureFileType {
  /// File extension value used by native preview calls.
  String get value {
    switch (this) {
      case AppleSpatialCaptureFileType.glb:
        return 'glb';
      case AppleSpatialCaptureFileType.gltf:
        return 'gltf';
      case AppleSpatialCaptureFileType.usdz:
        return 'usdz';
      case AppleSpatialCaptureFileType.obj:
        return 'obj';
    }
  }
}

/// Infers a supported model file type from a path or URL extension.
AppleSpatialCaptureFileType inferAppleSpatialCaptureFileType(String path) {
  final normalized = path.trim().toLowerCase();
  if (!normalized.contains('.')) {
    return AppleSpatialCaptureFileType.usdz;
  }
  final ext = normalized.split('.').last;
  switch (ext) {
    case 'glb':
      return AppleSpatialCaptureFileType.glb;
    case 'gltf':
      return AppleSpatialCaptureFileType.gltf;
    case 'obj':
      return AppleSpatialCaptureFileType.obj;
    case 'usdz':
    default:
      return AppleSpatialCaptureFileType.usdz;
  }
}

/// Feature availability reported by the current Apple device.
class AppleSpatialCaptureSupport {
  /// Creates a support status object.
  const AppleSpatialCaptureSupport({
    required this.photogrammetry,
    required this.lidar,
    required this.roomPlan,
    this.gaussianSplat = false,
    this.gaussianSplatTraining = false,
  });

  /// Whether photogrammetry capture or reconstruction is supported.
  final bool photogrammetry;

  /// Whether LiDAR mesh capture is supported.
  final bool lidar;

  /// Whether RoomPlan capture is supported.
  final bool roomPlan;

  /// Whether Gaussian-splat dataset capture is supported.
  final bool gaussianSplat;

  /// Whether on-device Gaussian-splat training is supported (Apple-silicon
  /// Mac on macOS 14+, or experimentally a recent iPhone/iPad on iOS 16+).
  final bool gaussianSplatTraining;
}

/// Progress stage emitted by native photogrammetry operations.
enum AppleSpatialCaptureProgressStage {
  /// The operation is preparing inputs.
  preparing,

  /// The operation is ingesting selected images.
  ingesting,

  /// The operation is reconstructing geometry or textures.
  processing,

  /// The operation is finalizing output files.
  finalizing,

  /// The operation completed successfully.
  completed,

  /// The operation was cancelled.
  cancelled,

  /// The operation failed.
  failed,

  /// Informational status event.
  info,
}

AppleSpatialCaptureProgressStage _progressStageFromString(String value) {
  switch (value) {
    case 'preparing':
      return AppleSpatialCaptureProgressStage.preparing;
    case 'ingesting':
      return AppleSpatialCaptureProgressStage.ingesting;
    case 'processing':
      return AppleSpatialCaptureProgressStage.processing;
    case 'finalizing':
      return AppleSpatialCaptureProgressStage.finalizing;
    case 'completed':
      return AppleSpatialCaptureProgressStage.completed;
    case 'cancelled':
      return AppleSpatialCaptureProgressStage.cancelled;
    case 'failed':
      return AppleSpatialCaptureProgressStage.failed;
    case 'info':
    default:
      return AppleSpatialCaptureProgressStage.info;
  }
}

/// Progress payload emitted by the native photogrammetry event stream.
class AppleSpatialCaptureProgress {
  /// Creates a progress event.
  const AppleSpatialCaptureProgress({
    required this.operation,
    required this.stage,
    required this.message,
    this.progress,
    this.etaSeconds,
    this.elapsedSeconds,
    this.operationId,
    this.stepIndex,
    this.stepTotal,
    this.stepLabel,
  });

  /// Native operation name.
  final String operation;

  /// Current high-level progress stage.
  final AppleSpatialCaptureProgressStage stage;

  /// Human-readable progress message.
  final String message;

  /// Fractional progress in the range `0.0` to `1.0`, when available.
  final double? progress;

  /// Estimated remaining seconds, when the native API provides it.
  final int? etaSeconds;

  /// Elapsed seconds since the operation started, when available.
  final int? elapsedSeconds;

  /// Optional caller-provided operation identifier.
  final String? operationId;

  /// Current pipeline step index, when available.
  final int? stepIndex;

  /// Total pipeline step count, when available.
  final int? stepTotal;

  /// Human-readable pipeline step label, when available.
  final String? stepLabel;

  /// Creates a progress event from a native method-channel map.
  factory AppleSpatialCaptureProgress.fromMap(Map<Object?, Object?> map) {
    final stageRaw = (map['stage'] as String? ?? 'info').trim().toLowerCase();
    final progressRaw = map['progress'];
    final progressValue = progressRaw is num ? progressRaw.toDouble() : null;
    final etaRaw = map['etaSeconds'];
    final etaValue = etaRaw is num ? etaRaw.toInt() : null;
    final elapsedRaw = map['elapsedSeconds'];
    final elapsedValue = elapsedRaw is num ? elapsedRaw.toInt() : null;
    final stepIndexRaw = map['stepIndex'];
    final stepTotalRaw = map['stepTotal'];
    final stepIndexValue = stepIndexRaw is num ? stepIndexRaw.toInt() : null;
    final stepTotalValue = stepTotalRaw is num ? stepTotalRaw.toInt() : null;

    return AppleSpatialCaptureProgress(
      operation: (map['operation'] as String? ?? 'unknown').trim(),
      stage: _progressStageFromString(stageRaw),
      message: (map['message'] as String? ?? '').trim(),
      progress: progressValue,
      etaSeconds: etaValue,
      elapsedSeconds: elapsedValue,
      operationId: (map['operationId'] as String?)?.trim(),
      stepIndex: stepIndexValue,
      stepTotal: stepTotalValue,
      stepLabel: (map['stepLabel'] as String?)?.trim(),
    );
  }
}

/// Exception thrown by the plugin for platform and validation failures.
class AppleSpatialCaptureError implements Exception {
  /// Creates a plugin error.
  const AppleSpatialCaptureError({
    required this.code,
    required this.message,
    this.details,
  });

  /// Stable error code.
  final String code;

  /// Human-readable error message.
  final String message;

  /// Optional platform-specific error details.
  final Object? details;

  @override
  String toString() => 'AppleSpatialCaptureError($code): $message';
}
