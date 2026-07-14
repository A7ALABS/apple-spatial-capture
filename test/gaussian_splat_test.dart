import 'dart:typed_data';

import 'package:apple_spatial_capture/apple_spatial_capture.dart';
import 'package:flutter_test/flutter_test.dart';

/// Records calls and returns canned values so the facade's delegation and the
/// viewport handle's guard logic can be verified without a device.
class _FakePlatform implements AppleSpatialCapturePlatform {
  final List<String> calls = <String>[];
  int splatCountToReturn = 1000;

  @override
  Future<AppleSplatViewportSession> openSplatViewport({
    required String datasetPath,
  }) async {
    calls.add('openSplatViewport:$datasetPath');
    return AppleSplatViewportSession(
      sessionId: 7,
      splatCount: splatCountToReturn,
      orbitRadius: 2.5,
    );
  }

  @override
  Future<AppleSplatViewportSession> openSplatPlyViewport({
    required String plyPath,
  }) async {
    calls.add('openSplatPlyViewport:$plyPath');
    return AppleSplatViewportSession(
      sessionId: 9,
      splatCount: splatCountToReturn,
      orbitRadius: 1.0,
    );
  }

  @override
  Future<Uint8List?> renderSplatViewport({
    required int sessionId,
    double azimuth = 0,
    double elevation = 0.35,
    double distanceScale = 1,
  }) async {
    calls.add('render:$sessionId:$azimuth:$elevation:$distanceScale');
    return Uint8List.fromList(const [1, 2, 3]);
  }

  @override
  Future<int> cropSplatViewport({
    required int sessionId,
    double keepFraction = 0.85,
  }) async {
    calls.add('crop:$sessionId:$keepFraction');
    return 640;
  }

  @override
  Future<int> cleanupSplatViewport({
    required int sessionId,
    double minOpacity = 0,
    double maxWorldScale = 0,
  }) async {
    calls.add('cleanup:$sessionId:$minOpacity:$maxWorldScale');
    return 512;
  }

  @override
  Future<void> saveSplatViewportEdits({
    required int sessionId,
    required String datasetPath,
  }) async {
    calls.add('saveEdits:$sessionId:$datasetPath');
  }

  @override
  Future<void> closeSplatViewport({required int sessionId}) async {
    calls.add('close:$sessionId');
  }

  @override
  Future<void> snapshotSplatViewport({
    required int sessionId,
    required String path,
  }) async {
    calls.add('snapshot:$sessionId:$path');
  }

  @override
  Future<int> restoreSplatViewport({
    required int sessionId,
    required String path,
  }) async {
    calls.add('restore:$sessionId:$path');
    return splatCountToReturn;
  }

  // Unused by these tests.
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError(invocation.memberName.toString());
}

void main() {
  late _FakePlatform fake;

  setUp(() {
    fake = _FakePlatform();
    AppleSpatialCapture.setPlatform(fake);
  });

  group('GaussianSplatApi viewport handle', () {
    test(
      'openViewport yields an editable session and delegates render',
      () async {
        final viewport = await AppleSpatialCapture.gaussianSplat.openViewport(
          '/data/gs_1',
        );

        expect(viewport.editable, isTrue);
        expect(viewport.datasetPath, '/data/gs_1');
        expect(viewport.sessionId, 7);
        expect(viewport.orbitRadius, 2.5);
        expect(viewport.splatCount, 1000);

        final frame = await viewport.renderFrame(azimuth: 1.2);
        expect(frame, isNotNull);
        expect(fake.calls, contains('render:7:1.2:0.35:1.0'));
      },
    );

    test('edits update the cached splat count', () async {
      final viewport = await AppleSpatialCapture.gaussianSplat.openViewport(
        '/data/gs_1',
      );

      final afterCrop = await viewport.crop(keepFraction: 0.7);
      expect(afterCrop, 640);
      expect(viewport.splatCount, 640);

      final afterCleanup = await viewport.cleanup(minOpacity: 0.05);
      expect(afterCleanup, 512);
      expect(viewport.splatCount, 512);
    });

    test('saveEdits uses the stored dataset path', () async {
      final viewport = await AppleSpatialCapture.gaussianSplat.openViewport(
        '/data/gs_1',
      );
      await viewport.saveEdits();
      expect(fake.calls, contains('saveEdits:7:/data/gs_1'));
    });

    test('ply viewport is view-only and rejects edits', () async {
      final viewport = await AppleSpatialCapture.gaussianSplat.openPlyViewport(
        '/tmp/cloud.ply',
      );

      expect(viewport.editable, isFalse);
      expect(viewport.datasetPath, isNull);
      // Rendering still works.
      expect(await viewport.renderFrame(), isNotNull);
      // Editing throws a typed error instead of hitting the native layer.
      expect(
        () => viewport.crop(),
        throwsA(
          isA<AppleSpatialCaptureError>().having(
            (e) => e.code,
            'code',
            'NOT_EDITABLE',
          ),
        ),
      );
      expect(
        () => viewport.saveEdits(),
        throwsA(isA<AppleSpatialCaptureError>()),
      );
    });

    test('close is idempotent and blocks further calls', () async {
      final viewport = await AppleSpatialCapture.gaussianSplat.openViewport(
        '/data/gs_1',
      );

      await viewport.close();
      await viewport.close(); // no-op second time
      expect(viewport.isClosed, isTrue);
      expect(fake.calls.where((c) => c.startsWith('close:')).length, 1);
      expect(
        () => viewport.renderFrame(),
        throwsA(
          isA<AppleSpatialCaptureError>().having(
            (e) => e.code,
            'code',
            'INVALID_SESSION',
          ),
        ),
      );
    });
  });
}
