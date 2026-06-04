import 'package:apple_spatial_capture/apple_spatial_capture.dart';
import 'package:flutter/material.dart';

import '../widgets/photogrammetry_options_form.dart';
import '../widgets/section_card.dart';
import '../widgets/tab_list.dart';

class PhotosTab extends StatelessWidget {
  const PhotosTab({
    super.key,
    required this.isWorking,
    required this.outputFormat,
    required this.textureQuality,
    required this.sampleOrdering,
    required this.featureSensitivity,
    required this.useObjectMasking,
    required this.progressLog,
    required this.onOutputFormatChanged,
    required this.onTextureQualityChanged,
    required this.onSampleOrderingChanged,
    required this.onFeatureSensitivityChanged,
    required this.onUseObjectMaskingChanged,
    required this.onStartPhotoReconstruction,
  });

  final bool isWorking;
  final ApplePhotogrammetryOutputFormat outputFormat;
  final ApplePhotogrammetryTextureQuality textureQuality;
  final ApplePhotogrammetrySampleOrdering sampleOrdering;
  final ApplePhotogrammetryFeatureSensitivity featureSensitivity;
  final bool useObjectMasking;
  final List<String> progressLog;
  final ValueChanged<ApplePhotogrammetryOutputFormat> onOutputFormatChanged;
  final ValueChanged<ApplePhotogrammetryTextureQuality> onTextureQualityChanged;
  final ValueChanged<ApplePhotogrammetrySampleOrdering> onSampleOrderingChanged;
  final ValueChanged<ApplePhotogrammetryFeatureSensitivity>
      onFeatureSensitivityChanged;
  final ValueChanged<bool> onUseObjectMaskingChanged;
  final VoidCallback onStartPhotoReconstruction;

  @override
  Widget build(BuildContext context) {
    return TabList(
      children: [
        SectionCard(
          title: 'Photo reconstruction',
          subtitle: 'Pick at least 3 photos and generate a model.',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              PhotogrammetryOptionsForm(
                outputFormat: outputFormat,
                textureQuality: textureQuality,
                sampleOrdering: sampleOrdering,
                featureSensitivity: featureSensitivity,
                useObjectMasking: useObjectMasking,
                onOutputFormatChanged: onOutputFormatChanged,
                onTextureQualityChanged: onTextureQualityChanged,
                onSampleOrderingChanged: onSampleOrderingChanged,
                onFeatureSensitivityChanged: onFeatureSensitivityChanged,
                onUseObjectMaskingChanged: onUseObjectMaskingChanged,
              ),
              const SizedBox(height: 12),
              FilledButton.icon(
                onPressed: isWorking ? null : onStartPhotoReconstruction,
                icon: const Icon(Icons.photo_library_rounded),
                label: const Text('Select photos and generate'),
              ),
            ],
          ),
        ),
        SectionCard(
          title: 'Progress log',
          subtitle: progressLog.isEmpty
              ? 'Progress events appear here during photo reconstruction.'
              : 'Latest event first.',
          child: progressLog.isEmpty
              ? const Text('No progress events yet.')
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (final entry in progressLog)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Text(entry),
                      ),
                  ],
                ),
        ),
      ],
    );
  }
}
