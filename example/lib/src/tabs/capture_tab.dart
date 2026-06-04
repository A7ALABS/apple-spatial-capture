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
    required this.lastModelPath,
    required this.onStartObjectCapture,
    required this.onStartLiDARCapture,
    required this.onStartRoomPlanCapture,
    required this.onPreviewLastModel,
  });

  final AppleSpatialCaptureSupport? support;
  final bool isWorking;
  final String? lastModelPath;
  final VoidCallback onStartObjectCapture;
  final VoidCallback onStartLiDARCapture;
  final VoidCallback onStartRoomPlanCapture;
  final VoidCallback onPreviewLastModel;

  @override
  Widget build(BuildContext context) {
    return TabList(
      children: [
        SectionCard(
          title: 'Device support',
          subtitle: Platform.isIOS
              ? 'Runtime checks for this iOS device.'
              : 'Run on a physical iOS device to use capture APIs.',
          child: Column(
            children: [
              SupportTile(
                label: 'Object Capture',
                minimum: 'iOS 17+',
                isSupported: support?.photogrammetry,
              ),
              SupportTile(
                label: 'LiDAR mesh',
                minimum: 'iOS 14+',
                isSupported: support?.lidar,
              ),
              SupportTile(
                label: 'RoomPlan',
                minimum: 'iOS 16+',
                isSupported: support?.roomPlan,
              ),
            ],
          ),
        ),
        SectionCard(
          title: 'Capture from device',
          subtitle: 'Start a native full-screen capture flow.',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              ActionButton(
                icon: Icons.view_in_ar_rounded,
                label: 'Object Capture',
                description: 'Guided object scan and USDZ reconstruction.',
                onPressed: isWorking ? null : onStartObjectCapture,
              ),
              const SizedBox(height: 10),
              ActionButton(
                icon: Icons.polyline_rounded,
                label: 'LiDAR mesh',
                description: 'Fast mesh scan from the LiDAR sensor.',
                onPressed: isWorking ? null : onStartLiDARCapture,
              ),
              const SizedBox(height: 10),
              ActionButton(
                icon: Icons.meeting_room_rounded,
                label: 'RoomPlan',
                description: 'Room-scale capture using Apple RoomPlan.',
                onPressed: isWorking ? null : onStartRoomPlanCapture,
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
