import Flutter
import UIKit
import SwiftUI
import RealityKit
import ARKit
import QuickLook
import SceneKit
import GLTFSceneKit
import RoomPlan

@objc public class AppleSpatialCapturePlugin: NSObject, FlutterPlugin, FlutterStreamHandler, QLPreviewControllerDataSource {
    private static let channelName = "apple_spatial_capture"
    private static let progressChannelName = "apple_spatial_capture/progress"
    private static let pipelineTotalSteps = 6
    private var previewFileURL: URL?
    private var progressEventSink: FlutterEventSink?

    private struct PipelineStepInfo {
        let index: Int
        let label: String
    }

    @available(iOS 17.0, *)
    private struct PhotogrammetryRunOptions {
        let detail: PhotogrammetrySession.Request.Detail
        let featureSensitivity: PhotogrammetrySession.Configuration.FeatureSensitivity
        let sampleOrdering: PhotogrammetrySession.Configuration.SampleOrdering
        let useObjectMasking: Bool
        let textureQuality: TextureQualityProfile
        let outputFormat: OutputFormat
        let requestedDetail: String
        let didFallbackDetail: Bool
    }

    private enum OutputFormat {
        case usdz
        case obj
    }

    private struct TextureQualityProfile {
        let maxDimension: CGFloat
        let jpegQuality: CGFloat
        let label: String
    }

    @available(iOS 17.0, *)
    private actor ExportProgressState {
        var done = false

        func markDone() {
            done = true
        }

        func isDone() -> Bool {
            done
        }
    }

    @available(iOS 17.0, *)
    private actor PhotogrammetryWatchdogState {
        private var done = false
        private var exportStarted = false
        private var lastOutputAt = Date()
        private var cancelReason: String?

        func markOutput() {
            lastOutputAt = Date()
        }

        func markExportStarted() {
            exportStarted = true
            lastOutputAt = Date()
        }

        func requestCancel(reason: String) {
            cancelReason = reason
        }

        func markDone() {
            done = true
        }

        func snapshot() -> (done: Bool, exportStarted: Bool, lastOutputAt: Date, cancelReason: String?) {
            (done, exportStarted, lastOutputAt, cancelReason)
        }
    }

    public static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(
            name: channelName,
            binaryMessenger: registrar.messenger()
        )
        let progressChannel = FlutterEventChannel(
            name: progressChannelName,
            binaryMessenger: registrar.messenger()
        )
        let instance = AppleSpatialCapturePlugin()
        registrar.addMethodCallDelegate(instance, channel: channel)
        progressChannel.setStreamHandler(instance)
    }

    public func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        progressEventSink = events
        return nil
    }

    public func onCancel(withArguments arguments: Any?) -> FlutterError? {
        progressEventSink = nil
        return nil
    }

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {

        // --- Object Capture (photogrammetry, iOS 17+) ---
        case "isObjectCaptureSupported":
            if #available(iOS 17.0, *) {
                DispatchQueue.main.async { result(ObjectCaptureSession.isSupported) }
            } else {
                result(false)
            }

        case "startObjectCapture":
            startObjectCapture(result: result)
        case "startPhotogrammetryFromImages":
            startPhotogrammetryFromImages(call: call, result: result)

        // --- LiDAR Mesh Reconstruction (iOS 14+ with LiDAR) ---
        case "isLiDARSupported":
            if #available(iOS 14.0, *) {
                result(ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh))
            } else {
                result(false)
            }

        case "startLiDARCapture":
            startLiDARCapture(result: result)

        case "previewCapturedModel":
            previewCapturedModel(call: call, result: result)

        case "previewRemoteModel":
            previewRemoteModel(call: call, result: result)
        // --- RoomPlan (iOS 16+ with LiDAR) ---
        case "isRoomPlanSupported":
            if #available(iOS 16.0, *) {
                result(RoomCaptureSession.isSupported)
            } else {
                result(false)
            }

        case "startRoomPlanCapture":
            startRoomPlanCapture(result: result)

        // Legacy alias kept for backward compat
        case "isSupported":
            if #available(iOS 17.0, *) {
                DispatchQueue.main.async { result(ObjectCaptureSession.isSupported) }
            } else {
                result(false)
            }
        case "startCapture":
            startObjectCapture(result: result)

        default:
            result(FlutterMethodNotImplemented)
        }
    }

    // MARK: - Object Capture

    private func startObjectCapture(result: @escaping FlutterResult) {
        guard #available(iOS 17.0, *) else {
            result(FlutterError(code: "UNSUPPORTED",
                                message: "Object Capture requires iOS 17.0+.",
                                details: nil))
            return
        }
        DispatchQueue.main.async {
            guard ObjectCaptureSession.isSupported else {
                result(FlutterError(code: "UNSUPPORTED",
                                    message: "Object Capture requires a LiDAR-equipped device.",
                                    details: nil))
                return
            }
            guard let rootVC = self.topViewController() else {
                result(FlutterError(code: "NO_VC", message: "No root view controller.", details: nil))
                return
            }

            let outputDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("objectcapture_\(UUID().uuidString)", isDirectory: true)

            do {
                try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
            } catch {
                result(FlutterError(code: "DIR_ERROR", message: error.localizedDescription, details: nil))
                return
            }

            if #available(iOS 17.0, *) {
                var hostingVC: UIHostingController<ObjectCaptureFlowView>?
                let view = ObjectCaptureFlowView(outputDirectory: outputDir) { usdzPath, captureError in
                    if let path = usdzPath, !path.isEmpty {
                        result(path)
                    } else if let error = captureError, !error.isEmpty {
                        result(FlutterError(code: "CAPTURE_FAILED", message: error, details: nil))
                    } else {
                        result(nil)
                    }
                    DispatchQueue.main.async {
                        hostingVC?.dismiss(animated: true)
                        hostingVC = nil
                    }
                }
                let vc = UIHostingController(rootView: view)
                vc.modalPresentationStyle = .fullScreen
                vc.isModalInPresentation = true
                hostingVC = vc
                rootVC.present(vc, animated: true)
            }
        }
    }

    private func startPhotogrammetryFromImages(call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard #available(iOS 17.0, *) else {
            result(FlutterError(code: "UNSUPPORTED",
                                message: "Photogrammetry requires iOS 17.0+.",
                                details: nil))
            return
        }

        guard ObjectCaptureSession.isSupported else {
            result(FlutterError(code: "UNSUPPORTED",
                                message: "Photogrammetry from photos requires a LiDAR-equipped device.",
                                details: nil))
            return
        }

        guard
            let args = call.arguments as? [String: Any],
            let rawImagePaths = args["imagePaths"] as? [String]
        else {
            result(FlutterError(code: "INVALID_ARGS",
                                message: "Missing selected image paths.",
                                details: nil))
            return
        }

        let rawNormalizedPaths = rawImagePaths
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let operationId = (args["operationId"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let options = parsePhotogrammetryRunOptions(
            from: args["options"] as? [String: Any]
        )

        if options.didFallbackDetail {
            emitProgress(
                operationId: operationId,
                stage: "info",
                message: "Requested detail '\(options.requestedDetail)' is not available on this iOS runtime. Using reduced detail."
            )
        }

        var imagePaths = rawNormalizedPaths
        let sampledPaths = sampleImagePathsForProcessing(
            imagePaths: rawNormalizedPaths,
            textureQuality: options.textureQuality,
            outputFormat: options.outputFormat
        )
        imagePaths = sampledPaths

        if sampledPaths.count < rawNormalizedPaths.count {
            emitProgress(
                operationId: operationId,
                stage: "info",
                message: "Using \(sampledPaths.count)/\(rawNormalizedPaths.count) photos for faster processing."
            )
        }

        guard imagePaths.count >= 3 else {
            result(FlutterError(code: "INSUFFICIENT_IMAGES",
                                message: "Select at least 3 photos to generate a model.",
                                details: nil))
            return
        }

        emitProgress(
            operationId: operationId,
            stage: "preparing",
            message: "Preparing selected photos...",
            progress: 0.0,
            stepIndex: 1,
            stepLabel: "Preparing Images"
        )

        emitProgress(
            operationId: operationId,
            stage: "info",
            message: "Texture quality: \(options.textureQuality.label). Output: \(options.outputFormat == .obj ? "OBJ" : "USDZ"). Object masking: \(options.useObjectMasking ? "On" : "Off")."
        )

        let outputDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("objectcapture_gallery_\(UUID().uuidString)", isDirectory: true)
        let imagesDirectory = outputDir.appendingPathComponent("Images", isDirectory: true)
        let modelURL: URL = {
            switch options.outputFormat {
            case .usdz:
                return outputDir.appendingPathComponent("model.usdz")
            case .obj:
                return outputDir.appendingPathComponent("model_obj", isDirectory: true)
            }
        }()

        do {
            try FileManager.default.createDirectory(at: imagesDirectory, withIntermediateDirectories: true)
            if options.outputFormat == .obj {
                try FileManager.default.createDirectory(at: modelURL, withIntermediateDirectories: true)
            }
            try copySelectedImagesToInputDirectory(
                imagePaths: imagePaths,
                imagesDirectory: imagesDirectory,
                textureQuality: options.textureQuality
            )
            emitProgress(
                operationId: operationId,
                stage: "ingesting",
                message: "Images normalized for photogrammetry. Starting reconstruction...",
                progress: 0.05,
                stepIndex: 2,
                stepLabel: "Ingesting Photos"
            )
        } catch {
            emitProgress(
                operationId: operationId,
                stage: "failed",
                message: "Failed to prepare selected photos."
            )
            result(FlutterError(code: "FILE_PREP_FAILED",
                                message: "Could not prepare selected photos: \(error.localizedDescription)",
                                details: nil))
            return
        }

        Task(priority: .userInitiated) {
            do {
                let generatedURL = try await self.runPhotogrammetry(
                    inputDirectory: imagesDirectory,
                    outputModelURL: modelURL,
                    operationId: operationId,
                    options: options
                )
                DispatchQueue.main.async {
                    self.emitProgress(
                        operationId: operationId,
                        stage: "completed",
                        message: "3D model generated.",
                        progress: 1.0,
                        stepIndex: Self.pipelineTotalSteps,
                        stepLabel: "Completed"
                    )
                    result(generatedURL.path)
                }
            } catch {
                DispatchQueue.main.async {
                    self.emitProgress(
                        operationId: operationId,
                        stage: "failed",
                        message: error.localizedDescription
                    )
                    result(FlutterError(code: "PHOTOGRAMMETRY_FAILED",
                                        message: error.localizedDescription,
                                        details: nil))
                }
            }
        }
    }

    private func copySelectedImagesToInputDirectory(
        imagePaths: [String],
        imagesDirectory: URL,
        textureQuality: TextureQualityProfile
    ) throws {
        let supportedExtensions: Set<String> = ["jpg", "jpeg", "heic", "heif", "png"]
        var copiedCount = 0

        for (index, imagePath) in imagePaths.enumerated() {
            let sourceURL = URL(fileURLWithPath: imagePath)
            guard FileManager.default.fileExists(atPath: sourceURL.path) else { continue }

            let ext = sourceURL.pathExtension.lowercased()
            guard supportedExtensions.contains(ext) else { continue }

            let destinationURL = imagesDirectory
                .appendingPathComponent(String(format: "image_%04d", index + 1))
                .appendingPathExtension("jpg")

            if FileManager.default.fileExists(atPath: destinationURL.path) {
                try? FileManager.default.removeItem(at: destinationURL)
            }

            if let encodedData = makePhotogrammetryJPEGData(
                sourceURL: sourceURL,
                textureQuality: textureQuality
            ) {
                try encodedData.write(to: destinationURL, options: [.atomic])
            } else {
                // Fallback to original file copy if image decoding fails.
                let fallbackURL = imagesDirectory
                    .appendingPathComponent(String(format: "image_%04d", index + 1))
                    .appendingPathExtension(ext)
                if FileManager.default.fileExists(atPath: fallbackURL.path) {
                    try? FileManager.default.removeItem(at: fallbackURL)
                }
                try FileManager.default.copyItem(at: sourceURL, to: fallbackURL)
            }
            copiedCount += 1
        }

        if copiedCount < 3 {
            throw NSError(
                domain: "ObjectCapture",
                code: 1001,
                userInfo: [NSLocalizedDescriptionKey: "Need at least 3 valid image files."]
            )
        }
    }

    private func makePhotogrammetryJPEGData(
        sourceURL: URL,
        textureQuality: TextureQualityProfile
    ) -> Data? {
        guard let originalImage = UIImage(contentsOfFile: sourceURL.path) else {
            return nil
        }

        let normalizedImage = resizedImageIfNeeded(
            image: originalImage,
            maxDimension: textureQuality.maxDimension
        )

        return normalizedImage.jpegData(compressionQuality: textureQuality.jpegQuality)
    }

    private func resizedImageIfNeeded(image: UIImage, maxDimension: CGFloat) -> UIImage {
        let width = image.size.width
        let height = image.size.height
        let largest = max(width, height)
        guard largest > maxDimension, maxDimension > 0 else {
            return image
        }

        let ratio = maxDimension / largest
        let targetSize = CGSize(
            width: max(1, floor(width * ratio)),
            height: max(1, floor(height * ratio))
        )
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1.0
        let renderer = UIGraphicsImageRenderer(size: targetSize, format: format)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: targetSize))
        }
    }

    private func sampleImagePathsForProcessing(
        imagePaths: [String],
        textureQuality: TextureQualityProfile,
        outputFormat: OutputFormat
    ) -> [String] {
        guard imagePaths.count > 3 else { return imagePaths }

        let maxCount: Int = {
            switch textureQuality.label.lowercased() {
            case "low":
                return outputFormat == .obj ? 8 : 10
            case "high":
                return outputFormat == .obj ? 14 : 16
            default:
                return outputFormat == .obj ? 10 : 12
            }
        }()

        guard imagePaths.count > maxCount else { return imagePaths }

        let lastIndex = imagePaths.count - 1
        let step = Double(lastIndex) / Double(maxCount - 1)
        var sampled: [String] = []
        sampled.reserveCapacity(maxCount)

        for i in 0..<maxCount {
            let index = Int((Double(i) * step).rounded())
            let clamped = min(max(index, 0), lastIndex)
            sampled.append(imagePaths[clamped])
        }

        // Deduplicate while preserving order.
        var seen = Set<String>()
        return sampled.filter { path in
            if seen.contains(path) { return false }
            seen.insert(path)
            return true
        }
    }

    @available(iOS 17.0, *)
    private func runPhotogrammetry(
        inputDirectory: URL,
        outputModelURL: URL,
        operationId: String?,
        options: PhotogrammetryRunOptions
    ) async throws -> URL {
        if FileManager.default.fileExists(atPath: outputModelURL.path) {
            try? FileManager.default.removeItem(at: outputModelURL)
        }

        var config = PhotogrammetrySession.Configuration()
        config.sampleOrdering = options.sampleOrdering
        config.featureSensitivity = options.featureSensitivity
        config.isObjectMaskingEnabled = options.useObjectMasking

        let photogrammetry = try PhotogrammetrySession(
            input: inputDirectory,
            configuration: config
        )
        let request = PhotogrammetrySession.Request.modelFile(
            url: outputModelURL,
            detail: options.detail
        )

        try photogrammetry.process(requests: [request])
        emitProgress(
            operationId: operationId,
            stage: "processing",
            message: "Photogrammetry started...",
            progress: 0.08,
            stepIndex: 3,
            stepLabel: "Analyzing Photos"
        )

        var generatedURL: URL?
        var requestCompleted = false
        let requestStartDate = Date()
        var processingCompleteDate: Date?
        let exportState = ExportProgressState()
        let watchdogState = PhotogrammetryWatchdogState()
        var exportHeartbeatTask: Task<Void, Never>?
        var watchdogTask: Task<Void, Never>?

        watchdogTask = Task {
            let maxTotalSeconds = 900
            let maxReconstructionIdleSeconds = 180

            while true {
                try? await Task.sleep(for: .seconds(15))
                let state = await watchdogState.snapshot()
                if state.done { break }

                let now = Date()
                let totalElapsed = Int(now.timeIntervalSince(requestStartDate).rounded())
                let idleElapsed = Int(now.timeIntervalSince(state.lastOutputAt).rounded())

                if totalElapsed >= maxTotalSeconds {
                    let reason = "Photogrammetry exceeded \(maxTotalSeconds)s and was cancelled. Try fewer photos or lower texture quality."
                    await watchdogState.requestCancel(reason: reason)
                    emitProgress(
                        operationId: operationId,
                        stage: "failed",
                        message: reason
                    )
                    photogrammetry.cancel()
                    await watchdogState.markDone()
                    break
                }

                if !state.exportStarted && idleElapsed >= maxReconstructionIdleSeconds {
                    let reason = "Photogrammetry stalled for \(maxReconstructionIdleSeconds)s without progress and was cancelled."
                    await watchdogState.requestCancel(reason: reason)
                    emitProgress(
                        operationId: operationId,
                        stage: "failed",
                        message: reason
                    )
                    photogrammetry.cancel()
                    await watchdogState.markDone()
                    break
                }
            }
        }

        for try await output in photogrammetry.outputs {
            await watchdogState.markOutput()
            switch output {
            case .inputComplete:
                emitProgress(
                    operationId: operationId,
                    stage: "processing",
                    message: "Image ingestion complete. Building geometry...",
                    progress: 0.12,
                    stepIndex: 3,
                    stepLabel: "Analyzing Photos"
                )
            case .requestProgress(_, let fractionComplete):
                emitProgress(
                    operationId: operationId,
                    stage: "processing",
                    message: "Reconstructing model...",
                    progress: fractionComplete,
                    stepIndex: 4,
                    stepLabel: "Reconstructing Geometry"
                )
            case .requestProgressInfo(_, let progressInfo):
                let stageDescription = String(describing: progressInfo.processingStage)
                let stepInfo = pipelineStepInfo(for: stageDescription)
                let etaValue = progressInfo.estimatedRemainingTime.map {
                    Int($0.rounded())
                }
                emitProgress(
                    operationId: operationId,
                    stage: "processing",
                    message: "Step \(stepInfo.index)/\(Self.pipelineTotalSteps): \(stepInfo.label)",
                    etaSeconds: etaValue,
                    stepIndex: stepInfo.index,
                    stepLabel: stepInfo.label
                )
            case .automaticDownsampling:
                emitProgress(
                    operationId: operationId,
                    stage: "info",
                    message: "Input images were downsampled to fit memory limits."
                )
            case .invalidSample(_, let reason):
                emitProgress(
                    operationId: operationId,
                    stage: "info",
                    message: "Skipped invalid sample: \(reason)"
                )
            case .skippedSample(let id):
                emitProgress(
                    operationId: operationId,
                    stage: "info",
                    message: "Skipped sample id \(id)."
                )
            case .stitchingIncomplete:
                emitProgress(
                    operationId: operationId,
                    stage: "info",
                    message: "Stitching incomplete. Output quality may be reduced."
                )
            case .requestComplete(_, let result):
                requestCompleted = true
                await exportState.markDone()
                await watchdogState.markDone()
                exportHeartbeatTask?.cancel()
                exportHeartbeatTask = nil
                if case .modelFile(let modelFileURL) = result {
                    generatedURL = modelFileURL
                }
                emitProgress(
                    operationId: operationId,
                    stage: "finalizing",
                    message: "Finalizing output model...",
                    progress: 0.98,
                    stepIndex: 5,
                    stepLabel: "Finalizing Reconstruction"
                )
            case .requestError(_, let error):
                await exportState.markDone()
                await watchdogState.markDone()
                exportHeartbeatTask?.cancel()
                exportHeartbeatTask = nil
                throw error
            case .processingComplete:
                await watchdogState.markExportStarted()
                processingCompleteDate = Date()
                let exportLabel = options.outputFormat == .obj
                    ? "Exporting OBJ assets..."
                    : "Exporting USDZ file..."
                emitProgress(
                    operationId: operationId,
                    stage: "finalizing",
                    message: "Processing complete. \(exportLabel)",
                    progress: 0.99,
                    stepIndex: 6,
                    stepLabel: "Exporting Model File"
                )
                emitProgress(
                    operationId: operationId,
                    stage: "info",
                    message: options.outputFormat == .obj
                        ? "OBJ export still depends on texture baking and can take time."
                        : "USDZ export can take several minutes for large texture sets."
                )
                exportHeartbeatTask?.cancel()
                exportHeartbeatTask = Task {
                    let maxExportSeconds: Int = options.outputFormat == .obj ? 420 : 600
                    while await !exportState.isDone() {
                        try? await Task.sleep(for: .seconds(15))
                        if await exportState.isDone() { break }
                        guard let started = processingCompleteDate else { continue }
                        let elapsed = Int(Date().timeIntervalSince(started).rounded())
                        if elapsed >= maxExportSeconds {
                            emitProgress(
                                operationId: operationId,
                                stage: "failed",
                                message: "Export exceeded \(maxExportSeconds)s. Cancelling to avoid indefinite stall. Try fewer photos or lower texture quality."
                            )
                            photogrammetry.cancel()
                            await exportState.markDone()
                            break
                        }
                        emitProgress(
                            operationId: operationId,
                            stage: "info",
                            message: options.outputFormat == .obj
                                ? "Still exporting OBJ assets... (\(elapsed)s)"
                                : "Still exporting USDZ file... (\(elapsed)s)"
                        )
                    }
                }
            case .processingCancelled:
                await exportState.markDone()
                await watchdogState.markDone()
                exportHeartbeatTask?.cancel()
                exportHeartbeatTask = nil
                let state = await watchdogState.snapshot()
                if let cancelReason = state.cancelReason, !cancelReason.isEmpty {
                    throw NSError(
                        domain: "ObjectCapture",
                        code: 1011,
                        userInfo: [NSLocalizedDescriptionKey: cancelReason]
                    )
                }
                emitProgress(
                    operationId: operationId,
                    stage: "cancelled",
                    message: "Generation was cancelled."
                )
                throw NSError(
                    domain: "ObjectCapture",
                    code: 1002,
                    userInfo: [NSLocalizedDescriptionKey: "Generation was cancelled."]
                )
            default:
                break
            }
        }
        await exportState.markDone()
        await watchdogState.markDone()
        exportHeartbeatTask?.cancel()
        watchdogTask?.cancel()
        exportHeartbeatTask = nil
        watchdogTask = nil

        if !requestCompleted {
            throw NSError(
                domain: "ObjectCapture",
                code: 1003,
                userInfo: [NSLocalizedDescriptionKey: "Generation ended without producing a model."]
            )
        }

        let rawOutputURL = generatedURL ?? outputModelURL
        guard FileManager.default.fileExists(atPath: rawOutputURL.path) else {
            throw NSError(
                domain: "ObjectCapture",
                code: 1004,
                userInfo: [NSLocalizedDescriptionKey: "Model file was not found after generation."]
            )
        }

        let finalURL = try resolvePreviewableOutputURL(
            outputURL: rawOutputURL,
            outputFormat: options.outputFormat
        )

        let totalSeconds = Int(Date().timeIntervalSince(requestStartDate).rounded())
        if let processingCompleteDate {
            let exportSeconds = Int(Date().timeIntervalSince(processingCompleteDate).rounded())
            let fileSizeBytes = (try? FileManager.default.attributesOfItem(atPath: finalURL.path)[.size] as? NSNumber)?.int64Value ?? 0
            let fileSizeMB = Double(fileSizeBytes) / (1024.0 * 1024.0)
            emitProgress(
                operationId: operationId,
                stage: "info",
                message: String(
                    format: "Export finished in %ds (total %ds). Output size: %.1f MB",
                    exportSeconds,
                    totalSeconds,
                    fileSizeMB
                )
            )
        }

        return finalURL
    }

    private func resolvePreviewableOutputURL(
        outputURL: URL,
        outputFormat: OutputFormat
    ) throws -> URL {
        guard outputFormat == .obj else {
            return outputURL
        }

        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: outputURL.path, isDirectory: &isDirectory)
        guard exists else { return outputURL }
        guard isDirectory.boolValue else {
            return outputURL
        }

        let enumerator = FileManager.default.enumerator(
            at: outputURL,
            includingPropertiesForKeys: nil
        )

        var candidateURL: URL?
        while let item = enumerator?.nextObject() as? URL {
            let ext = item.pathExtension.lowercased()
            if ext == "obj" {
                return item
            }
            if candidateURL == nil && ["usdz", "usdc", "reality"].contains(ext) {
                candidateURL = item
            }
        }

        // Fallback: return any known model artifact if OBJ isn't present.
        if let candidateURL {
            return candidateURL
        }

        // Final fallback: return folder path and let caller surface a clear preview error.
        return outputURL
    }

    private func emitProgress(
        operationId: String?,
        stage: String,
        message: String,
        progress: Double? = nil,
        etaSeconds: Int? = nil,
        stepIndex: Int? = nil,
        stepLabel: String? = nil
    ) {
        DispatchQueue.main.async {
            guard let sink = self.progressEventSink else { return }
            var payload: [String: Any] = [
                "operation": "photogrammetry_from_images",
                "stage": stage,
                "message": message
            ]
            if let operationId, !operationId.isEmpty {
                payload["operationId"] = operationId
            }
            if let progress {
                payload["progress"] = min(max(progress, 0.0), 1.0)
            }
            if let etaSeconds, etaSeconds >= 0 {
                payload["etaSeconds"] = etaSeconds
            }
            if let stepIndex, stepIndex > 0 {
                payload["stepIndex"] = min(stepIndex, Self.pipelineTotalSteps)
                payload["stepTotal"] = Self.pipelineTotalSteps
            }
            if let stepLabel, !stepLabel.isEmpty {
                payload["stepLabel"] = stepLabel
            }
            sink(payload)
        }
    }

    @available(iOS 17.0, *)
    private func parsePhotogrammetryRunOptions(from raw: [String: Any]?) -> PhotogrammetryRunOptions {
        let detailRaw = (raw?["detail"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        // iOS runtime currently supports reduced detail for on-device export here.
        let detail: PhotogrammetrySession.Request.Detail = .reduced
        let requestedDetail = detailRaw ?? "reduced"
        let didFallbackDetail = requestedDetail != "reduced"

        let featureRaw = (raw?["featureSensitivity"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let featureSensitivity: PhotogrammetrySession.Configuration.FeatureSensitivity = {
            switch featureRaw {
            case "high":
                return .high
            case "normal", .none:
                return .normal
            default:
                return .normal
            }
        }()

        let orderingRaw = (raw?["sampleOrdering"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let sampleOrdering: PhotogrammetrySession.Configuration.SampleOrdering = {
            switch orderingRaw {
            case "unordered":
                return .unordered
            case "sequential", .none:
                return .sequential
            default:
                return .sequential
            }
        }()

        let textureQualityRaw = (raw?["textureQuality"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let textureQuality: TextureQualityProfile = {
            switch textureQualityRaw {
            case "low":
                return TextureQualityProfile(
                    maxDimension: 1536,
                    jpegQuality: 0.72,
                    label: "Low"
                )
            case "high":
                return TextureQualityProfile(
                    maxDimension: 3072,
                    jpegQuality: 0.90,
                    label: "High"
                )
            case "medium", .none:
                return TextureQualityProfile(
                    maxDimension: 2048,
                    jpegQuality: 0.82,
                    label: "Medium"
                )
            default:
                return TextureQualityProfile(
                    maxDimension: 2048,
                    jpegQuality: 0.82,
                    label: "Medium"
                )
            }
        }()

        let outputFormatRaw = (raw?["outputFormat"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let outputFormat: OutputFormat = {
            switch outputFormatRaw {
            case "obj":
                return .obj
            case "usdz", .none:
                return .usdz
            default:
                return .usdz
            }
        }()

        let useObjectMasking: Bool = {
            if let boolValue = raw?["useObjectMasking"] as? Bool {
                return boolValue
            }
            if let stringValue = (raw?["useObjectMasking"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased() {
                return stringValue == "true" || stringValue == "1" || stringValue == "yes"
            }
            return false
        }()

        return PhotogrammetryRunOptions(
            detail: detail,
            featureSensitivity: featureSensitivity,
            sampleOrdering: sampleOrdering,
            useObjectMasking: useObjectMasking,
            textureQuality: textureQuality,
            outputFormat: outputFormat,
            requestedDetail: requestedDetail,
            didFallbackDetail: didFallbackDetail
        )
    }

    private func pipelineStepInfo(for stageDescription: String) -> PipelineStepInfo {
        let value = stageDescription.lowercased()

        if value.contains("pre") || value.contains("detect") || value.contains("sample") {
            return PipelineStepInfo(index: 3, label: "Analyzing Photos")
        }
        if value.contains("point") || value.contains("pose") || value.contains("align") {
            return PipelineStepInfo(index: 4, label: "Estimating Camera Poses")
        }
        if value.contains("mesh") || value.contains("surface") {
            return PipelineStepInfo(index: 4, label: "Generating Mesh")
        }
        if value.contains("texture") || value.contains("map") {
            return PipelineStepInfo(index: 5, label: "Building Textures")
        }
        if value.contains("optimi") || value.contains("simplif") {
            return PipelineStepInfo(index: 5, label: "Optimizing Model")
        }
        if value.contains("export") || value.contains("file") {
            return PipelineStepInfo(index: 6, label: "Exporting Model File")
        }
        return PipelineStepInfo(index: 4, label: "Reconstructing Geometry")
    }

    // MARK: - LiDAR Mesh

    private func startLiDARCapture(result: @escaping FlutterResult) {
        guard #available(iOS 14.0, *) else {
            result(FlutterError(code: "UNSUPPORTED",
                                message: "LiDAR scan requires iOS 14.0+.",
                                details: nil))
            return
        }
        guard ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) else {
            result(FlutterError(code: "UNSUPPORTED",
                                message: "LiDAR scanner not available on this device.",
                                details: nil))
            return
        }

        DispatchQueue.main.async {
            guard let rootVC = self.topViewController() else {
                result(FlutterError(code: "NO_VC", message: "No root view controller.", details: nil))
                return
            }

            if #available(iOS 14.0, *) {
                var hostingVC: UIHostingController<LiDARMeshCaptureView>?
                let view = LiDARMeshCaptureView { usdzPath in
                    result(usdzPath)
                    DispatchQueue.main.async {
                        hostingVC?.dismiss(animated: true)
                        hostingVC = nil
                    }
                }
                let vc = UIHostingController(rootView: view)
                vc.modalPresentationStyle = .fullScreen
                vc.isModalInPresentation = true
                hostingVC = vc
                rootVC.present(vc, animated: true)
            }
        }
    }


    // MARK: - RoomPlan

    private func startRoomPlanCapture(result: @escaping FlutterResult) {
        guard #available(iOS 16.0, *) else {
            result(FlutterError(code: "UNSUPPORTED",
                                message: "RoomPlan requires iOS 16.0+.",
                                details: nil))
            return
        }
        guard RoomCaptureSession.isSupported else {
            result(FlutterError(code: "UNSUPPORTED",
                                message: "RoomPlan requires a LiDAR-equipped device.",
                                details: nil))
            return
        }

        DispatchQueue.main.async {
            guard let rootVC = self.topViewController() else {
                result(FlutterError(code: "NO_VC", message: "No root view controller.", details: nil))
                return
            }

            if #available(iOS 16.0, *) {
                var hostingVC: UIHostingController<RoomPlanCaptureView>?
                let view = RoomPlanCaptureView { usdzPath in
                    result(usdzPath)
                    DispatchQueue.main.async {
                        hostingVC?.dismiss(animated: true)
                        hostingVC = nil
                    }
                }
                let vc = UIHostingController(rootView: view)
                vc.modalPresentationStyle = .fullScreen
                vc.isModalInPresentation = true
                hostingVC = vc
                rootVC.present(vc, animated: true)
            }
        }
    }

    // MARK: - Helpers

    private func previewCapturedModel(call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard
            let args = call.arguments as? [String: Any],
            let path = args["path"] as? String,
            !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            result(FlutterError(code: "INVALID_ARGS", message: "Missing mesh file path.", details: nil))
            return
        }

        let fileURL = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            result(FlutterError(code: "FILE_NOT_FOUND", message: "Mesh file does not exist.", details: nil))
            return
        }

        let forcedType = (args["fileType"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let normalizedType: String? = {
            guard let forcedType else { return nil }
            return ["glb", "gltf", "usdz", "obj"].contains(forcedType) ? forcedType : nil
        }()

        DispatchQueue.main.async {
            guard let rootVC = self.topViewController() else {
                result(FlutterError(code: "NO_VC", message: "No root view controller.", details: nil))
                return
            }

            let ext = normalizedType ?? fileURL.pathExtension.lowercased()
            if ext == "glb" || ext == "gltf" || ext == "obj" {
                self.presentSceneModel(fileURL: fileURL, fileType: ext, from: rootVC, result: result)
                return
            }

            self.previewFileURL = fileURL
            let previewController = QLPreviewController()
            previewController.dataSource = self
            previewController.modalPresentationStyle = .fullScreen
            rootVC.present(previewController, animated: true) {
                result(true)
            }
        }
    }

    private func previewRemoteModel(call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard
            let args = call.arguments as? [String: Any],
            let rawURL = args["url"] as? String,
            let remoteURL = URL(string: rawURL),
            let scheme = remoteURL.scheme?.lowercased(),
            (scheme == "http" || scheme == "https")
        else {
            result(FlutterError(code: "INVALID_ARGS", message: "Missing or invalid remote URL.", details: nil))
            return
        }

        let forcedType = (args["fileType"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let normalizedType: String? = {
            guard let forcedType else { return nil }
            return ["glb", "gltf", "usdz", "obj"].contains(forcedType) ? forcedType : nil
        }()

        let providedName = (args["fileName"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let defaultName = remoteURL.lastPathComponent.isEmpty ? "model.usdz" : remoteURL.lastPathComponent
        var fileName = (providedName?.isEmpty == false) ? providedName! : defaultName
        fileName = fileName.replacingOccurrences(of: "/", with: "_")
        if let normalizedType, URL(fileURLWithPath: fileName).pathExtension.isEmpty {
            fileName += ".\(normalizedType)"
        }

        let destinationURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("preview_\(UUID().uuidString)_\(fileName)")

        let task = URLSession.shared.downloadTask(with: remoteURL) { tempURL, _, error in
            if let error = error {
                result(FlutterError(code: "DOWNLOAD_FAILED", message: error.localizedDescription, details: nil))
                return
            }

            guard let tempURL = tempURL else {
                result(FlutterError(code: "DOWNLOAD_FAILED", message: "No file downloaded.", details: nil))
                return
            }

            do {
                if FileManager.default.fileExists(atPath: destinationURL.path) {
                    try FileManager.default.removeItem(at: destinationURL)
                }
                try FileManager.default.moveItem(at: tempURL, to: destinationURL)
            } catch {
                result(FlutterError(code: "FILE_MOVE_FAILED", message: error.localizedDescription, details: nil))
                return
            }

            DispatchQueue.main.async {
                guard let rootVC = self.topViewController() else {
                    result(FlutterError(code: "NO_VC", message: "No root view controller.", details: nil))
                    return
                }

                let ext = normalizedType ?? destinationURL.pathExtension.lowercased()
                if ext == "glb" || ext == "gltf" || ext == "obj" {
                    self.presentSceneModel(fileURL: destinationURL, fileType: ext, from: rootVC, result: result)
                    return
                }

                self.previewFileURL = destinationURL
                let previewController = QLPreviewController()
                previewController.dataSource = self
                previewController.modalPresentationStyle = .fullScreen
                rootVC.present(previewController, animated: true) {
                    result(true)
                }
            }
        }
        task.resume()
    }

    public func numberOfPreviewItems(in controller: QLPreviewController) -> Int {
        return previewFileURL == nil ? 0 : 1
    }

    public func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem {
        return (previewFileURL ?? URL(fileURLWithPath: "/")) as NSURL
    }

    private func presentSceneModel(fileURL: URL, fileType: String, from rootVC: UIViewController, result: @escaping FlutterResult) {
        let viewer = SceneModelPreviewViewController(fileURL: fileURL, fileType: fileType)
        viewer.modalPresentationStyle = .fullScreen
        rootVC.present(viewer, animated: true) {
            result(true)
        }
    }

    private func topViewController() -> UIViewController? {
        guard
            let scene = UIApplication.shared.connectedScenes
                .first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene,
            let window = scene.windows.first(where: { $0.isKeyWindow })
        else { return nil }

        var vc = window.rootViewController
        while let presented = vc?.presentedViewController { vc = presented }
        return vc
    }
}

private final class SceneModelPreviewViewController: UIViewController {
    private let fileURL: URL
    private let fileType: String
    private let sceneView = SCNView(frame: .zero)
    private let messageLabel = UILabel()

    init(fileURL: URL, fileType: String) {
        self.fileURL = fileURL
        self.fileType = fileType
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        setupSceneView()
        setupCloseButton()
        loadModel()
    }

    private func setupSceneView() {
        sceneView.frame = view.bounds
        sceneView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        sceneView.backgroundColor = .black
        sceneView.autoenablesDefaultLighting = true
        sceneView.allowsCameraControl = true
        sceneView.antialiasingMode = .multisampling4X
        view.addSubview(sceneView)
    }

    private func setupCloseButton() {
        let button = UIButton(type: .system)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.setImage(UIImage(systemName: "xmark"), for: .normal)
        button.tintColor = .white
        button.backgroundColor = UIColor.black.withAlphaComponent(0.55)
        button.layer.cornerRadius = 18
        button.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
        view.addSubview(button)

        NSLayoutConstraint.activate([
            button.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
            button.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
            button.widthAnchor.constraint(equalToConstant: 36),
            button.heightAnchor.constraint(equalToConstant: 36),
        ])
    }

    private func loadModel() {
        do {
            let scene: SCNScene
            switch fileType {
            case "glb", "gltf":
                let source = try GLTFSceneSource(path: fileURL.path)
                scene = try source.scene()
            case "obj":
                if let source = SCNSceneSource(url: fileURL, options: nil),
                   let parsedScene = try? source.scene(options: nil) {
                    scene = parsedScene
                    configureOBJMaterials(in: scene)
                } else {
                    throw NSError(domain: "ScenePreview", code: -2, userInfo: [
                        NSLocalizedDescriptionKey: "SceneKit could not parse the OBJ file."
                    ])
                }
            default:
                throw NSError(domain: "ScenePreview", code: -1, userInfo: [
                    NSLocalizedDescriptionKey: "Unsupported file type: \(fileType)"
                ])
            }
            sceneView.scene = scene
            ensureCamera(in: scene)
        } catch {
            showError("Unable to load \(fileType.uppercased()) model.\n\(error.localizedDescription)")
        }
    }

    private func configureOBJMaterials(in scene: SCNScene) {
        scene.rootNode.enumerateChildNodes { node, _ in
            guard let geometry = node.geometry else { return }
            let hasVertexColors = !geometry.sources(for: .color).isEmpty

            if geometry.materials.isEmpty {
                geometry.materials = [SCNMaterial()]
            }

            for material in geometry.materials {
                material.isDoubleSided = true
                material.lightingModel = .blinn
                if hasVertexColors {
                    material.diffuse.contents = UIColor.white
                    material.multiply.contents = UIColor.white
                }
            }
        }
    }

    private func ensureCamera(in scene: SCNScene) {
        let hasCamera = !scene.rootNode.childNodes { node, _ in
            node.camera != nil
        }.isEmpty
        guard !hasCamera else { return }

        let bounds = scene.rootNode.boundingBox
        let minVec = bounds.min
        let maxVec = bounds.max

        let center = SCNVector3(
            (minVec.x + maxVec.x) * 0.5,
            (minVec.y + maxVec.y) * 0.5,
            (minVec.z + maxVec.z) * 0.5
        )
        let sizeX = maxVec.x - minVec.x
        let sizeY = maxVec.y - minVec.y
        let sizeZ = maxVec.z - minVec.z
        let maxSize = max(sizeX, max(sizeY, sizeZ))
        let distance = max(maxSize * 2.3, 0.8)

        let cameraNode = SCNNode()
        cameraNode.camera = SCNCamera()
        cameraNode.position = SCNVector3(center.x, center.y, center.z + distance)
        let lookAt = SCNLookAtConstraint(target: scene.rootNode)
        lookAt.isGimbalLockEnabled = true
        cameraNode.constraints = [lookAt]
        scene.rootNode.addChildNode(cameraNode)
        sceneView.pointOfView = cameraNode
    }

    private func showError(_ message: String) {
        messageLabel.removeFromSuperview()
        messageLabel.translatesAutoresizingMaskIntoConstraints = false
        messageLabel.numberOfLines = 0
        messageLabel.textAlignment = .center
        messageLabel.textColor = .white
        messageLabel.font = .systemFont(ofSize: 14, weight: .medium)
        messageLabel.text = message
        messageLabel.backgroundColor = UIColor.black.withAlphaComponent(0.45)
        messageLabel.layer.cornerRadius = 8
        messageLabel.layer.masksToBounds = true
        messageLabel.setContentHuggingPriority(.required, for: .vertical)
        sceneView.addSubview(messageLabel)

        NSLayoutConstraint.activate([
            messageLabel.leadingAnchor.constraint(equalTo: sceneView.leadingAnchor, constant: 20),
            messageLabel.trailingAnchor.constraint(equalTo: sceneView.trailingAnchor, constant: -20),
            messageLabel.centerYAnchor.constraint(equalTo: sceneView.centerYAnchor),
        ])
    }

    @objc
    private func closeTapped() {
        dismiss(animated: true)
    }
}
