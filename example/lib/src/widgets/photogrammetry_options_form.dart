import 'package:apple_spatial_capture/apple_spatial_capture.dart';
import 'package:flutter/material.dart';

class PhotogrammetryOptionsForm extends StatelessWidget {
  const PhotogrammetryOptionsForm({
    super.key,
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
