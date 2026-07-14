import SwiftUI
import ARKit
import SceneKit
import CoreImage
import ImageIO
import UniformTypeIdentifiers

/// On-disk layout(s) written for a captured dataset.
enum GaussianSplatDatasetFormat: String {
    /// nerfstudio-style `transforms.json` (+ `sparse_pc.ply`) — consumed by
    /// nerfstudio/gsplat, Brush, and most `transforms.json` trainers.
    case nerfstudio
    /// COLMAP text model (`sparse/0/cameras.txt`, `images.txt`,
    /// `points3D.txt`) — consumed by LichtFeld Studio and the original
    /// 3DGS reference implementation.
    case colmap
    /// Write both layouts side by side in the same dataset folder.
    case both

    var includesNerfstudio: Bool { self != .colmap }
    var includesColmap: Bool { self != .nerfstudio }
}

/// Options controlling Gaussian-splat dataset capture, parsed from the
/// method-channel payload.
struct GaussianSplatCaptureOptions {
    var maxImages: Int = 250
    var translationThresholdMeters: Float = 0.08
    var rotationThresholdDegrees: Float = 10
    var includeDepthMaps: Bool = false
    var jpegQuality: Double = 0.85
    var format: GaussianSplatDatasetFormat = .nerfstudio
    /// Lock auto-exposure (ISO + shutter) and white balance once recording
    /// starts, so all frames share consistent color and brightness (iOS 16+).
    var lockCameraSettings: Bool = true
    /// Also lock focus when camera settings are locked. Off by default so
    /// close-up passes stay sharp.
    var lockFocus: Bool = false

    static func parse(from raw: [String: Any]?) -> GaussianSplatCaptureOptions {
        var options = GaussianSplatCaptureOptions()
        guard let raw else { return options }
        if let value = raw["format"] as? String,
           let format = GaussianSplatDatasetFormat(rawValue: value) {
            options.format = format
        }
        if let value = raw["lockCameraSettings"] as? Bool {
            options.lockCameraSettings = value
        }
        if let value = raw["lockFocus"] as? Bool {
            options.lockFocus = value
        }
        if let value = raw["maxImages"] as? NSNumber {
            options.maxImages = max(10, min(1000, value.intValue))
        }
        if let value = raw["translationThresholdMeters"] as? NSNumber {
            options.translationThresholdMeters = max(0.01, min(1.0, value.floatValue))
        }
        if let value = raw["rotationThresholdDegrees"] as? NSNumber {
            options.rotationThresholdDegrees = max(1.0, min(90.0, value.floatValue))
        }
        if let value = raw["includeDepthMaps"] as? Bool {
            options.includeDepthMaps = value
        }
        if let value = raw["jpegQuality"] as? NSNumber {
            options.jpegQuality = max(0.3, min(1.0, value.doubleValue))
        }
        return options
    }
}

/// Full-screen Gaussian-splat dataset capture view, in the style of mobile
/// splat scanners (Scaniverse, RealityScan): photos are captured automatically
/// as the user moves, with live tracking guidance and pose markers.
///
/// Produces a training-ready dataset folder (`images/`, `transforms.json` in
/// nerfstudio format, `sparse_pc.ply` seed point cloud, optional `depth/`)
/// and returns a summary payload via `completion`, or nil on cancel.
@available(iOS 14.0, *)
struct GaussianSplatCaptureView: View {
    let options: GaussianSplatCaptureOptions
    let completion: ([String: Any]?) -> Void

    @StateObject private var coordinator = GaussianSplatCoordinator()
    @State private var isExporting = false
    @State private var errorMessage: String?

    private static let minImagesToFinish = 10

    var body: some View {
        ZStack {
            GaussianSplatARViewRepresentable(coordinator: coordinator, options: options)
                .ignoresSafeArea()

            if isExporting {
                exportingOverlay
            } else {
                controls
            }
        }
        .onDisappear { coordinator.stopSession() }
    }

    // MARK: - Subviews

    private var exportingOverlay: some View {
        ZStack {
            Color.black.opacity(0.75).ignoresSafeArea()
            VStack(spacing: 20) {
                ProgressView()
                    .progressViewStyle(CircularProgressViewStyle(tint: .white))
                    .scaleEffect(1.5)
                Text("Saving dataset…")
                    .font(.headline).foregroundColor(.white)
                Text("Writing images, camera poses and point cloud")
                    .font(.subheadline).foregroundColor(.white.opacity(0.65))
            }
        }
    }

    private var controls: some View {
        VStack(spacing: 0) {
            topBar
            statusArea
            Spacer()
            bottomBar
        }
    }

    private var topBar: some View {
        HStack {
            Button(action: cancel) {
                Image(systemName: "xmark")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(width: 36, height: 36)
                    .background(Color.black.opacity(0.55))
                    .clipShape(Circle())
            }
            .padding(.leading, 20)
            Spacer()
        }
        .padding(.top, 60)
    }

    private var statusArea: some View {
        VStack(spacing: 10) {
            captureCounterBadge
            if coordinator.cameraSettingsLocked {
                HStack(spacing: 6) {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 10, weight: .semibold))
                    Text("Exposure · ISO · WB locked")
                        .font(.caption2.weight(.semibold))
                }
                .foregroundColor(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Color.black.opacity(0.55))
                .cornerRadius(14)
            }
            if let guidance = coordinator.guidanceMessage {
                Text(guidance)
                    .font(.footnote.weight(.semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Color.orange.opacity(0.85))
                    .cornerRadius(12)
                    .transition(.opacity)
            }
            if let notice = coordinator.qualityNotice {
                Text(notice)
                    .font(.footnote.weight(.semibold))
                    .foregroundColor(.black)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Color.yellow.opacity(0.9))
                    .cornerRadius(12)
                    .transition(.opacity)
            }
            if coordinator.didHitImageLimit {
                Text("Photo limit reached")
                    .font(.footnote.weight(.semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Color.blue.opacity(0.85))
                    .cornerRadius(12)
            }
            if let errorMessage {
                Text(errorMessage)
                    .font(.footnote)
                    .foregroundColor(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Color.red.opacity(0.85))
                    .cornerRadius(12)
            }
        }
        .padding(.top, 14)
        .animation(.easeInOut(duration: 0.25), value: coordinator.guidanceMessage)
        .animation(.easeInOut(duration: 0.25), value: coordinator.qualityNotice)
    }

    private var captureCounterBadge: some View {
        HStack(spacing: 8) {
            Image(systemName: "camera.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.white)
            Text(counterText)
                .font(.caption.weight(.semibold))
                .foregroundColor(.white)
            if coordinator.phase == .recording {
                Circle().fill(Color.red).frame(width: 8, height: 8)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(Color.black.opacity(0.55))
        .cornerRadius(20)
    }

    private var counterText: String {
        switch coordinator.phase {
        case .idle:
            return "Ready"
        case .recording, .paused:
            if coordinator.rejectedFrameCount > 0 {
                return "\(coordinator.capturedImageCount) photos · \(coordinator.rejectedFrameCount) skipped"
            }
            return "\(coordinator.capturedImageCount) photos"
        }
    }

    private var bottomBar: some View {
        VStack(spacing: 14) {
            if coordinator.phase == .idle {
                Text("Photos are captured automatically.\nMove slowly around your subject.")
                    .font(.subheadline)
                    .foregroundColor(.white)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 10)
                    .background(Color.black.opacity(0.55))
                    .cornerRadius(12)
            }

            ZStack {
                HStack {
                    thumbnailWell
                    Spacer()
                    finishButton
                }
                .padding(.horizontal, 36)

                recordButton
            }
        }
        .padding(.bottom, 44)
    }

    private var thumbnailWell: some View {
        Group {
            if let thumbnail = coordinator.lastCaptureThumbnail {
                Image(uiImage: thumbnail)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 52, height: 52)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(Color.white.opacity(0.8), lineWidth: 1.5)
                    )
            } else {
                Color.clear.frame(width: 52, height: 52)
            }
        }
    }

    @ViewBuilder
    private var finishButton: some View {
        if coordinator.capturedImageCount >= Self.minImagesToFinish {
            Button(action: finish) {
                Image(systemName: "checkmark")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundColor(.white)
                    .frame(width: 52, height: 52)
                    .background(Color.green)
                    .clipShape(Circle())
            }
        } else {
            Color.clear.frame(width: 52, height: 52)
        }
    }

    private var recordButton: some View {
        Button(action: toggleRecording) {
            ZStack {
                Circle()
                    .stroke(Color.white, lineWidth: 4)
                    .frame(width: 74, height: 74)
                if coordinator.phase == .recording {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.red)
                        .frame(width: 30, height: 30)
                } else {
                    Circle()
                        .fill(Color.red)
                        .frame(width: 60, height: 60)
                }
            }
        }
        .disabled(coordinator.didHitImageLimit && coordinator.phase != .recording)
    }

    // MARK: - Actions

    private func toggleRecording() {
        errorMessage = nil
        switch coordinator.phase {
        case .recording:
            coordinator.pauseRecording()
        case .idle, .paused:
            do {
                try coordinator.startRecording()
            } catch {
                errorMessage = "Could not start capture: \(error.localizedDescription)"
            }
        }
    }

    private func finish() {
        errorMessage = nil
        isExporting = true
        coordinator.finishAndExport { result in
            DispatchQueue.main.async {
                switch result {
                case .success(let payload):
                    completion(payload)
                case .failure(let error):
                    isExporting = false
                    errorMessage = "Export failed: \(error.localizedDescription)"
                }
            }
        }
    }

    private func cancel() {
        coordinator.cancelAndCleanup()
        completion(nil)
    }
}

// MARK: - Coordinator

@available(iOS 14.0, *)
final class GaussianSplatCoordinator: NSObject, ObservableObject, ARSessionDelegate {
    enum CapturePhase {
        case idle
        case recording
        case paused
    }

    @Published var phase: CapturePhase = .idle
    @Published var capturedImageCount = 0
    @Published var rejectedFrameCount = 0
    @Published var guidanceMessage: String?
    @Published var qualityNotice: String?
    @Published var cameraSettingsLocked = false
    @Published var lastCaptureThumbnail: UIImage?
    @Published var didHitImageLimit = false

    private var options = GaussianSplatCaptureOptions()
    private weak var sceneView: ARSCNView?
    private let writer = GaussianSplatDatasetWriter()

    private var latestFrame: ARFrame?
    private var lastKeyframeTransform: simd_float4x4?
    private var lastCaptureTimestamp: TimeInterval = 0
    private var previousFrameTransform: simd_float4x4?
    private var previousFrameTimestamp: TimeInterval = 0
    private var currentSpeedMetersPerSecond: Float = 0
    private var currentAngularSpeedRadiansPerSecond: Float = 0
    private var pendingWriteCount = 0
    private var nextKeyframeIndex = 0
    private var markerNodes: [SCNNode] = []
    private var qualityNoticeResetWorkItem: DispatchWorkItem?

    /// Skip captures while this many frames are still being encoded, so the
    /// ARKit pixel-buffer pool is never starved.
    private static let maxPendingWrites = 3
    private static let minSecondsBetweenCaptures: TimeInterval = 0.15
    /// Above this camera speed frames are likely motion-blurred; capture is
    /// held and the user is told to slow down.
    private static let maxCaptureSpeedMetersPerSecond: Float = 0.9
    /// Estimated motion blur (exposure duration × image-space velocity) above
    /// which a frame is not worth capturing.
    private static let maxPredictedBlurPixels: Float = 8
    /// Nominal subject distance used to convert linear camera speed into
    /// image-space pixel velocity for the blur estimate.
    private static let nominalSubjectDistanceMeters: Float = 1.0
    private static let maxFeaturePointsPerKeyframe = 2000

    func start(sceneView: ARSCNView, options: GaussianSplatCaptureOptions) {
        self.options = options
        self.sceneView = sceneView
        sceneView.session.delegate = self
        sceneView.scene = SCNScene()
        sceneView.debugOptions = [ARSCNDebugOptions.showFeaturePoints]
        sceneView.automaticallyUpdatesLighting = true

        let config = ARWorldTrackingConfiguration()
        if options.includeDepthMaps,
           ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
            config.frameSemantics.insert(.sceneDepth)
        }
        sceneView.session.run(config, options: [.resetTracking, .removeExistingAnchors])
    }

    func stopSession() {
        restoreCameraSettings()
        sceneView?.session.pause()
    }

    func startRecording() throws {
        guard !didHitImageLimit else { return }
        if phase == .idle {
            try writer.prepare(includeDepth: options.includeDepthMaps)
        }
        phase = .recording
        lockCameraSettingsWhenConverged()
    }

    func pauseRecording() {
        guard phase == .recording else { return }
        phase = .paused
    }

    func finishAndExport(completion: @escaping (Result<[String: Any], Error>) -> Void) {
        phase = .paused
        stopSession()
        writer.finalizeDataset(
            format: options.format,
            rejectedFrameCount: rejectedFrameCount,
            completion: completion
        )
    }

    // MARK: - Camera settings lock (consistent ISO / shutter / white balance)

    /// Waits for auto-exposure and auto-white-balance to settle, then locks
    /// them (and optionally focus) so every frame in the dataset shares the
    /// same ISO, shutter speed, and color rendition. Kept locked across
    /// pause/resume; restored when the session ends.
    private func lockCameraSettingsWhenConverged(attempt: Int = 0) {
        guard options.lockCameraSettings, !cameraSettingsLocked else { return }
        guard #available(iOS 16.0, *) else { return }
        guard let device = ARWorldTrackingConfiguration
            .configurableCaptureDeviceForPrimaryCamera else { return }

        // Give AE/AWB up to ~1.5 s to converge before freezing them.
        if (device.isAdjustingExposure || device.isAdjustingWhiteBalance), attempt < 15 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                self?.lockCameraSettingsWhenConverged(attempt: attempt + 1)
            }
            return
        }

        do {
            try device.lockForConfiguration()
            if device.isExposureModeSupported(.locked) {
                device.exposureMode = .locked
            }
            if device.isWhiteBalanceModeSupported(.locked) {
                device.whiteBalanceMode = .locked
            }
            if options.lockFocus, device.isFocusModeSupported(.locked) {
                device.focusMode = .locked
            }
            device.unlockForConfiguration()
            cameraSettingsLocked = true
        } catch {
            // Locking is best-effort; capture continues with auto settings.
        }
    }

    private func restoreCameraSettings() {
        guard cameraSettingsLocked else { return }
        cameraSettingsLocked = false
        guard #available(iOS 16.0, *) else { return }
        guard let device = ARWorldTrackingConfiguration
            .configurableCaptureDeviceForPrimaryCamera else { return }
        do {
            try device.lockForConfiguration()
            if device.isExposureModeSupported(.continuousAutoExposure) {
                device.exposureMode = .continuousAutoExposure
            }
            if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
                device.whiteBalanceMode = .continuousAutoWhiteBalance
            }
            if device.isFocusModeSupported(.continuousAutoFocus) {
                device.focusMode = .continuousAutoFocus
            }
            device.unlockForConfiguration()
        } catch {
            // Session is ending; nothing to recover.
        }
    }

    func cancelAndCleanup() {
        phase = .idle
        stopSession()
        writer.cancelAndCleanup()
    }

    // MARK: ARSessionDelegate

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        latestFrame = frame
        updateSpeedEstimate(frame: frame)
        updateGuidance(frame: frame)

        if phase == .recording {
            captureKeyframeIfNeeded(frame: frame)
        }

        previousFrameTransform = frame.camera.transform
        previousFrameTimestamp = frame.timestamp
    }

    func sessionWasInterrupted(_ session: ARSession) {
        if phase == .recording {
            phase = .paused
        }
    }

    // MARK: - Guidance

    private func updateSpeedEstimate(frame: ARFrame) {
        guard
            let previousTransform = previousFrameTransform,
            frame.timestamp > previousFrameTimestamp
        else { return }
        let delta = Self.translationDistance(previousTransform, frame.camera.transform)
        let angleDelta = Self.rotationAngleDegrees(previousTransform, frame.camera.transform)
            * .pi / 180
        let dt = Float(frame.timestamp - previousFrameTimestamp)
        guard dt > 0 else { return }
        // Low-pass filter to keep the "too fast" warning from flickering.
        let instantaneous = delta / dt
        currentSpeedMetersPerSecond = currentSpeedMetersPerSecond * 0.8 + instantaneous * 0.2
        let instantaneousAngular = angleDelta / dt
        currentAngularSpeedRadiansPerSecond =
            currentAngularSpeedRadiansPerSecond * 0.8 + instantaneousAngular * 0.2
    }

    /// Estimated motion blur in pixels for this frame: exposure time times
    /// the image-space velocity from camera rotation and translation.
    private func predictedBlurPixels(frame: ARFrame) -> Float {
        let exposure = Float(frame.camera.exposureDuration)
        let focalPixels = frame.camera.intrinsics[0][0]
        let angularVelocity = currentAngularSpeedRadiansPerSecond
        let linearVelocity = currentSpeedMetersPerSecond / Self.nominalSubjectDistanceMeters
        return exposure * focalPixels * (angularVelocity + linearVelocity)
    }

    private func showQualityNotice(_ message: String) {
        qualityNotice = message
        qualityNoticeResetWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.qualityNotice = nil
        }
        qualityNoticeResetWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6, execute: workItem)
    }

    private func updateGuidance(frame: ARFrame) {
        let message: String?
        switch frame.camera.trackingState {
        case .notAvailable:
            message = "Tracking unavailable"
        case .limited(.initializing):
            message = "Initializing — move your device slowly"
        case .limited(.excessiveMotion):
            message = "Slow down"
        case .limited(.insufficientFeatures):
            message = "Not enough detail — add light or texture"
        case .limited(.relocalizing):
            message = "Relocalizing…"
        case .limited:
            message = "Limited tracking"
        case .normal:
            if phase == .recording,
               currentSpeedMetersPerSecond > Self.maxCaptureSpeedMetersPerSecond {
                message = "Move slower to avoid blur"
            } else {
                message = nil
            }
        }
        if message != guidanceMessage {
            guidanceMessage = message
        }
    }

    // MARK: - Keyframe capture

    private func captureKeyframeIfNeeded(frame: ARFrame) {
        guard case .normal = frame.camera.trackingState else { return }
        guard pendingWriteCount < Self.maxPendingWrites else { return }
        guard frame.timestamp - lastCaptureTimestamp >= Self.minSecondsBetweenCaptures else { return }
        guard currentSpeedMetersPerSecond <= Self.maxCaptureSpeedMetersPerSecond else { return }

        let transform = frame.camera.transform
        if let lastTransform = lastKeyframeTransform {
            let movedEnough = Self.translationDistance(lastTransform, transform)
                >= options.translationThresholdMeters
            let rotatedEnough = Self.rotationAngleDegrees(lastTransform, transform)
                >= options.rotationThresholdDegrees
            guard movedEnough || rotatedEnough else { return }
        }

        // The frame is due, but skip it if the current exposure and camera
        // motion would smear it — the user is prompted and the same pose is
        // retried on a later, steadier frame.
        guard predictedBlurPixels(frame: frame) <= Self.maxPredictedBlurPixels else {
            showQualityNotice("Hold steadier — waiting for a sharp frame")
            return
        }

        let imageResolution = frame.camera.imageResolution
        var featurePoints: [SIMD3<Float>] = []
        if let rawPoints = frame.rawFeaturePoints?.points {
            featurePoints = Array(rawPoints.prefix(Self.maxFeaturePointsPerKeyframe))
        }

        let job = GaussianSplatDatasetWriter.KeyframeJob(
            index: nextKeyframeIndex,
            pixelBuffer: frame.capturedImage,
            depthMap: options.includeDepthMaps
                ? (frame.smoothedSceneDepth?.depthMap ?? frame.sceneDepth?.depthMap)
                : nil,
            transform: transform,
            intrinsics: frame.camera.intrinsics,
            width: Int(imageResolution.width),
            height: Int(imageResolution.height),
            timestamp: frame.timestamp,
            featurePoints: featurePoints,
            jpegQuality: options.jpegQuality
        )

        nextKeyframeIndex += 1
        let previousKeyframeTransform = lastKeyframeTransform
        lastKeyframeTransform = transform
        lastCaptureTimestamp = frame.timestamp
        pendingWriteCount += 1
        let marker = addKeyframeMarker(transform: transform)

        writer.enqueue(job: job) { [weak self] outcome, exposureNotice in
            DispatchQueue.main.async {
                guard let self else { return }
                self.pendingWriteCount = max(0, self.pendingWriteCount - 1)
                if let exposureNotice {
                    self.showQualityNotice(exposureNotice)
                }
                switch outcome {
                case .saved(let thumbnail):
                    self.capturedImageCount += 1
                    if let thumbnail {
                        self.lastCaptureThumbnail = thumbnail
                    }
                    if self.capturedImageCount >= self.options.maxImages {
                        self.didHitImageLimit = true
                        if self.phase == .recording {
                            self.phase = .paused
                        }
                    }
                case .rejectedBlurry:
                    // Undo the keyframe advance so the same pose is retried
                    // with a sharper frame.
                    self.rejectedFrameCount += 1
                    self.lastKeyframeTransform = previousKeyframeTransform
                    marker?.removeFromParentNode()
                    self.showQualityNotice("Blurry frame skipped — hold steadier")
                case .failed:
                    self.lastKeyframeTransform = previousKeyframeTransform
                    marker?.removeFromParentNode()
                }
            }
        }
    }

    /// Drops a small translucent card at the capture pose — the RealityScan
    /// style breadcrumb trail showing where photos were taken. Returns the
    /// node so a rejected frame can remove its marker again.
    @discardableResult
    private func addKeyframeMarker(transform: simd_float4x4) -> SCNNode? {
        guard let sceneView else { return nil }
        let plane = SCNPlane(width: 0.04, height: 0.03)
        plane.cornerRadius = 0.006
        let material = SCNMaterial()
        material.diffuse.contents = UIColor.white.withAlphaComponent(0.65)
        material.isDoubleSided = true
        material.lightingModel = .constant
        plane.materials = [material]
        let node = SCNNode(geometry: plane)
        node.simdTransform = transform
        sceneView.scene.rootNode.addChildNode(node)
        markerNodes.append(node)
        return node
    }

    // MARK: - Pose math

    private static func translationDistance(
        _ a: simd_float4x4,
        _ b: simd_float4x4
    ) -> Float {
        let ta = SIMD3<Float>(a.columns.3.x, a.columns.3.y, a.columns.3.z)
        let tb = SIMD3<Float>(b.columns.3.x, b.columns.3.y, b.columns.3.z)
        return simd_distance(ta, tb)
    }

    private static func rotationAngleDegrees(
        _ a: simd_float4x4,
        _ b: simd_float4x4
    ) -> Float {
        let qa = simd_quatf(rotationMatrix(a))
        let qb = simd_quatf(rotationMatrix(b))
        let delta = qa.inverse * qb
        let angle = abs(delta.angle)
        let wrapped = angle > .pi ? (2 * .pi - angle) : angle
        return wrapped * 180 / .pi
    }

    private static func rotationMatrix(_ m: simd_float4x4) -> simd_float3x3 {
        simd_float3x3(
            SIMD3<Float>(m.columns.0.x, m.columns.0.y, m.columns.0.z),
            SIMD3<Float>(m.columns.1.x, m.columns.1.y, m.columns.1.z),
            SIMD3<Float>(m.columns.2.x, m.columns.2.y, m.columns.2.z)
        )
    }
}

// MARK: - Dataset writer

/// Serial background writer for the capture session. Encodes keyframe JPEGs,
/// accumulates a colored sparse point cloud, and finalizes the dataset as
/// nerfstudio-format `transforms.json` (+ `sparse_pc.ply`, optional depth
/// maps) ready for Gaussian-splatting trainers (nerfstudio/gsplat, Brush).
@available(iOS 14.0, *)
final class GaussianSplatDatasetWriter {
    enum KeyframeOutcome {
        case saved(thumbnail: UIImage?)
        /// The frame failed the measured-sharpness check and was not written.
        case rejectedBlurry
        case failed(Error)
    }

    struct KeyframeJob {
        let index: Int
        let pixelBuffer: CVPixelBuffer
        let depthMap: CVPixelBuffer?
        let transform: simd_float4x4
        let intrinsics: simd_float3x3
        let width: Int
        let height: Int
        let timestamp: TimeInterval
        let featurePoints: [SIMD3<Float>]
        let jpegQuality: Double
    }

    private struct KeyframeRecord {
        let imageFileName: String
        let depthFileName: String?
        let transform: simd_float4x4
        let fx: Float
        let fy: Float
        let cx: Float
        let cy: Float
        let width: Int
        let height: Int
    }

    private let ioQueue = DispatchQueue(
        label: "apple_spatial_capture.gaussian_splat.io",
        qos: .userInitiated
    )
    private let ciContext = CIContext(options: nil)
    private let colorSpace = CGColorSpaceCreateDeviceRGB()

    // All mutable state below is touched only on ioQueue (after prepare).
    private var datasetURL: URL?
    private var imagesURL: URL?
    private var depthURL: URL?
    private var records: [KeyframeRecord] = []
    /// Sparse points keyed by ~1 cm world voxel so re-observed features don't
    /// duplicate; value keeps the most recent color sample.
    private var pointVoxels: [Int64: (position: SIMD3<Float>, color: SIMD3<UInt8>)] = [:]
    /// Laplacian-variance sharpness of recently accepted frames; new frames
    /// are rejected when they fall far below this scan's own baseline.
    private var sharpnessHistory: [Double] = []

    private static let maxAccumulatedPoints = 400_000
    private static let sharpnessHistoryLimit = 12
    /// A frame must reach this fraction of the median accepted sharpness.
    private static let minRelativeSharpness = 0.3
    private static let minSharpnessSamples = 3
    /// Mean luma (0–1) below which the scene is warned as too dark.
    private static let darkSceneMeanLuma = 0.15
    /// Fraction of near-clipped pixels above which highlights are warned.
    private static let clippedHighlightsFraction = 0.2
    private static let colorSampleWidth: CGFloat = 480
    private static let voxelSize: Float = 0.01
    private static let voxelBias: Int64 = 1 << 20
    private static let voxelMask: Int64 = (1 << 21) - 1

    func prepare(includeDepth: Bool) throws {
        guard datasetURL == nil else { return }
        // Datasets live in Documents/GaussianSplatDatasets so they survive
        // (tmp/ is purgeable) and are reachable via the Files app / Finder
        // when the host app enables UIFileSharingEnabled.
        let containerURL = FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let root = containerURL
            .appendingPathComponent("GaussianSplatDatasets", isDirectory: true)
            .appendingPathComponent(
                "gs_\(formatter.string(from: Date()))",
                isDirectory: true
            )
        let images = root.appendingPathComponent("images", isDirectory: true)
        try FileManager.default.createDirectory(at: images, withIntermediateDirectories: true)
        var depth: URL?
        if includeDepth {
            let depthDir = root.appendingPathComponent("depth", isDirectory: true)
            try FileManager.default.createDirectory(at: depthDir, withIntermediateDirectories: true)
            depth = depthDir
        }
        datasetURL = root
        imagesURL = images
        depthURL = depth
    }

    /// Encodes one keyframe off the session thread. The frame is analyzed
    /// first (measured sharpness against this scan's baseline, exposure
    /// sanity) and only written when it passes, so no blurry image ever
    /// reaches the dataset. `completion` also carries a transient exposure
    /// notice ("too dark" / "clipped highlights") when applicable.
    func enqueue(
        job: KeyframeJob,
        completion: @escaping (KeyframeOutcome, _ exposureNotice: String?) -> Void
    ) {
        ioQueue.async { [self] in
            guard let imagesURL else {
                completion(.failed(Self.error("Dataset directory is not prepared.")), nil)
                return
            }

            // One downscaled RGBA raster serves the quality analysis, the UI
            // thumbnail, and the color samples for this keyframe's sparse
            // points.
            let ciImage = CIImage(cvPixelBuffer: job.pixelBuffer)
            guard let raster = rasterizeScaledRGBA(ciImage: ciImage) else {
                completion(.failed(Self.error("Could not analyze the camera frame.")), nil)
                return
            }

            let quality = Self.analyzeQuality(raster: raster)
            var exposureNotice: String?
            if quality.meanLuma < Self.darkSceneMeanLuma {
                exposureNotice = "Scene is dark — add light for a cleaner splat"
            } else if quality.clippedFraction > Self.clippedHighlightsFraction {
                exposureNotice = "Highlights are clipping — reduce exposure or avoid bright light"
            }

            if sharpnessHistory.count >= Self.minSharpnessSamples {
                let sorted = sharpnessHistory.sorted()
                let median = sorted[sorted.count / 2]
                if quality.sharpness < median * Self.minRelativeSharpness {
                    completion(.rejectedBlurry, exposureNotice)
                    return
                }
            }

            let imageFileName = String(format: "frame_%05d.jpg", job.index + 1)
            let imageURL = imagesURL.appendingPathComponent(imageFileName)
            do {
                try ciContext.writeJPEGRepresentation(
                    of: ciImage,
                    to: imageURL,
                    colorSpace: colorSpace,
                    options: [
                        CIImageRepresentationOption(
                            rawValue: kCGImageDestinationLossyCompressionQuality as String
                        ): job.jpegQuality
                    ]
                )
            } catch {
                completion(.failed(error), exposureNotice)
                return
            }

            sharpnessHistory.append(quality.sharpness)
            if sharpnessHistory.count > Self.sharpnessHistoryLimit {
                sharpnessHistory.removeFirst()
            }

            var depthFileName: String?
            if let depthMap = job.depthMap, let depthURL {
                let fileName = String(format: "depth_%05d.png", job.index + 1)
                if Self.writeDepthPNG(
                    depthMap: depthMap,
                    to: depthURL.appendingPathComponent(fileName)
                ) {
                    depthFileName = fileName
                }
            }

            let thumbnail = UIImage(cgImage: raster.cgImage, scale: 1, orientation: .right)
            ingestFeaturePoints(job: job, raster: raster)

            records.append(
                KeyframeRecord(
                    imageFileName: imageFileName,
                    depthFileName: depthFileName,
                    transform: job.transform,
                    fx: job.intrinsics[0][0],
                    fy: job.intrinsics[1][1],
                    cx: job.intrinsics[2][0],
                    cy: job.intrinsics[2][1],
                    width: job.width,
                    height: job.height
                )
            )
            completion(.saved(thumbnail: thumbnail), exposureNotice)
        }
    }

    // MARK: - Frame quality analysis

    private struct FrameQuality {
        /// Variance of a 4-neighbor Laplacian over luma — higher is sharper.
        let sharpness: Double
        /// Mean luma in 0–1.
        let meanLuma: Double
        /// Fraction of pixels at or near full white.
        let clippedFraction: Double
    }

    private static func analyzeQuality(raster: ScaledRaster) -> FrameQuality {
        let width = raster.width
        let height = raster.height
        var luma = [Float](repeating: 0, count: width * height)
        var lumaSum = 0.0
        var clippedCount = 0
        for y in 0..<height {
            let rowOffset = y * raster.rowBytes
            for x in 0..<width {
                let offset = rowOffset + x * 4
                let r = Float(raster.pixels[offset])
                let g = Float(raster.pixels[offset + 1])
                let b = Float(raster.pixels[offset + 2])
                let value = (0.299 * r + 0.587 * g + 0.114 * b) / 255
                luma[y * width + x] = value
                lumaSum += Double(value)
                if value > 0.97 { clippedCount += 1 }
            }
        }

        var lapSum = 0.0
        var lapSquaredSum = 0.0
        var sampleCount = 0
        for y in stride(from: 1, to: height - 1, by: 2) {
            for x in stride(from: 1, to: width - 1, by: 2) {
                let index = y * width + x
                let lap = Double(
                    4 * luma[index]
                        - luma[index - 1] - luma[index + 1]
                        - luma[index - width] - luma[index + width]
                )
                lapSum += lap
                lapSquaredSum += lap * lap
                sampleCount += 1
            }
        }

        let pixelCount = Double(width * height)
        let lapMean = sampleCount > 0 ? lapSum / Double(sampleCount) : 0
        let variance = sampleCount > 0
            ? max(0, lapSquaredSum / Double(sampleCount) - lapMean * lapMean)
            : 0
        return FrameQuality(
            sharpness: variance,
            meanLuma: pixelCount > 0 ? lumaSum / pixelCount : 0,
            clippedFraction: pixelCount > 0 ? Double(clippedCount) / pixelCount : 0
        )
    }

    func finalizeDataset(
        format: GaussianSplatDatasetFormat,
        rejectedFrameCount: Int,
        completion: @escaping (Result<[String: Any], Error>) -> Void
    ) {
        ioQueue.async { [self] in
            guard let datasetURL, !records.isEmpty else {
                completion(.failure(Self.error("No frames were captured.")))
                return
            }

            var payload: [String: Any] = [
                "datasetPath": datasetURL.path,
                "imageCount": records.count,
                "pointCount": pointVoxels.count,
                "rejectedImageCount": rejectedFrameCount,
            ]

            if format.includesNerfstudio {
                do {
                    let result = try writeNerfstudioTransforms(datasetURL: datasetURL)
                    payload["transformsPath"] = result.transformsURL.path
                    if let pointCloudURL = result.pointCloudURL {
                        payload["pointCloudPath"] = pointCloudURL.path
                    }
                } catch {
                    completion(.failure(error))
                    return
                }
            }

            if format.includesColmap {
                do {
                    let colmapURL = try writeColmapModel(datasetURL: datasetURL)
                    payload["colmapPath"] = colmapURL.path
                } catch {
                    completion(.failure(error))
                    return
                }
            }

            completion(.success(payload))
        }
    }

    // MARK: - nerfstudio layout

    private func writeNerfstudioTransforms(
        datasetURL: URL
    ) throws -> (transformsURL: URL, pointCloudURL: URL?) {
        guard let firstRecord = records.first else {
            throw Self.error("No frames were captured.")
        }

        var pointCloudURL: URL?
        var pointCloudFileName: String?
        if !pointVoxels.isEmpty {
            let fileName = "sparse_pc.ply"
            let url = datasetURL.appendingPathComponent(fileName)
            do {
                try writePointCloudPLY(to: url)
                pointCloudFileName = fileName
                pointCloudURL = url
            } catch {
                // The point cloud is an optional training prior; a failed
                // write should not lose the captured images and poses.
            }
        }

        var root: [String: Any] = [
            "camera_model": "OPENCV",
            "w": firstRecord.width,
            "h": firstRecord.height,
            "fl_x": Double(firstRecord.fx),
            "fl_y": Double(firstRecord.fy),
            "cx": Double(firstRecord.cx),
            "cy": Double(firstRecord.cy),
            "k1": 0.0,
            "k2": 0.0,
            "p1": 0.0,
            "p2": 0.0,
            "frames": records.map { record -> [String: Any] in
                var frame: [String: Any] = [
                    "file_path": "images/\(record.imageFileName)",
                    "w": record.width,
                    "h": record.height,
                    "fl_x": Double(record.fx),
                    "fl_y": Double(record.fy),
                    "cx": Double(record.cx),
                    "cy": Double(record.cy),
                    "transform_matrix": Self.matrixRows(record.transform),
                ]
                if let depthFileName = record.depthFileName {
                    frame["depth_file_path"] = "depth/\(depthFileName)"
                }
                return frame
            },
        ]
        if let pointCloudFileName {
            root["ply_file_path"] = pointCloudFileName
        }

        let transformsURL = datasetURL.appendingPathComponent("transforms.json")
        let data = try JSONSerialization.data(
            withJSONObject: root,
            options: [.prettyPrinted, .sortedKeys]
        )
        try data.write(to: transformsURL, options: .atomic)
        return (transformsURL, pointCloudURL)
    }

    // MARK: - COLMAP layout (LichtFeld Studio, reference 3DGS)

    /// Writes a COLMAP text model at `sparse/0/`. COLMAP stores world-to-camera
    /// poses in the OpenCV camera convention (+x right, +y down, +z forward),
    /// so ARKit's OpenGL-style camera-to-world transforms are converted here.
    private func writeColmapModel(datasetURL: URL) throws -> URL {
        let sparseURL = datasetURL
            .appendingPathComponent("sparse", isDirectory: true)
            .appendingPathComponent("0", isDirectory: true)
        try FileManager.default.createDirectory(
            at: sparseURL,
            withIntermediateDirectories: true
        )

        // Flips +y/+z to move between OpenGL and OpenCV camera axes.
        let openGLToOpenCV = simd_float4x4(diagonal: SIMD4<Float>(1, -1, -1, 1))

        var cameras = "# Camera list with one line of data per camera:\n"
        cameras += "#   CAMERA_ID, MODEL, WIDTH, HEIGHT, PARAMS[]\n"
        var images = "# Image list with two lines of data per image:\n"
        images += "#   IMAGE_ID, QW, QX, QY, QZ, TX, TY, TZ, CAMERA_ID, NAME\n"
        images += "#   POINTS2D[] as (X, Y, POINT3D_ID)\n"

        for (index, record) in records.enumerated() {
            let id = index + 1
            cameras += "\(id) PINHOLE \(record.width) \(record.height) "
            cameras += "\(record.fx) \(record.fy) \(record.cx) \(record.cy)\n"

            let worldToCamera = (record.transform * openGLToOpenCV).inverse
            let rotation = simd_quatf(Self.rotationMatrix(worldToCamera))
            let translation = worldToCamera.columns.3
            images += "\(id) \(rotation.real) \(rotation.imag.x) \(rotation.imag.y) \(rotation.imag.z) "
            images += "\(translation.x) \(translation.y) \(translation.z) "
            images += "\(id) \(record.imageFileName)\n"
            // No per-image 2D observations; trainers only need the poses.
            images += "\n"
        }

        var points = "# 3D point list with one line of data per point:\n"
        points += "#   POINT3D_ID, X, Y, Z, R, G, B, ERROR, TRACK[] as (IMAGE_ID, POINT2D_IDX)\n"
        var pointId = 1
        for (_, entry) in pointVoxels {
            points += "\(pointId) \(entry.position.x) \(entry.position.y) \(entry.position.z) "
            points += "\(entry.color.x) \(entry.color.y) \(entry.color.z) 1.0\n"
            pointId += 1
        }

        try cameras.write(
            to: sparseURL.appendingPathComponent("cameras.txt"),
            atomically: true,
            encoding: .utf8
        )
        try images.write(
            to: sparseURL.appendingPathComponent("images.txt"),
            atomically: true,
            encoding: .utf8
        )
        try points.write(
            to: sparseURL.appendingPathComponent("points3D.txt"),
            atomically: true,
            encoding: .utf8
        )
        return sparseURL
    }

    private static func rotationMatrix(_ m: simd_float4x4) -> simd_float3x3 {
        simd_float3x3(
            SIMD3<Float>(m.columns.0.x, m.columns.0.y, m.columns.0.z),
            SIMD3<Float>(m.columns.1.x, m.columns.1.y, m.columns.1.z),
            SIMD3<Float>(m.columns.2.x, m.columns.2.y, m.columns.2.z)
        )
    }

    func cancelAndCleanup() {
        ioQueue.async { [self] in
            if let datasetURL {
                try? FileManager.default.removeItem(at: datasetURL)
            }
            datasetURL = nil
            imagesURL = nil
            depthURL = nil
            records.removeAll()
            pointVoxels.removeAll()
        }
    }

    // MARK: - Sparse point cloud

    private struct ScaledRaster {
        let cgImage: CGImage
        let pixels: [UInt8]
        let width: Int
        let height: Int
        let rowBytes: Int
        /// Scale from full-resolution image pixels to raster pixels.
        let scale: CGFloat
    }

    private func rasterizeScaledRGBA(ciImage: CIImage) -> ScaledRaster? {
        let extent = ciImage.extent
        guard extent.width > 1, extent.height > 1 else { return nil }
        let scale = Self.colorSampleWidth / extent.width
        let scaled = ciImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let cgImage = ciContext.createCGImage(scaled, from: scaled.extent) else {
            return nil
        }

        let width = cgImage.width
        let height = cgImage.height
        let rowBytes = width * 4
        var pixels = [UInt8](repeating: 0, count: rowBytes * height)
        let bitmapInfo = CGBitmapInfo.byteOrder32Big.rawValue
            | CGImageAlphaInfo.premultipliedLast.rawValue
        let didDraw = pixels.withUnsafeMutableBytes { rawBuffer -> Bool in
            guard
                let baseAddress = rawBuffer.baseAddress,
                let context = CGContext(
                    data: baseAddress,
                    width: width,
                    height: height,
                    bitsPerComponent: 8,
                    bytesPerRow: rowBytes,
                    space: colorSpace,
                    bitmapInfo: bitmapInfo
                )
            else { return false }
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard didDraw else { return nil }
        return ScaledRaster(
            cgImage: cgImage,
            pixels: pixels,
            width: width,
            height: height,
            rowBytes: rowBytes,
            scale: scale
        )
    }

    private func ingestFeaturePoints(job: KeyframeJob, raster: ScaledRaster) {
        guard pointVoxels.count < Self.maxAccumulatedPoints else { return }
        let worldToCamera = job.transform.inverse
        let fx = CGFloat(job.intrinsics[0][0])
        let fy = CGFloat(job.intrinsics[1][1])
        let cx = CGFloat(job.intrinsics[2][0])
        let cy = CGFloat(job.intrinsics[2][1])

        for point in job.featurePoints {
            let camera = worldToCamera * SIMD4<Float>(point.x, point.y, point.z, 1)
            // ARKit cameras look along -Z; reject points behind or far away.
            guard camera.z < -0.05, camera.z > -10 else { continue }

            // Project into sensor-oriented pixel coordinates (+y down).
            let u = fx * CGFloat(camera.x / -camera.z) + cx
            let v = fy * CGFloat(camera.y / camera.z) + cy
            let px = Int(u * raster.scale)
            let py = Int(v * raster.scale)
            guard px >= 0, px < raster.width, py >= 0, py < raster.height else { continue }

            let offset = py * raster.rowBytes + px * 4
            guard offset + 2 < raster.pixels.count else { continue }
            let color = SIMD3<UInt8>(
                raster.pixels[offset],
                raster.pixels[offset + 1],
                raster.pixels[offset + 2]
            )
            pointVoxels[Self.voxelKey(for: point)] = (point, color)
        }
    }

    private func writePointCloudPLY(to url: URL) throws {
        var body = ""
        body.reserveCapacity(pointVoxels.count * 40)
        for (_, entry) in pointVoxels {
            body += "\(entry.position.x) \(entry.position.y) \(entry.position.z) "
            body += "\(entry.color.x) \(entry.color.y) \(entry.color.z)\n"
        }

        let header = """
        ply
        format ascii 1.0
        element vertex \(pointVoxels.count)
        property float x
        property float y
        property float z
        property uchar red
        property uchar green
        property uchar blue
        end_header

        """
        try (header + body).write(to: url, atomically: true, encoding: .utf8)
    }

    private static func voxelKey(for position: SIMD3<Float>) -> Int64 {
        func quantize(_ value: Float) -> Int64 {
            let q = Int64((value / voxelSize).rounded()) + voxelBias
            return min(max(q, 0), voxelMask)
        }
        return quantize(position.x)
            | (quantize(position.y) << 21)
            | (quantize(position.z) << 42)
    }

    // MARK: - Serialization helpers

    /// Row-major 4×4 camera-to-world matrix. ARKit's camera space (+x right,
    /// +y up, -z forward) matches the OpenGL convention nerfstudio expects,
    /// so the pose is emitted as-is.
    private static func matrixRows(_ m: simd_float4x4) -> [[Double]] {
        (0..<4).map { row in
            (0..<4).map { column in Double(m[column][row]) }
        }
    }

    /// Writes a 16-bit grayscale PNG of depth in millimeters (0 = invalid),
    /// the layout nerfstudio-style loaders expect for `depth_file_path`.
    private static func writeDepthPNG(depthMap: CVPixelBuffer, to url: URL) -> Bool {
        guard CVPixelBufferGetPixelFormatType(depthMap) == kCVPixelFormatType_DepthFloat32 else {
            return false
        }
        CVPixelBufferLockBaseAddress(depthMap, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(depthMap, .readOnly) }

        let width = CVPixelBufferGetWidth(depthMap)
        let height = CVPixelBufferGetHeight(depthMap)
        guard
            width > 0,
            height > 0,
            let base = CVPixelBufferGetBaseAddress(depthMap)?
                .assumingMemoryBound(to: Float32.self)
        else { return false }

        let stride = CVPixelBufferGetBytesPerRow(depthMap) / MemoryLayout<Float32>.size
        var pixels = [UInt16](repeating: 0, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                let depth = base[y * stride + x]
                guard depth.isFinite, depth > 0 else { continue }
                let millimeters = min(depth * 1000, 65535)
                // PNG samples are big-endian.
                pixels[y * width + x] = UInt16(millimeters).bigEndian
            }
        }

        let data = pixels.withUnsafeBytes { Data($0) }
        guard
            let provider = CGDataProvider(data: data as CFData),
            let image = CGImage(
                width: width,
                height: height,
                bitsPerComponent: 16,
                bitsPerPixel: 16,
                bytesPerRow: width * 2,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
            ),
            let destination = CGImageDestinationCreateWithURL(
                url as CFURL,
                UTType.png.identifier as CFString,
                1,
                nil
            )
        else { return false }

        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination)
    }

    private static func error(_ message: String) -> NSError {
        NSError(
            domain: "GaussianSplatCapture",
            code: 2001,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }
}

// MARK: - UIViewRepresentable

@available(iOS 14.0, *)
struct GaussianSplatARViewRepresentable: UIViewRepresentable {
    let coordinator: GaussianSplatCoordinator
    let options: GaussianSplatCaptureOptions

    func makeUIView(context: Context) -> ARSCNView {
        let sceneView = ARSCNView(frame: .zero)
        coordinator.start(sceneView: sceneView, options: options)
        return sceneView
    }

    func updateUIView(_ uiView: ARSCNView, context: Context) {}
}
