import 'package:flutter/material.dart';

import 'spatial_capture_example_screen.dart';

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
