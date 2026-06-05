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

  AppleSpatialCaptureSupport? _support;
  AppleSpatialCaptureFileType _remoteFileType = AppleSpatialCaptureFileType.usdz;
  ApplePhotogrammetryOutputFormat _photoOutputFormat =
      ApplePhotogrammetryOutputFormat.obj;
  ApplePhotogrammetryTextureQuality _photoTextureQuality =
      ApplePhotogrammetryTextureQuality.low;
  ApplePhotogrammetrySampleOrdering _photoSampleOrdering =
      ApplePhotogrammetrySampleOrdering.unordered;
  ApplePhotogrammetryFeatureSensitivity _photoFeatureSensitivity =
      ApplePhotogrammetryFeatureSensitivity.normal;
  bool _useObjectMasking = false;

  StreamSubscription<AppleSpatialCaptureProgress>? _progressSubscription;
  String? _activeOperationId;
  String? _lastModelPath;
  String? _errorMessage;
  String _statusMessage = 'Checking device support...';
  bool _isCheckingSupport = true;
  bool _isWorking = false;
  double? _progress;
  final List<String> _progressLog = <String>[];

  @override
  void initState() {
    super.initState();
    _loadSupport();
  }

  @override
  void dispose() {
    _progressSubscription?.cancel();
    _localPathController.dispose();
    _remoteUrlController.dispose();
    _remoteFileNameController.dispose();
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

  Future<void> _startPhotoReconstruction() async {
    if (!_ensureSupported(_support?.photogrammetry, 'Photogrammetry')) return;

    List<XFile> images;
    try {
      images = await _imagePicker.pickMultiImage();
    } catch (error) {
      _setError('Could not open the photo library: $error');
      return;
    }
    if (!mounted) return;

    final imagePaths = images
        .map((image) => image.path.trim())
        .where((path) => path.isNotEmpty)
        .toList();

    if (imagePaths.length < 3) {
      _setError('Select at least 3 images for photogrammetry.');
      return;
    }

    final operationId = 'example_${DateTime.now().microsecondsSinceEpoch}';
    _activeOperationId = operationId;
    await _progressSubscription?.cancel();
    _progressSubscription = AppleSpatialCapture.platform.progressStream.listen(
      _handleProgressEvent,
      onError: (Object error) => _appendProgressLog('Progress error: $error'),
    );

    setState(() {
      _isWorking = true;
      _errorMessage = null;
      _progress = null;
      _lastModelPath = null;
      _statusMessage = 'Generating model from ${imagePaths.length} photos...';
      _progressLog
        ..clear()
        ..add('Selected ${imagePaths.length} photos.');
    });

    try {
      final path = await AppleSpatialCapture.platform
          .startPhotogrammetryFromImages(
            imagePaths,
            operationId: operationId,
            options: ApplePhotogrammetryOptions(
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
        _statusMessage = 'Photo reconstruction complete.';
      });
    } on AppleSpatialCaptureError catch (error) {
      _setError(error.message);
    } catch (error) {
      _setError('Photogrammetry failed: $error');
    } finally {
      await _progressSubscription?.cancel();
      _progressSubscription = null;
      _activeOperationId = null;
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
      if (event.etaSeconds != null) '${event.etaSeconds}s remaining',
    ];

    setState(() {
      _progress = event.progress;
      _statusMessage = event.stepLabel ?? event.message;
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
              onPressed: _isWorking ? null : _loadSupport,
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
                      onStartObjectCapture: _startGuidedObjectCapture,
                      onStartLiDARCapture: _startLiDARCapture,
                      onStartRoomPlanCapture: _startRoomPlanCapture,
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
