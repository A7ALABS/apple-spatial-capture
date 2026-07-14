import 'dart:io';

import 'package:apple_spatial_capture/apple_spatial_capture.dart';
import 'package:flutter/material.dart';

import '../widgets/action_button.dart';
import '../widgets/section_card.dart';
import '../widgets/support_tile.dart';
import '../widgets/tab_list.dart';

class CaptureTab extends StatelessWidget {
  const CaptureTab({
    super.key,
    required this.support,
    required this.isWorking,
    required this.supportsDeviceCapture,
    required this.lastModelPath,
    required this.lastDatasetSummary,
    required this.splatDatasetFormat,
    required this.onSplatDatasetFormatChanged,
    required this.trainDatasetPathController,
    required this.availableDatasetPaths,
    required this.onDatasetSelected,
    required this.trainingIterations,
    required this.onTrainingIterationsChanged,
    required this.onTrainGaussianSplat,
    required this.onPreviewSplat,
    required this.lastTrainingSummary,
    required this.onStartObjectCapture,
    required this.onStartLiDARCapture,
    required this.onStartRoomPlanCapture,
    required this.onStartGaussianSplatCapture,
    required this.onShareDataset,
    required this.onPreviewLastModel,
  });

  final AppleSpatialCaptureSupport? support;
  final bool isWorking;
  final bool supportsDeviceCapture;
  final String? lastModelPath;
  final String? lastDatasetSummary;
  final AppleGaussianSplatDatasetFormat splatDatasetFormat;
  final ValueChanged<AppleGaussianSplatDatasetFormat>
  onSplatDatasetFormatChanged;
  final TextEditingController trainDatasetPathController;
  final List<String> availableDatasetPaths;
  final ValueChanged<String> onDatasetSelected;
  final int trainingIterations;
  final ValueChanged<int> onTrainingIterationsChanged;
  final VoidCallback onTrainGaussianSplat;
  final VoidCallback onPreviewSplat;
  final String? lastTrainingSummary;
  final VoidCallback onStartObjectCapture;
  final VoidCallback onStartLiDARCapture;
  final VoidCallback onStartRoomPlanCapture;
  final VoidCallback onStartGaussianSplatCapture;
  final VoidCallback? onShareDataset;
  final VoidCallback onPreviewLastModel;

  @override
  Widget build(BuildContext context) {
    return TabList(
      children: [
        SectionCard(
          title: 'Device support',
          subtitle: Platform.isIOS || Platform.isMacOS
              ? 'Runtime checks for this Apple device.'
              : 'Run on iOS, iPadOS, or macOS to use capture APIs.',
          child: Column(
            children: [
              SupportTile(
                label: 'Photogrammetry',
                minimum: 'iOS/iPadOS 17+ or macOS 12+',
                isSupported: support?.photogrammetry,
              ),
              SupportTile(
                label: 'LiDAR mesh',
                minimum: 'iOS/iPadOS 14+',
                isSupported: support?.lidar,
              ),
              SupportTile(
                label: 'RoomPlan',
                minimum: 'iOS/iPadOS 16+',
                isSupported: support?.roomPlan,
              ),
              SupportTile(
                label: 'Gaussian splat dataset',
                minimum: 'iOS/iPadOS 14+',
                isSupported: support?.gaussianSplat,
              ),
              SupportTile(
                label: 'Splat training (msplat)',
                minimum: 'macOS 14+ / iOS 16+ (experimental)',
                isSupported: support?.gaussianSplatTraining,
              ),
            ],
          ),
        ),
        SectionCard(
          title: 'Capture from device',
          subtitle: supportsDeviceCapture
              ? 'Start a native full-screen capture flow.'
              : 'Device capture is available on supported iPhone and iPad devices.',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              ActionButton(
                icon: Icons.view_in_ar_rounded,
                label: 'Object Capture',
                description: 'Guided object scan and USDZ reconstruction.',
                onPressed: isWorking || !supportsDeviceCapture
                    ? null
                    : onStartObjectCapture,
              ),
              const SizedBox(height: 10),
              ActionButton(
                icon: Icons.polyline_rounded,
                label: 'LiDAR mesh',
                description: 'Fast mesh scan from the LiDAR sensor.',
                onPressed: isWorking || !supportsDeviceCapture
                    ? null
                    : onStartLiDARCapture,
              ),
              const SizedBox(height: 10),
              ActionButton(
                icon: Icons.meeting_room_rounded,
                label: 'RoomPlan',
                description: 'Room-scale capture using Apple RoomPlan.',
                onPressed: isWorking || !supportsDeviceCapture
                    ? null
                    : onStartRoomPlanCapture,
              ),
              const SizedBox(height: 10),
              ActionButton(
                icon: Icons.grain_rounded,
                label: 'Gaussian splat dataset',
                description:
                    'Auto-capture photos + camera poses for splat training.',
                onPressed: isWorking || !supportsDeviceCapture
                    ? null
                    : onStartGaussianSplatCapture,
              ),
              const SizedBox(height: 10),
              DropdownButtonFormField<AppleGaussianSplatDatasetFormat>(
                initialValue: splatDatasetFormat,
                decoration: const InputDecoration(
                  labelText: 'Splat dataset format',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
                items: const [
                  DropdownMenuItem(
                    value: AppleGaussianSplatDatasetFormat.nerfstudio,
                    child: Text('nerfstudio (gsplat, Brush)'),
                  ),
                  DropdownMenuItem(
                    value: AppleGaussianSplatDatasetFormat.colmap,
                    child: Text('COLMAP (LichtFeld Studio)'),
                  ),
                  DropdownMenuItem(
                    value: AppleGaussianSplatDatasetFormat.both,
                    child: Text('Both layouts'),
                  ),
                ],
                onChanged: isWorking
                    ? null
                    : (value) {
                        if (value != null) {
                          onSplatDatasetFormatChanged(value);
                        }
                      },
              ),
            ],
          ),
        ),
        if (support?.gaussianSplatTraining == true)
          SectionCard(
            title: 'Train Gaussian splat on-device',
            subtitle:
                'Runs the bundled msplat Metal engine on a captured dataset '
                '(needs the nerfstudio transforms.json layout).',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (availableDatasetPaths.isNotEmpty) ...[
                  InputDecorator(
                    decoration: const InputDecoration(
                      labelText: 'Captured datasets',
                      border: OutlineInputBorder(),
                      isDense: true,
                      contentPadding: EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 4,
                      ),
                    ),
                    child: DropdownButtonHideUnderline(
                      child: DropdownButton<String>(
                        value:
                            availableDatasetPaths.contains(
                              trainDatasetPathController.text,
                            )
                            ? trainDatasetPathController.text
                            : null,
                        isExpanded: true,
                        hint: const Text('Select a captured dataset'),
                        items: [
                          for (final path in availableDatasetPaths)
                            DropdownMenuItem(
                              value: path,
                              child: Text(
                                path.split('/').last,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                        ],
                        onChanged: isWorking
                            ? null
                            : (value) {
                                if (value != null) {
                                  onDatasetSelected(value);
                                }
                              },
                      ),
                    ),
                  ),
                  const SizedBox(height: 10),
                ],
                TextField(
                  controller: trainDatasetPathController,
                  decoration: const InputDecoration(
                    labelText: 'Dataset folder path',
                    hintText: '/…/GaussianSplatDatasets/gs_20260712_120000',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
                const SizedBox(height: 10),
                DropdownButtonFormField<int>(
                  initialValue: trainingIterations,
                  decoration: const InputDecoration(
                    labelText: 'Iterations',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                  items: const [
                    DropdownMenuItem(
                      value: 1000,
                      child: Text('1000 — fast preview'),
                    ),
                    DropdownMenuItem(
                      value: 3000,
                      child: Text('3000 — balanced'),
                    ),
                    DropdownMenuItem(
                      value: 7000,
                      child: Text('7000 — high quality'),
                    ),
                  ],
                  onChanged: isWorking
                      ? null
                      : (value) {
                          if (value != null) {
                            onTrainingIterationsChanged(value);
                          }
                        },
                ),
                const SizedBox(height: 10),
                FilledButton.icon(
                  onPressed: isWorking ? null : onTrainGaussianSplat,
                  icon: const Icon(Icons.auto_awesome_rounded),
                  label: const Text('Train splat'),
                ),
                const SizedBox(height: 10),
                OutlinedButton.icon(
                  onPressed: isWorking ? null : onPreviewSplat,
                  icon: const Icon(Icons.threed_rotation_rounded),
                  label: const Text('Preview trained splat'),
                ),
                if (lastTrainingSummary != null) ...[
                  const SizedBox(height: 10),
                  Text(
                    lastTrainingSummary!,
                    style: const TextStyle(fontSize: 12),
                  ),
                ],
              ],
            ),
          ),
        if (lastDatasetSummary != null)
          SectionCard(
            title: 'Last captured dataset',
            subtitle: lastDatasetSummary!,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text(
                  'Train with nerfstudio/gsplat, Brush, or LichtFeld Studio.',
                  style: TextStyle(fontSize: 12),
                ),
                const SizedBox(height: 10),
                OutlinedButton.icon(
                  onPressed: isWorking ? null : onShareDataset,
                  icon: const Icon(Icons.ios_share_rounded),
                  label: const Text('Share dataset (AirDrop, Files…)'),
                ),
              ],
            ),
          ),
        if (lastModelPath != null)
          SectionCard(
            title: 'Last generated model',
            subtitle: lastModelPath!,
            child: OutlinedButton.icon(
              onPressed: isWorking ? null : onPreviewLastModel,
              icon: const Icon(Icons.open_in_new_rounded),
              label: const Text('Preview last model'),
            ),
          ),
      ],
    );
  }
}
