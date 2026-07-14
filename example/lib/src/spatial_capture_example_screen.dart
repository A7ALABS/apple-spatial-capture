import 'dart:async';
import 'dart:io';

import 'package:apple_spatial_capture/apple_spatial_capture.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import 'tabs/capture_tab.dart';
import 'tabs/photos_tab.dart';
import 'tabs/preview_tab.dart';
import 'widgets/status_banner.dart';

class SpatialCaptureExampleScreen extends StatefulWidget {
  const SpatialCaptureExampleScreen({super.key});

  @override
  State<SpatialCaptureExampleScreen> createState() =>
      _SpatialCaptureExampleScreenState();
}

class _SpatialCaptureExampleScreenState
    extends State<SpatialCaptureExampleScreen> {
  final ImagePicker _imagePicker = ImagePicker();
  final TextEditingController _localPathController = TextEditingController();
  final TextEditingController _remoteUrlController = TextEditingController();
  final TextEditingController _remoteFileNameController =
      TextEditingController();
  final TextEditingController _trainDatasetPathController =
      TextEditingController();

  AppleSpatialCaptureSupport? _support;
  AppleSpatialCaptureFileType _remoteFileType =
      AppleSpatialCaptureFileType.usdz;
  ApplePhotogrammetryOutputFormat _photoOutputFormat =
      ApplePhotogrammetryOutputFormat.obj;
  ApplePhotogrammetryTextureQuality _photoTextureQuality =
      ApplePhotogrammetryTextureQuality.low;
  ApplePhotogrammetrySampleOrdering _photoSampleOrdering =
      ApplePhotogrammetrySampleOrdering.unordered;
  ApplePhotogrammetryFeatureSensitivity _photoFeatureSensitivity =
      ApplePhotogrammetryFeatureSensitivity.normal;
  bool _useObjectMasking = false;
  AppleGaussianSplatDatasetFormat _splatDatasetFormat =
      AppleGaussianSplatDatasetFormat.nerfstudio;

  StreamSubscription<AppleSpatialCaptureProgress>? _progressSubscription;
  Timer? _elapsedTimer;
  DateTime? _operationStartedAt;
  String? _activeOperationId;
  String? _lastModelPath;
  String? _lastDatasetSummary;
  String? _lastDatasetPath;
  String? _lastTrainingSummary;
  int _trainingIterations = 3000;
  List<String> _availableDatasets = const [];
  String? _errorMessage;
  String _statusMessage = 'Checking device support...';
  bool _isCheckingSupport = true;
  bool _isWorking = false;
  double? _progress;
  int? _elapsedSeconds;
  final List<String> _progressLog = <String>[];

  @override
  void initState() {
    super.initState();
    _loadSupport();
    _loadAvailableDatasets();
  }

  Future<void> _loadAvailableDatasets() async {
    if (!_isAppleSpatialPlatform) return;
    try {
      final datasets = await AppleSpatialCapture.gaussianSplat.listDatasets();
      if (!mounted) return;
      setState(() {
        _availableDatasets = datasets;
        if (_trainDatasetPathController.text.trim().isEmpty &&
            datasets.isNotEmpty) {
          _trainDatasetPathController.text = datasets.first;
        }
      });
    } catch (_) {
      // Older native builds without the listing method; the text field
      // remains usable.
    }
  }

  @override
  void dispose() {
    _elapsedTimer?.cancel();
    _progressSubscription?.cancel();
    _localPathController.dispose();
    _remoteUrlController.dispose();
    _remoteFileNameController.dispose();
    _trainDatasetPathController.dispose();
    super.dispose();
  }

  Future<void> _loadSupport() async {
    if (!_isAppleSpatialPlatform) {
      setState(() {
        _isCheckingSupport = false;
        _statusMessage =
            'This plugin runs on iOS, iPadOS, and supported macOS devices.';
      });
      return;
    }

    setState(() {
      _isCheckingSupport = true;
      _errorMessage = null;
      _elapsedSeconds = null;
      _statusMessage = 'Checking device support...';
    });

    try {
      final support = await AppleSpatialCapture.platform.supportStatus();
      if (!mounted) return;
      setState(() {
        _support = support;
        _isCheckingSupport = false;
        _statusMessage = 'Support status loaded.';
      });
    } on AppleSpatialCaptureError catch (error) {
      if (!mounted) return;
      _setError(error.message);
      setState(() => _isCheckingSupport = false);
    } catch (error) {
      if (!mounted) return;
      _setError('Could not load support status: $error');
      setState(() => _isCheckingSupport = false);
    }
  }

  Future<void> _startGuidedObjectCapture() async {
    if (!Platform.isIOS) {
      _setError(
        'Guided Object Capture requires a supported iPhone or iPad. Use photo reconstruction on macOS.',
      );
      return;
    }
    if (!_ensureSupported(_support?.photogrammetry, 'Object Capture')) return;

    await _runModelCapture(
      statusMessage: 'Opening Object Capture...',
      startCapture: AppleSpatialCapture.platform.startPhotogrammetryCapture,
    );
  }

  Future<void> _startLiDARCapture() async {
    if (!Platform.isIOS) {
      _setError('LiDAR scanning requires a supported iPhone or iPad.');
      return;
    }
    if (!_ensureSupported(_support?.lidar, 'LiDAR scanning')) return;

    await _runModelCapture(
      statusMessage: 'Opening LiDAR scanner...',
      startCapture: AppleSpatialCapture.platform.startLiDARCapture,
    );
  }

  Future<void> _startRoomPlanCapture() async {
    if (!Platform.isIOS) {
      _setError('RoomPlan requires a supported iPhone or iPad.');
      return;
    }
    if (!_ensureSupported(_support?.roomPlan, 'RoomPlan')) return;

    await _runModelCapture(
      statusMessage: 'Opening RoomPlan scanner...',
      startCapture: AppleSpatialCapture.platform.startRoomPlanCapture,
    );
  }

  Future<void> _startGaussianSplatCapture() async {
    if (!Platform.isIOS) {
      _setError('Gaussian splat capture requires a supported iPhone or iPad.');
      return;
    }
    if (!_ensureSupported(_support?.gaussianSplat, 'Gaussian splat capture')) {
      return;
    }

    setState(() {
      _isWorking = true;
      _errorMessage = null;
      _progress = null;
      _elapsedSeconds = null;
      _statusMessage = 'Opening Gaussian splat capture...';
      _progressLog.clear();
    });

    try {
      final dataset = await AppleSpatialCapture.gaussianSplat.capture(
        options: AppleGaussianSplatCaptureOptions(format: _splatDatasetFormat),
      );
      if (!mounted) return;
      if (dataset == null) {
        setState(() => _statusMessage = 'Capture cancelled.');
        return;
      }

      final layouts = <String>[
        if (dataset.transformsPath != null) 'transforms.json',
        if (dataset.colmapPath != null) 'COLMAP sparse/0',
      ].join(' + ');
      final rejectedNote = dataset.rejectedImageCount > 0
          ? ', ${dataset.rejectedImageCount} blurry skipped'
          : '';
      setState(() {
        _lastDatasetSummary =
            '${dataset.imageCount} images$rejectedNote, '
            '${dataset.pointCount} seed points ($layouts)\n'
            '${dataset.datasetPath}';
        _lastDatasetPath = dataset.datasetPath;
        _trainDatasetPathController.text = dataset.datasetPath;
        _statusMessage =
            'Dataset captured: ${dataset.imageCount} images ready for training.';
      });
      await _loadAvailableDatasets();
    } on AppleSpatialCaptureError catch (error) {
      _setError(error.message);
    } catch (error) {
      _setError('Gaussian splat capture failed: $error');
    } finally {
      if (mounted) {
        setState(() => _isWorking = false);
      }
    }
  }

  Future<void> _trainGaussianSplat() async {
    final datasetPath = _trainDatasetPathController.text.trim();
    if (datasetPath.isEmpty) {
      _setError('Enter a dataset folder path (capture one first on iPhone).');
      return;
    }
    if (!_ensureSupported(
      _support?.gaussianSplatTraining,
      'Gaussian splat training',
    )) {
      return;
    }

    final operationId = 'train_${DateTime.now().microsecondsSinceEpoch}';
    _activeOperationId = operationId;
    _startElapsedTimer();
    await _progressSubscription?.cancel();
    _progressSubscription = AppleSpatialCapture.platform.progressStream.listen(
      _handleProgressEvent,
      onError: (Object error) => _appendProgressLog('Progress error: $error'),
    );

    setState(() {
      _isWorking = true;
      _errorMessage = null;
      _progress = null;
      _lastTrainingSummary = null;
      _statusMessage = 'Training Gaussian splat...';
      _progressLog
        ..clear()
        ..add('Starting on-device splat training...');
    });

    try {
      final result = await AppleSpatialCapture.gaussianSplat.train(
        datasetPath: datasetPath,
        operationId: operationId,
        options: AppleGaussianSplatTrainingOptions(
          iterations: _trainingIterations,
        ),
      );
      if (!mounted) return;
      setState(() {
        _lastTrainingSummary =
            '${result.splatCount} gaussians from ${result.cameraCount} views '
            'in ${_formatDuration(result.elapsedSeconds)}\n${result.splatPath}';
        _statusMessage = 'Splat trained: ${result.splatPath}';
      });
    } on AppleSpatialCaptureError catch (error) {
      _setError(error.message);
    } catch (error) {
      _setError('Training failed: $error');
    } finally {
      await _progressSubscription?.cancel();
      _progressSubscription = null;
      _activeOperationId = null;
      _stopElapsedTimer();
      if (mounted) {
        setState(() => _isWorking = false);
      }
    }
  }

  Future<void> _previewTrainedSplat() async {
    final datasetPath = _trainDatasetPathController.text.trim();
    if (datasetPath.isEmpty) {
      _setError('Select or enter a dataset folder path first.');
      return;
    }

    try {
      await AppleSpatialCapture.gaussianSplat.preview(datasetPath);
      if (!mounted) return;
      setState(() => _statusMessage = 'Splat preview opened.');
    } on AppleSpatialCaptureError catch (error) {
      _setError(error.message);
    } catch (error) {
      _setError('Could not preview splat: $error');
    }
  }

  Future<void> _shareLastDataset() async {
    final path = _lastDatasetPath;
    if (path == null || path.isEmpty) {
      _setError('Capture a Gaussian splat dataset first.');
      return;
    }

    setState(() {
      _isWorking = true;
      _errorMessage = null;
      _statusMessage = 'Preparing dataset archive...';
    });

    try {
      final shared = await AppleSpatialCapture.gaussianSplat.shareDataset(path);
      if (!mounted) return;
      setState(() {
        _statusMessage = shared ? 'Dataset shared.' : 'Share sheet dismissed.';
      });
    } on AppleSpatialCaptureError catch (error) {
      _setError(error.message);
    } catch (error) {
      _setError('Could not share dataset: $error');
    } finally {
      if (mounted) {
        setState(() => _isWorking = false);
      }
    }
  }

  Future<void> _startPhotoReconstruction() async {
    if (!_ensureSupported(_support?.photogrammetry, 'Photogrammetry')) return;

    setState(() {
      _errorMessage = null;
      _progress = null;
      _elapsedSeconds = null;
      _lastModelPath = null;
      _statusMessage = 'Opening photo picker...';
      _progressLog
        ..clear()
        ..add('Opening photo picker...');
    });

    List<XFile> images;
    try {
      images = await _imagePicker.pickMultiImage();
    } catch (error) {
      _setError('Could not open the photo library: $error');
      _appendProgressLog('Photo picker failed: $error');
      return;
    }
    if (!mounted) return;

    _appendProgressLog('Photo picker returned ${images.length} file(s).');

    final imagePaths = images
        .map((image) => image.path.trim())
        .where((path) => path.isNotEmpty)
        .toList();

    if (imagePaths.length < 3) {
      _setError('Select at least 3 images for photogrammetry.');
      _appendProgressLog(
        'Only ${imagePaths.length} usable image path(s) were selected.',
      );
      return;
    }

    final operationId = 'example_${DateTime.now().microsecondsSinceEpoch}';
    _activeOperationId = operationId;
    _startElapsedTimer();
    await _progressSubscription?.cancel();
    _progressSubscription = AppleSpatialCapture.platform.progressStream.listen(
      _handleProgressEvent,
      onError: (Object error) => _appendProgressLog('Progress error: $error'),
    );

    setState(() {
      _isWorking = true;
      _errorMessage = null;
      _progress = null;
      _elapsedSeconds = 0;
      _lastModelPath = null;
      _statusMessage = 'Generating model from ${imagePaths.length} photos...';
      _progressLog
        ..insert(0, 'Starting native photogrammetry...')
        ..add('Selected ${imagePaths.length} photos.');
    });

    try {
      final path = await AppleSpatialCapture.platform
          .startPhotogrammetryFromImages(
            imagePaths,
            operationId: operationId,
            options: ApplePhotogrammetryOptions(
              detail: _detailForTextureQuality(_photoTextureQuality),
              outputFormat: _photoOutputFormat,
              textureQuality: _photoTextureQuality,
              sampleOrdering: _photoSampleOrdering,
              featureSensitivity: _photoFeatureSensitivity,
              useObjectMasking: _useObjectMasking,
            ),
          );

      if (!mounted) return;
      if (path == null || path.trim().isEmpty) {
        _setError('Photogrammetry was cancelled before export.');
        return;
      }

      setState(() {
        _lastModelPath = path;
        _localPathController.text = path;
        _statusMessage = _elapsedSeconds == null
            ? 'Photo reconstruction complete.'
            : 'Photo reconstruction complete in ${_formatDuration(_elapsedSeconds!)}.';
      });
    } on AppleSpatialCaptureError catch (error) {
      _setError(error.message);
    } catch (error) {
      _setError('Photogrammetry failed: $error');
    } finally {
      await _progressSubscription?.cancel();
      _progressSubscription = null;
      _activeOperationId = null;
      _stopElapsedTimer();
      if (mounted) {
        setState(() => _isWorking = false);
      }
    }
  }

  Future<void> _runModelCapture({
    required String statusMessage,
    required Future<String?> Function() startCapture,
  }) async {
    setState(() {
      _isWorking = true;
      _errorMessage = null;
      _progress = null;
      _elapsedSeconds = null;
      _lastModelPath = null;
      _statusMessage = statusMessage;
      _progressLog.clear();
    });

    try {
      final path = await startCapture();
      if (!mounted) return;
      if (path == null || path.trim().isEmpty) {
        setState(() => _statusMessage = 'Capture cancelled.');
        return;
      }

      setState(() {
        _lastModelPath = path;
        _localPathController.text = path;
        _statusMessage = 'Capture complete.';
        _isWorking = false;
      });

      await Future<void>.delayed(const Duration(milliseconds: 250));
      if (!mounted) return;
      await _previewLocalPath(path);
    } on AppleSpatialCaptureError catch (error) {
      _setError(error.message);
    } catch (error) {
      _setError('Capture failed: $error');
    } finally {
      if (mounted) {
        setState(() => _isWorking = false);
      }
    }
  }

  Future<void> _previewLastModel() async {
    final path = _lastModelPath ?? _localPathController.text.trim();
    if (path.isEmpty) {
      _setError('Enter a local model path or finish a capture first.');
      return;
    }

    await _previewLocalPath(path);
  }

  Future<void> _previewLocalPath(String path) async {
    try {
      await AppleSpatialCapture.platform.previewCapturedModel(
        path: path,
        fileType: inferAppleSpatialCaptureFileType(path),
      );
    } on AppleSpatialCaptureError catch (error) {
      _setError(error.message);
    } catch (error) {
      _setError('Could not preview local model: $error');
    }
  }

  Future<void> _previewRemoteModel() async {
    final url = _remoteUrlController.text.trim();
    if (url.isEmpty) {
      _setError('Enter an http or https model URL.');
      return;
    }

    final providedName = _remoteFileNameController.text.trim();
    final fileName = providedName.isEmpty
        ? 'model.${_remoteFileType.value}'
        : _ensureFileExtension(providedName, _remoteFileType);

    setState(() {
      _isWorking = true;
      _errorMessage = null;
      _elapsedSeconds = null;
      _statusMessage = 'Downloading remote model preview...';
    });

    try {
      await AppleSpatialCapture.platform.previewRemoteModel(
        url: url,
        fileName: fileName,
        fileType: _remoteFileType,
      );
      if (!mounted) return;
      setState(() => _statusMessage = 'Remote preview opened.');
    } on AppleSpatialCaptureError catch (error) {
      _setError(error.message);
    } catch (error) {
      _setError('Could not preview remote model: $error');
    } finally {
      if (mounted) {
        setState(() => _isWorking = false);
      }
    }
  }

  bool _ensureSupported(bool? isSupported, String featureName) {
    if (!_isAppleSpatialPlatform) {
      _setError('$featureName requires iOS, iPadOS, or macOS.');
      return false;
    }
    if (isSupported != true) {
      _setError('$featureName is not supported on this device.');
      return false;
    }
    return true;
  }

  void _handleProgressEvent(AppleSpatialCaptureProgress event) {
    if (event.operationId != _activeOperationId) return;
    if (!mounted) return;

    final pieces = <String>[
      event.stage.name,
      if (event.stepIndex != null && event.stepTotal != null)
        '${event.stepIndex}/${event.stepTotal}',
      if ((event.stepLabel ?? '').isNotEmpty) event.stepLabel!,
      if (event.message.isNotEmpty) event.message,
      if (event.elapsedSeconds != null)
        '${_formatDuration(event.elapsedSeconds!)} elapsed',
      if (event.etaSeconds != null) '${event.etaSeconds}s remaining',
    ];

    setState(() {
      _progress = event.progress;
      final statusText = event.stepLabel ?? event.message;
      if (event.elapsedSeconds != null) {
        final currentElapsed = _elapsedSeconds;
        _elapsedSeconds = currentElapsed == null
            ? event.elapsedSeconds
            : event.elapsedSeconds! > currentElapsed
            ? event.elapsedSeconds
            : currentElapsed;
      }
      _statusMessage = statusText;
      _progressLog.insert(0, pieces.join(' - '));
      if (_progressLog.length > 8) {
        _progressLog.removeLast();
      }
    });
  }

  void _appendProgressLog(String message) {
    if (!mounted) return;
    setState(() {
      _progressLog.insert(0, message);
      if (_progressLog.length > 8) {
        _progressLog.removeLast();
      }
    });
  }

  void _setError(String message) {
    if (!mounted) return;
    setState(() {
      _errorMessage = message;
      _statusMessage = message;
    });
  }

  String _ensureFileExtension(
    String fileName,
    AppleSpatialCaptureFileType fileType,
  ) {
    if (fileName.contains('.')) return fileName;
    return '$fileName.${fileType.value}';
  }

  String _formatDuration(int seconds) {
    final duration = Duration(seconds: seconds);
    final hours = duration.inHours;
    final minutes = duration.inMinutes.remainder(60).toString().padLeft(2, '0');
    final secs = duration.inSeconds.remainder(60).toString().padLeft(2, '0');
    if (hours > 0) {
      return '$hours:$minutes:$secs';
    }
    return '${duration.inMinutes}:$secs';
  }

  ApplePhotogrammetryDetail _detailForTextureQuality(
    ApplePhotogrammetryTextureQuality textureQuality,
  ) {
    switch (textureQuality) {
      case ApplePhotogrammetryTextureQuality.low:
        return ApplePhotogrammetryDetail.reduced;
      case ApplePhotogrammetryTextureQuality.medium:
        return ApplePhotogrammetryDetail.medium;
      case ApplePhotogrammetryTextureQuality.high:
        return ApplePhotogrammetryDetail.full;
    }
  }

  void _startElapsedTimer() {
    _elapsedTimer?.cancel();
    _operationStartedAt = DateTime.now();
    _elapsedSeconds = 0;
    _elapsedTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      final startedAt = _operationStartedAt;
      if (!mounted || startedAt == null) return;
      setState(() {
        _elapsedSeconds = DateTime.now().difference(startedAt).inSeconds;
      });
    });
  }

  void _stopElapsedTimer() {
    _elapsedTimer?.cancel();
    _elapsedTimer = null;
    _operationStartedAt = null;
  }

  bool get _isAppleSpatialPlatform => Platform.isIOS || Platform.isMacOS;

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 3,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Apple Spatial Capture'),
          actions: [
            IconButton(
              tooltip: 'Refresh support',
              onPressed: _isWorking
                  ? null
                  : () {
                      _loadSupport();
                      _loadAvailableDatasets();
                    },
              icon: const Icon(Icons.refresh_rounded),
            ),
          ],
          bottom: const TabBar(
            tabs: [
              Tab(icon: Icon(Icons.view_in_ar_rounded), text: 'Capture'),
              Tab(icon: Icon(Icons.photo_library_rounded), text: 'Photos'),
              Tab(icon: Icon(Icons.open_in_new_rounded), text: 'Preview'),
            ],
          ),
        ),
        body: SafeArea(
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                child: StatusBanner(
                  isWorking: _isWorking || _isCheckingSupport,
                  message: _statusMessage,
                  errorMessage: _errorMessage,
                  progress: _progress,
                  elapsedLabel: _elapsedSeconds == null
                      ? null
                      : 'Elapsed ${_formatDuration(_elapsedSeconds!)}',
                ),
              ),
              Expanded(
                child: TabBarView(
                  children: [
                    CaptureTab(
                      support: _support,
                      isWorking: _isWorking,
                      supportsDeviceCapture: Platform.isIOS,
                      lastModelPath: _lastModelPath,
                      lastDatasetSummary: _lastDatasetSummary,
                      splatDatasetFormat: _splatDatasetFormat,
                      onSplatDatasetFormatChanged: (value) {
                        setState(() => _splatDatasetFormat = value);
                      },
                      trainDatasetPathController: _trainDatasetPathController,
                      availableDatasetPaths: _availableDatasets,
                      onDatasetSelected: (path) {
                        setState(() {
                          _trainDatasetPathController.text = path;
                        });
                      },
                      trainingIterations: _trainingIterations,
                      onTrainingIterationsChanged: (value) {
                        setState(() => _trainingIterations = value);
                      },
                      onTrainGaussianSplat: _trainGaussianSplat,
                      onPreviewSplat: _previewTrainedSplat,
                      lastTrainingSummary: _lastTrainingSummary,
                      onStartObjectCapture: _startGuidedObjectCapture,
                      onStartLiDARCapture: _startLiDARCapture,
                      onStartRoomPlanCapture: _startRoomPlanCapture,
                      onStartGaussianSplatCapture: _startGaussianSplatCapture,
                      onShareDataset: _lastDatasetPath == null
                          ? null
                          : _shareLastDataset,
                      onPreviewLastModel: _previewLastModel,
                    ),
                    PhotosTab(
                      isWorking: _isWorking,
                      outputFormat: _photoOutputFormat,
                      textureQuality: _photoTextureQuality,
                      sampleOrdering: _photoSampleOrdering,
                      featureSensitivity: _photoFeatureSensitivity,
                      useObjectMasking: _useObjectMasking,
                      progressLog: _progressLog,
                      onOutputFormatChanged: (value) {
                        setState(() => _photoOutputFormat = value);
                      },
                      onTextureQualityChanged: (value) {
                        setState(() => _photoTextureQuality = value);
                      },
                      onSampleOrderingChanged: (value) {
                        setState(() => _photoSampleOrdering = value);
                      },
                      onFeatureSensitivityChanged: (value) {
                        setState(() => _photoFeatureSensitivity = value);
                      },
                      onUseObjectMaskingChanged: (value) {
                        setState(() => _useObjectMasking = value);
                      },
                      onStartPhotoReconstruction: _startPhotoReconstruction,
                    ),
                    PreviewTab(
                      isWorking: _isWorking,
                      localPathController: _localPathController,
                      remoteUrlController: _remoteUrlController,
                      remoteFileNameController: _remoteFileNameController,
                      remoteFileType: _remoteFileType,
                      onRemoteFileTypeChanged: (value) {
                        setState(() => _remoteFileType = value);
                      },
                      onPreviewLocalModel: _previewLastModel,
                      onPreviewRemoteModel: _previewRemoteModel,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
