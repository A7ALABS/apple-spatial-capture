import 'package:apple_spatial_capture/apple_spatial_capture.dart';
import 'package:flutter/material.dart';

import '../widgets/section_card.dart';
import '../widgets/tab_list.dart';

class PreviewTab extends StatelessWidget {
  const PreviewTab({
    super.key,
    required this.isWorking,
    required this.localPathController,
    required this.remoteUrlController,
    required this.remoteFileNameController,
    required this.remoteFileType,
    required this.onRemoteFileTypeChanged,
    required this.onPreviewLocalModel,
    required this.onPreviewRemoteModel,
  });

  final bool isWorking;
  final TextEditingController localPathController;
  final TextEditingController remoteUrlController;
  final TextEditingController remoteFileNameController;
  final AppleSpatialCaptureFileType remoteFileType;
  final ValueChanged<AppleSpatialCaptureFileType> onRemoteFileTypeChanged;
  final VoidCallback onPreviewLocalModel;
  final VoidCallback onPreviewRemoteModel;

  @override
  Widget build(BuildContext context) {
    return TabList(
      children: [
        SectionCard(
          title: 'Local model',
          subtitle: 'Preview the last capture or paste a model path.',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                controller: localPathController,
                decoration: const InputDecoration(
                  labelText: 'Local model path',
                  hintText: '/var/mobile/.../model.usdz',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 10),
              OutlinedButton.icon(
                onPressed: isWorking ? null : onPreviewLocalModel,
                icon: const Icon(Icons.open_in_new_rounded),
                label: const Text('Preview local model'),
              ),
            ],
          ),
        ),
        SectionCard(
          title: 'Remote model',
          subtitle: 'Download and preview an http or https model URL.',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                controller: remoteUrlController,
                keyboardType: TextInputType.url,
                decoration: const InputDecoration(
                  labelText: 'Remote model URL',
                  hintText: 'https://example.com/model.usdz',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: remoteFileNameController,
                decoration: const InputDecoration(
                  labelText: 'Optional file name',
                  hintText: 'model.usdz',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 10),
              DropdownButtonFormField<AppleSpatialCaptureFileType>(
                value: remoteFileType,
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
                onChanged: isWorking
                    ? null
                    : (value) {
                        if (value != null) onRemoteFileTypeChanged(value);
                      },
              ),
              const SizedBox(height: 10),
              OutlinedButton.icon(
                onPressed: isWorking ? null : onPreviewRemoteModel,
                icon: const Icon(Icons.cloud_download_rounded),
                label: const Text('Preview remote model'),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
