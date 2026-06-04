import 'dart:async';
import 'dart:io';

import 'package:apple_spatial_capture/apple_spatial_capture.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

void main() {
  runApp(const AppleSpatialCaptureExampleApp());
}

class AppleSpatialCaptureExampleApp extends StatelessWidget {
  const AppleSpatialCaptureExampleApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Apple Spatial Capture',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF2563EB),
          brightness: Brightness.dark,
        ),
        scaffoldBackgroundColor: const Color(0xFF0B1220),
        useMaterial3: true,
      ),
      home: const SpatialCaptureExampleScreen(),
    );
  }
}

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
    if (!Platform.isIOS) {
      setState(() {
        _isCheckingSupport = false;
        _statusMessage = 'This plugin only runs on iOS devices.';
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
    if (!_ensureSupported(_support?.photogrammetry, 'Object Capture')) return;

    await _runModelCapture(
      statusMessage: 'Opening Object Capture...',
      startCapture: AppleSpatialCapture.platform.startPhotogrammetryCapture,
    );
  }

  Future<void> _startLiDARCapture() async {
    if (!_ensureSupported(_support?.lidar, 'LiDAR scanning')) return;

    await _runModelCapture(
      statusMessage: 'Opening LiDAR scanner...',
      startCapture: AppleSpatialCapture.platform.startLiDARCapture,
    );
  }

  Future<void> _startRoomPlanCapture() async {
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
      final path = await AppleSpatialCapture.platform.startPhotogrammetryFromImages(
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
      });

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
    if (!Platform.isIOS) {
      _setError('$featureName requires a physical iOS device.');
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

  @override
  Widget build(BuildContext context) {
    final support = _support;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Apple Spatial Capture'),
        actions: [
          IconButton(
            tooltip: 'Refresh support',
            onPressed: _isWorking ? null : _loadSupport,
            icon: const Icon(Icons.refresh_rounded),
          ),
        ],
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            _StatusBanner(
              isWorking: _isWorking || _isCheckingSupport,
              message: _statusMessage,
              errorMessage: _errorMessage,
              progress: _progress,
            ),
            const SizedBox(height: 16),
            _SectionCard(
              title: 'Device support',
              subtitle: Platform.isIOS
                  ? 'Runtime checks for this iOS device.'
                  : 'Run on a physical iOS device to use capture APIs.',
              child: Column(
                children: [
                  _SupportTile(
                    label: 'Object Capture',
                    minimum: 'iOS 17+',
                    isSupported: support?.photogrammetry,
                  ),
                  _SupportTile(
                    label: 'LiDAR mesh',
                    minimum: 'iOS 14+',
                    isSupported: support?.lidar,
                  ),
                  _SupportTile(
                    label: 'RoomPlan',
                    minimum: 'iOS 16+',
                    isSupported: support?.roomPlan,
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            _SectionCard(
              title: 'Capture',
              subtitle: 'Each action presents native iOS capture UI.',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  FilledButton.icon(
                    onPressed: _isWorking ? null : _startGuidedObjectCapture,
                    icon: const Icon(Icons.view_in_ar_rounded),
                    label: const Text('Start Object Capture'),
                  ),
                  const SizedBox(height: 10),
                  FilledButton.tonalIcon(
                    onPressed: _isWorking ? null : _startLiDARCapture,
                    icon: const Icon(Icons.polyline_rounded),
                    label: const Text('Start LiDAR Scan'),
                  ),
                  const SizedBox(height: 10),
                  FilledButton.tonalIcon(
                    onPressed: _isWorking ? null : _startRoomPlanCapture,
                    icon: const Icon(Icons.meeting_room_rounded),
                    label: const Text('Start RoomPlan Scan'),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            _SectionCard(
              title: 'Photos to 3D model',
              subtitle: 'Pick at least 3 photos and monitor reconstruction.',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _PhotogrammetryOptionsForm(
                    outputFormat: _photoOutputFormat,
                    textureQuality: _photoTextureQuality,
                    sampleOrdering: _photoSampleOrdering,
                    featureSensitivity: _photoFeatureSensitivity,
                    useObjectMasking: _useObjectMasking,
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
                  ),
                  const SizedBox(height: 12),
                  FilledButton.icon(
                    onPressed: _isWorking ? null : _startPhotoReconstruction,
                    icon: const Icon(Icons.photo_library_rounded),
                    label: const Text('Generate from photos'),
                  ),
                  if (_progressLog.isNotEmpty) ...[
                    const SizedBox(height: 12),
                    for (final entry in _progressLog)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 6),
                        child: Text(
                          entry,
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 16),
            _SectionCard(
              title: 'Preview local model',
              subtitle: 'Preview the last capture or paste a local model path.',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  TextField(
                    controller: _localPathController,
                    decoration: const InputDecoration(
                      labelText: 'Local model path',
                      hintText: '/var/mobile/.../model.usdz',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 10),
                  OutlinedButton.icon(
                    onPressed: _isWorking ? null : _previewLastModel,
                    icon: const Icon(Icons.open_in_new_rounded),
                    label: const Text('Preview local model'),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            _SectionCard(
              title: 'Preview remote model',
              subtitle: 'Download and preview an http or https model URL.',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  TextField(
                    controller: _remoteUrlController,
                    keyboardType: TextInputType.url,
                    decoration: const InputDecoration(
                      labelText: 'Remote model URL',
                      hintText: 'https://example.com/model.usdz',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: _remoteFileNameController,
                    decoration: const InputDecoration(
                      labelText: 'Optional file name',
                      hintText: 'model.usdz',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 10),
                  DropdownButtonFormField<AppleSpatialCaptureFileType>(
                    value: _remoteFileType,
                    decoration: const InputDecoration(
                      labelText: 'File type',
                      border: OutlineInputBorder(),
                    ),
                    items: AppleSpatialCaptureFileType.values
                        .map(
                          (type) => DropdownMenuItem(
                            value: type,
                            child: Text(type.value.toUpperCase()),
                          ),
                        )
                        .toList(),
                    onChanged: _isWorking
                        ? null
                        : (value) {
                            if (value != null) {
                              setState(() => _remoteFileType = value);
                            }
                          },
                  ),
                  const SizedBox(height: 10),
                  OutlinedButton.icon(
                    onPressed: _isWorking ? null : _previewRemoteModel,
                    icon: const Icon(Icons.cloud_download_rounded),
                    label: const Text('Preview remote model'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _StatusBanner extends StatelessWidget {
  const _StatusBanner({
    required this.isWorking,
    required this.message,
    required this.errorMessage,
    required this.progress,
  });

  final bool isWorking;
  final String message;
  final String? errorMessage;
  final double? progress;

  @override
  Widget build(BuildContext context) {
    final hasError = errorMessage != null;
    final colorScheme = Theme.of(context).colorScheme;

    return DecoratedBox(
      decoration: BoxDecoration(
        color: hasError
            ? colorScheme.errorContainer
            : colorScheme.primaryContainer.withValues(alpha: 0.35),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                if (isWorking)
                  const SizedBox.square(
                    dimension: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                else
                  Icon(
                    hasError
                        ? Icons.error_outline_rounded
                        : Icons.check_circle_outline_rounded,
                  ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    message,
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                  ),
                ),
              ],
            ),
            if (progress != null) ...[
              const SizedBox(height: 12),
              LinearProgressIndicator(value: progress),
            ],
          ],
        ),
      ),
    );
  }
}

class _SectionCard extends StatelessWidget {
  const _SectionCard({
    required this.title,
    required this.subtitle,
    required this.child,
  });

  final String title;
  final String subtitle;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: 0,
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 4),
            Text(subtitle, style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: 14),
            child,
          ],
        ),
      ),
    );
  }
}

class _SupportTile extends StatelessWidget {
  const _SupportTile({
    required this.label,
    required this.minimum,
    required this.isSupported,
  });

  final String label;
  final String minimum;
  final bool? isSupported;

  @override
  Widget build(BuildContext context) {
    final supported = isSupported == true;
    final unknown = isSupported == null;

    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Icon(
        unknown
            ? Icons.help_outline_rounded
            : supported
                ? Icons.check_circle_outline_rounded
                : Icons.highlight_off_rounded,
        color: unknown
            ? null
            : supported
                ? Colors.greenAccent
                : Theme.of(context).colorScheme.error,
      ),
      title: Text(label),
      subtitle: Text(minimum),
      trailing: Text(
        unknown
            ? 'Unknown'
            : supported
                ? 'Available'
                : 'Unavailable',
      ),
    );
  }
}

class _PhotogrammetryOptionsForm extends StatelessWidget {
  const _PhotogrammetryOptionsForm({
    required this.outputFormat,
    required this.textureQuality,
    required this.sampleOrdering,
    required this.featureSensitivity,
    required this.useObjectMasking,
    required this.onOutputFormatChanged,
    required this.onTextureQualityChanged,
    required this.onSampleOrderingChanged,
    required this.onFeatureSensitivityChanged,
    required this.onUseObjectMaskingChanged,
  });

  final ApplePhotogrammetryOutputFormat outputFormat;
  final ApplePhotogrammetryTextureQuality textureQuality;
  final ApplePhotogrammetrySampleOrdering sampleOrdering;
  final ApplePhotogrammetryFeatureSensitivity featureSensitivity;
  final bool useObjectMasking;
  final ValueChanged<ApplePhotogrammetryOutputFormat> onOutputFormatChanged;
  final ValueChanged<ApplePhotogrammetryTextureQuality> onTextureQualityChanged;
  final ValueChanged<ApplePhotogrammetrySampleOrdering> onSampleOrderingChanged;
  final ValueChanged<ApplePhotogrammetryFeatureSensitivity>
      onFeatureSensitivityChanged;
  final ValueChanged<bool> onUseObjectMaskingChanged;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        DropdownButtonFormField<ApplePhotogrammetryOutputFormat>(
          value: outputFormat,
          decoration: const InputDecoration(
            labelText: 'Output format',
            border: OutlineInputBorder(),
          ),
          items: ApplePhotogrammetryOutputFormat.values
              .map(
                (value) => DropdownMenuItem(
                  value: value,
                  child: Text(value.value.toUpperCase()),
                ),
              )
              .toList(),
          onChanged: (value) {
            if (value != null) onOutputFormatChanged(value);
          },
        ),
        const SizedBox(height: 10),
        DropdownButtonFormField<ApplePhotogrammetryTextureQuality>(
          value: textureQuality,
          decoration: const InputDecoration(
            labelText: 'Texture quality',
            border: OutlineInputBorder(),
          ),
          items: ApplePhotogrammetryTextureQuality.values
              .map(
                (value) => DropdownMenuItem(
                  value: value,
                  child: Text(value.name),
                ),
              )
              .toList(),
          onChanged: (value) {
            if (value != null) onTextureQualityChanged(value);
          },
        ),
        const SizedBox(height: 10),
        DropdownButtonFormField<ApplePhotogrammetrySampleOrdering>(
          value: sampleOrdering,
          decoration: const InputDecoration(
            labelText: 'Sample ordering',
            border: OutlineInputBorder(),
          ),
          items: ApplePhotogrammetrySampleOrdering.values
              .map(
                (value) => DropdownMenuItem(
                  value: value,
                  child: Text(value.name),
                ),
              )
              .toList(),
          onChanged: (value) {
            if (value != null) onSampleOrderingChanged(value);
          },
        ),
        const SizedBox(height: 10),
        DropdownButtonFormField<ApplePhotogrammetryFeatureSensitivity>(
          value: featureSensitivity,
          decoration: const InputDecoration(
            labelText: 'Feature sensitivity',
            border: OutlineInputBorder(),
          ),
          items: ApplePhotogrammetryFeatureSensitivity.values
              .map(
                (value) => DropdownMenuItem(
                  value: value,
                  child: Text(value.name),
                ),
              )
              .toList(),
          onChanged: (value) {
            if (value != null) onFeatureSensitivityChanged(value);
          },
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Object masking'),
          subtitle: const Text('Use masking during image reconstruction.'),
          value: useObjectMasking,
          onChanged: onUseObjectMaskingChanged,
        ),
      ],
    );
  }
}
