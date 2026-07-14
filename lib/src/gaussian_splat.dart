import 'package:flutter/services.dart';

import '../apple_spatial_capture.dart';

/// Progress-stream operation name emitted by on-device splat training.
const String kGaussianSplatTrainingOperation = 'gaussian_splat_training';

/// Cohesive entry point for the Gaussian-splatting workflow.
///
/// Groups the whole pipeline — capture a dataset, manage/share datasets,
/// train a splat on-device, preview it full-screen, and drive an embedded
/// editable viewport — behind one object instead of the flat, low-level
/// methods on [AppleSpatialCapturePlatform]. Obtain it from
/// [AppleSpatialCapture.gaussianSplat].
///
/// The platform interface remains available for advanced or backward-compatible
/// use; this facade is the recommended surface for app code.
class GaussianSplatApi {
  /// Creates a facade over [platform] (defaults to the active plugin
  /// platform). Pass a fake platform in tests.
  GaussianSplatApi([AppleSpatialCapturePlatform? platform])
    : _platform = platform ?? AppleSpatialCapture.platform;

  final AppleSpatialCapturePlatform _platform;

  // ── Support ────────────────────────────────────────────────────────────

  /// Whether Gaussian-splat dataset capture is available on this device.
  Future<bool> get isCaptureSupported =>
      _platform.isGaussianSplatCaptureSupported();

  /// Whether on-device Gaussian-splat training is available on this device.
  Future<bool> get isTrainingSupported =>
      _platform.isGaussianSplatTrainingSupported();

  // ── Progress ───────────────────────────────────────────────────────────

  /// Training progress events, scoped to the splat-training operation.
  ///
  /// Filters [AppleSpatialCapturePlatform.progressStream] to the
  /// `gaussian_splat_training` operation so callers don't see unrelated
  /// photogrammetry events. Pass the same `operationId` to [train] to
  /// correlate a specific run.
  Stream<AppleSpatialCaptureProgress> get trainingProgress => _platform
      .progressStream
      .where((event) => event.operation == kGaussianSplatTrainingOperation);

  // ── Capture ────────────────────────────────────────────────────────────

  /// Starts the full-screen AR capture flow and returns the captured dataset,
  /// or null if the user cancels.
  Future<AppleGaussianSplatDataset?> capture({
    AppleGaussianSplatCaptureOptions options =
        const AppleGaussianSplatCaptureOptions(),
  }) => _platform.startGaussianSplatCapture(options: options);

  // ── Datasets ───────────────────────────────────────────────────────────

  /// Lists captured dataset folders on this device, newest first.
  Future<List<String>> listDatasets() => _platform.listGaussianSplatDatasets();

  /// Zips a dataset folder and opens the share sheet (AirDrop, Files, …).
  /// Returns true when the user completed a share action.
  Future<bool> shareDataset(String datasetPath) =>
      _platform.shareGaussianSplatDataset(datasetPath: datasetPath);

  // ── Training ───────────────────────────────────────────────────────────

  /// Trains a splat on-device from a captured dataset.
  ///
  /// Observe [trainingProgress] for live updates. On iOS the run may reduce
  /// resolution/frames and cap gaussian growth to fit memory — see the
  /// returned [AppleGaussianSplatTrainingResult].
  Future<AppleGaussianSplatTrainingResult> train({
    required String datasetPath,
    String? operationId,
    AppleGaussianSplatTrainingOptions options =
        const AppleGaussianSplatTrainingOptions(),
  }) => _platform.trainGaussianSplat(
    datasetPath: datasetPath,
    operationId: operationId,
    options: options,
  );

  /// Stops the active [train] run at the next iteration; it still exports
  /// what it trained so far. Returns false when no run is active.
  Future<bool> cancelTraining() => _platform.cancelGaussianSplatTraining();

  // ── Preview & viewport ─────────────────────────────────────────────────

  /// Opens the full-screen native orbit viewer for a trained dataset.
  Future<void> preview(String datasetPath) =>
      _platform.previewGaussianSplat(datasetPath: datasetPath);

  /// Opens an embedded, editable viewport for a trained dataset.
  ///
  /// The returned [AppleGaussianSplatViewport] renders orbit frames and
  /// supports editing (crop/cleanup/undo/save). Always [close][
  /// AppleGaussianSplatViewport.close] it when done.
  Future<AppleGaussianSplatViewport> openViewport(String datasetPath) async {
    final session = await _platform.openSplatViewport(datasetPath: datasetPath);
    return AppleGaussianSplatViewport._(
      _platform,
      session,
      datasetPath: datasetPath,
      editable: true,
    );
  }

  /// Opens an embedded, view-only viewport for a standalone `.ply` splat
  /// (e.g. one downloaded from the cloud). Editing is unavailable because a
  /// bare `.ply` lacks the training buffers edits need.
  Future<AppleGaussianSplatViewport> openPlyViewport(String plyPath) async {
    final session = await _platform.openSplatPlyViewport(plyPath: plyPath);
    return AppleGaussianSplatViewport._(
      _platform,
      session,
      datasetPath: null,
      editable: false,
    );
  }
}

/// A live embedded splat viewport render/edit session.
///
/// Wraps the native session so callers render and edit by calling methods on
/// this object instead of threading a session id through the platform
/// interface. Open one with [GaussianSplatApi.openViewport] (editable) or
/// [GaussianSplatApi.openPlyViewport] (view-only), and [close] it when done.
class AppleGaussianSplatViewport {
  AppleGaussianSplatViewport._(
    this._platform,
    this._session, {
    required this.datasetPath,
    required this.editable,
  }) : _splatCount = _session.splatCount;

  final AppleSpatialCapturePlatform _platform;
  final AppleSplatViewportSession _session;

  /// The dataset folder backing this session, or null for a view-only
  /// `.ply` session.
  final String? datasetPath;

  /// Whether this session supports editing. False for `.ply` sessions.
  final bool editable;

  int _splatCount;
  bool _closed = false;

  /// Native session handle.
  int get sessionId => _session.sessionId;

  /// Estimated orbit radius; `distanceScale` in [renderFrame] scales this.
  double get orbitRadius => _session.orbitRadius;

  /// Current gaussian count, updated after edits.
  int get splatCount => _splatCount;

  /// Whether [close] has been called.
  bool get isClosed => _closed;

  /// Renders one orbit frame as encoded JPEG bytes, or null if it cannot be
  /// produced. [azimuth]/[elevation] are radians; [distanceScale] multiplies
  /// [orbitRadius]. Keep at most one render in flight and send the latest
  /// pose.
  Future<Uint8List?> renderFrame({
    double azimuth = 0,
    double elevation = 0.35,
    double distanceScale = 1,
  }) {
    _ensureOpen();
    return _platform.renderSplatViewport(
      sessionId: sessionId,
      azimuth: azimuth,
      elevation: elevation,
      distanceScale: distanceScale,
    );
  }

  /// Removes low-opacity, oversized and non-finite gaussians (pass 0 to skip
  /// a criterion). Returns and stores the new [splatCount].
  Future<int> cleanup({double minOpacity = 0, double maxWorldScale = 0}) async {
    _ensureEditable();
    _splatCount = await _platform.cleanupSplatViewport(
      sessionId: sessionId,
      minOpacity: minOpacity,
      maxWorldScale: maxWorldScale,
    );
    return _splatCount;
  }

  /// Keeps the [keepFraction] of gaussians closest to the subject center.
  /// Returns and stores the new [splatCount].
  Future<int> crop({double keepFraction = 0.85}) async {
    _ensureEditable();
    _splatCount = await _platform.cropSplatViewport(
      sessionId: sessionId,
      keepFraction: keepFraction,
    );
    return _splatCount;
  }

  /// Saves an undo snapshot of the current scene to [path].
  Future<void> snapshot(String path) {
    _ensureOpen();
    return _platform.snapshotSplatViewport(sessionId: sessionId, path: path);
  }

  /// Restores a snapshot saved with [snapshot]. Returns and stores the new
  /// [splatCount].
  Future<int> restore(String path) async {
    _ensureOpen();
    _splatCount = await _platform.restoreSplatViewport(
      sessionId: sessionId,
      path: path,
    );
    return _splatCount;
  }

  /// Writes the edited scene back into the dataset folder (splat.ply,
  /// preview checkpoint, and splat.splat when present).
  Future<void> saveEdits() {
    _ensureEditable();
    final path = datasetPath;
    if (path == null) {
      throw const AppleSpatialCaptureError(
        code: 'NOT_EDITABLE',
        message: 'This viewport session has no dataset to save into.',
      );
    }
    return _platform.saveSplatViewportEdits(
      sessionId: sessionId,
      datasetPath: path,
    );
  }

  /// Releases the native session. Idempotent.
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _platform.closeSplatViewport(sessionId: sessionId);
  }

  void _ensureOpen() {
    if (_closed) {
      throw const AppleSpatialCaptureError(
        code: 'INVALID_SESSION',
        message: 'This viewport session has been closed.',
      );
    }
  }

  void _ensureEditable() {
    _ensureOpen();
    if (!editable) {
      throw const AppleSpatialCaptureError(
        code: 'NOT_EDITABLE',
        message:
            'This is a view-only .ply session; editing needs a dataset '
            'session opened with openViewport().',
      );
    }
  }
}
