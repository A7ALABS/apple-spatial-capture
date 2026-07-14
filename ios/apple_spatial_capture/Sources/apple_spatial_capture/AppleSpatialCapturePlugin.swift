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
        // Gaussian-splatting methods are routed together (see the router)
        // so this dispatch stays focused on photogrammetry, LiDAR and RoomPlan.
        if handleGaussianSplatMethod(call, result: result) { return }

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

    // MARK: - Gaussian Splat routing

    /// Routes every Gaussian-splatting method — dataset capture, training,
    /// full-screen preview, and the embedded viewport channel — in one place,
    /// so the main dispatch stays focused on photogrammetry, LiDAR and
    /// RoomPlan. Returns true when `call` was a splat method and has been
    /// answered via `result`.
    private func handleGaussianSplatMethod(
        _ call: FlutterMethodCall,
        result: @escaping FlutterResult
    ) -> Bool {
        switch call.method {
        case "isGaussianSplatCaptureSupported":
            if #available(iOS 14.0, *) {
                result(ARWorldTrackingConfiguration.isSupported)
            } else {
                result(false)
            }
        case "startGaussianSplatCapture":
            startGaussianSplatCapture(call: call, result: result)
        case "shareGaussianSplatDataset":
            shareGaussianSplatDataset(call: call, result: result)
        case "isGaussianSplatTrainingSupported":
            result(GaussianSplatTraining.isSupported)
        case "listGaussianSplatDatasets":
            result(Self.listGaussianSplatDatasets())
        case "trainGaussianSplat":
            trainGaussianSplat(call: call, result: result)
        case "cancelGaussianSplatTraining":
            result(GaussianSplatTraining.requestCancel())
        case "previewGaussianSplat":
            previewGaussianSplat(call: call, result: result)
        case "openSplatViewport":
            SplatViewportChannel.open(call, result: result)
        case "openSplatPlyViewport":
            SplatViewportChannel.openPly(call, result: result)
        case "renderSplatViewport":
            SplatViewportChannel.render(call, result: result)
        case "closeSplatViewport":
            SplatViewportChannel.close(call, result: result)
        case "cleanupSplatViewport":
            SplatViewportChannel.cleanup(call, result: result)
        case "cropSplatViewport":
            SplatViewportChannel.crop(call, result: result)
        case "snapshotSplatViewport":
            SplatViewportChannel.snapshot(call, result: result)
        case "restoreSplatViewport":
            SplatViewportChannel.restore(call, result: result)
        case "saveSplatViewportEdits":
            SplatViewportChannel.saveEdits(call, result: result)
        default:
            return false
        }
        return true
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
                    DispatchQueue.main.async {
                        let currentHostingVC = hostingVC
                        let finish: () -> Void = {
                            if let path = usdzPath, !path.isEmpty {
                                result(path)
                            } else if let error = captureError, !error.isEmpty {
                                result(FlutterError(code: "CAPTURE_FAILED", message: error, details: nil))
                            } else {
                                result(nil)
                            }
                            hostingVC = nil
                        }

                        guard let currentHostingVC = currentHostingVC else {
                            finish()
                            return
                        }

                        currentHostingVC.dismiss(animated: true) {
                            finish()
                        }
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

        guard rawNormalizedPaths.count >= 3 else {
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
                imagePaths: rawNormalizedPaths,
                imagesDirectory: imagesDirectory
            )
            emitProgress(
                operationId: operationId,
                stage: "ingesting",
                message: "Original images copied for photogrammetry. Starting reconstruction...",
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
        imagesDirectory: URL
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
                .appendingPathExtension(ext)

            if FileManager.default.fileExists(atPath: destinationURL.path) {
                try? FileManager.default.removeItem(at: destinationURL)
            }

            try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
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
            elapsedSeconds: 0,
            stepIndex: 3,
            stepLabel: "Analyzing Photos"
        )

        var generatedURL: URL?
        var requestCompleted = false
        var processingCompleted = false
        let requestStartDate = Date()
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
                        message: reason,
                        elapsedSeconds: totalElapsed
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
                        message: reason,
                        elapsedSeconds: totalElapsed
                    )
                    photogrammetry.cancel()
                    await watchdogState.markDone()
                    break
                }
            }
        }

        outputLoop: for try await output in photogrammetry.outputs {
            await watchdogState.markOutput()
            switch output {
            case .inputComplete:
                emitProgress(
                    operationId: operationId,
                    stage: "processing",
                    message: "Image ingestion complete. Building geometry...",
                    progress: 0.12,
                    elapsedSeconds: elapsedSeconds(since: requestStartDate),
                    stepIndex: 3,
                    stepLabel: "Analyzing Photos"
                )
            case .requestProgress(_, let fractionComplete):
                emitProgress(
                    operationId: operationId,
                    stage: "processing",
                    message: "Reconstructing model...",
                    progress: fractionComplete,
                    elapsedSeconds: elapsedSeconds(since: requestStartDate),
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
                    elapsedSeconds: elapsedSeconds(since: requestStartDate),
                    stepIndex: stepInfo.index,
                    stepLabel: stepInfo.label
                )
            case .automaticDownsampling:
                emitProgress(
                    operationId: operationId,
                    stage: "info",
                    message: "Input images were downsampled to fit memory limits.",
                    elapsedSeconds: elapsedSeconds(since: requestStartDate)
                )
            case .invalidSample(_, let reason):
                emitProgress(
                    operationId: operationId,
                    stage: "info",
                    message: "Skipped invalid sample: \(reason)",
                    elapsedSeconds: elapsedSeconds(since: requestStartDate)
                )
            case .skippedSample(let id):
                emitProgress(
                    operationId: operationId,
                    stage: "info",
                    message: "Skipped sample id \(id).",
                    elapsedSeconds: elapsedSeconds(since: requestStartDate)
                )
            case .stitchingIncomplete:
                emitProgress(
                    operationId: operationId,
                    stage: "info",
                    message: "Stitching incomplete. Output quality may be reduced.",
                    elapsedSeconds: elapsedSeconds(since: requestStartDate)
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
                    stage: "completed",
                    message: "Model file is ready.",
                    progress: 1.0,
                    elapsedSeconds: elapsedSeconds(since: requestStartDate),
                    stepIndex: 6,
                    stepLabel: "Model Ready"
                )
                break outputLoop
            case .requestError(_, let error):
                await exportState.markDone()
                await watchdogState.markDone()
                exportHeartbeatTask?.cancel()
                exportHeartbeatTask = nil
                throw error
            case .processingComplete:
                processingCompleted = true
                generatedURL = generatedURL ?? outputModelURL
                await exportState.markDone()
                await watchdogState.markDone()
                exportHeartbeatTask?.cancel()
                exportHeartbeatTask = nil
                emitProgress(
                    operationId: operationId,
                    stage: "completed",
                    message: "Processing complete. Model file is ready.",
                    progress: 1.0,
                    elapsedSeconds: elapsedSeconds(since: requestStartDate),
                    stepIndex: 6,
                    stepLabel: "Model Ready"
                )
                break outputLoop
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
                    message: "Generation was cancelled.",
                    elapsedSeconds: elapsedSeconds(since: requestStartDate)
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

        if !requestCompleted && !processingCompleted {
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
        if requestCompleted || processingCompleted {
            let fileSizeBytes = (try? FileManager.default.attributesOfItem(atPath: finalURL.path)[.size] as? NSNumber)?.int64Value ?? 0
            let fileSizeMB = Double(fileSizeBytes) / (1024.0 * 1024.0)
            emitProgress(
                operationId: operationId,
                stage: "info",
                message: String(
                    format: "Model finished in %ds. Output size: %.1f MB",
                    totalSeconds,
                    fileSizeMB
                ),
                elapsedSeconds: totalSeconds
            )
        }

        return finalURL
    }

    private func elapsedSeconds(since startDate: Date) -> Int {
        max(0, Int(Date().timeIntervalSince(startDate).rounded()))
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
        elapsedSeconds: Int? = nil,
        stepIndex: Int? = nil,
        stepLabel: String? = nil,
        operation: String = "photogrammetry_from_images"
    ) {
        DispatchQueue.main.async {
            guard let sink = self.progressEventSink else { return }
            var payload: [String: Any] = [
                "operation": operation,
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
            if let elapsedSeconds, elapsedSeconds >= 0 {
                payload["elapsedSeconds"] = elapsedSeconds
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
                return TextureQualityProfile(label: "Low")
            case "high":
                return TextureQualityProfile(label: "High")
            case "medium", .none:
                return TextureQualityProfile(label: "Medium")
            default:
                return TextureQualityProfile(label: "Medium")
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
                    DispatchQueue.main.async {
                        let currentHostingVC = hostingVC
                        let finish: () -> Void = {
                            result(usdzPath)
                            hostingVC = nil
                        }

                        guard let currentHostingVC = currentHostingVC else {
                            finish()
                            return
                        }

                        currentHostingVC.dismiss(animated: true) {
                            finish()
                        }
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


    // MARK: - Gaussian Splat Dataset

    private func startGaussianSplatCapture(call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard #available(iOS 14.0, *) else {
            result(FlutterError(code: "UNSUPPORTED",
                                message: "Gaussian splat capture requires iOS 14.0+.",
                                details: nil))
            return
        }
        guard ARWorldTrackingConfiguration.isSupported else {
            result(FlutterError(code: "UNSUPPORTED",
                                message: "ARKit world tracking is not available on this device.",
                                details: nil))
            return
        }

        let args = call.arguments as? [String: Any]
        let options = GaussianSplatCaptureOptions.parse(from: args?["options"] as? [String: Any])

        DispatchQueue.main.async {
            guard let rootVC = self.topViewController() else {
                result(FlutterError(code: "NO_VC", message: "No root view controller.", details: nil))
                return
            }

            if #available(iOS 14.0, *) {
                var hostingVC: UIHostingController<GaussianSplatCaptureView>?
                let view = GaussianSplatCaptureView(options: options) { payload in
                    DispatchQueue.main.async {
                        let currentHostingVC = hostingVC
                        let finish: () -> Void = {
                            result(payload)
                            hostingVC = nil
                        }

                        guard let currentHostingVC = currentHostingVC else {
                            finish()
                            return
                        }

                        currentHostingVC.dismiss(animated: true) {
                            finish()
                        }
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

    /// Lists captured dataset folders under Documents/GaussianSplatDatasets,
    /// newest first, so apps can offer a picker instead of a typed path.
    static func listGaussianSplatDatasets() -> [String] {
        guard let documentsURL = FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask).first else {
            return []
        }
        let rootURL = documentsURL.appendingPathComponent(
            "GaussianSplatDatasets",
            isDirectory: true
        )
        let keys: [URLResourceKey] = [.isDirectoryKey, .contentModificationDateKey]
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        return contents
            .compactMap { url -> (URL, Date)? in
                guard
                    let values = try? url.resourceValues(forKeys: Set(keys)),
                    values.isDirectory == true
                else { return nil }
                return (url, values.contentModificationDate ?? .distantPast)
            }
            .sorted { $0.1 > $1.1 }
            .map { $0.0.path }
    }

    /// Trains a Gaussian splat on-device from a captured dataset using the
    /// vendored msplat Metal engine, streaming progress over the event
    /// channel. Experimental on iOS.
    private func trainGaussianSplat(call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard
            let args = call.arguments as? [String: Any],
            let datasetPath = (args["datasetPath"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
            !datasetPath.isEmpty
        else {
            result(FlutterError(code: "INVALID_ARGS",
                                message: "Missing dataset path.",
                                details: nil))
            return
        }

        guard GaussianSplatTraining.isSupported else {
            result(FlutterError(code: "UNSUPPORTED",
                                message: "Gaussian splat training is not supported on this device.",
                                details: nil))
            return
        }

        let operationId = (args["operationId"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let options = GaussianSplatTrainingOptions.parse(
            from: args["options"] as? [String: Any]
        )

        let startDate = Date()
        emitProgress(
            operationId: operationId,
            stage: "preparing",
            message: "Loading dataset for splat training...",
            progress: 0.0,
            operation: "gaussian_splat_training"
        )

        GaussianSplatTraining.train(
            datasetPath: datasetPath,
            options: options,
            notice: { [weak self] message in
                self?.emitProgress(
                    operationId: operationId,
                    stage: "info",
                    message: message,
                    operation: "gaussian_splat_training"
                )
            },
            progress: { [weak self] update in
                let fraction = Double(update.iteration) / Double(max(1, update.totalIterations))
                let remaining = Double(update.totalIterations - update.iteration)
                    * Double(update.msPerStep) / 1000.0
                self?.emitProgress(
                    operationId: operationId,
                    stage: "processing",
                    message: "Training splat: \(update.splatCount) gaussians",
                    progress: fraction,
                    etaSeconds: update.msPerStep > 0 ? Int(remaining.rounded()) : nil,
                    elapsedSeconds: self?.elapsedSeconds(since: startDate),
                    operation: "gaussian_splat_training"
                )
            },
            completion: { [weak self] outcome in
                DispatchQueue.main.async {
                    switch outcome {
                    case .success(let payload):
                        self?.emitProgress(
                            operationId: operationId,
                            stage: "completed",
                            message: "Splat training complete.",
                            progress: 1.0,
                            elapsedSeconds: self?.elapsedSeconds(since: startDate),
                            operation: "gaussian_splat_training"
                        )
                        result(payload)
                    case .failure(let error):
                        self?.emitProgress(
                            operationId: operationId,
                            stage: "failed",
                            message: error.localizedDescription,
                            operation: "gaussian_splat_training"
                        )
                        let code = (error as NSError)
                            .userInfo[GaussianSplatTraining.errorCodeKey] as? String
                        result(FlutterError(code: code ?? "TRAINING_FAILED",
                                            message: error.localizedDescription,
                                            details: nil))
                    }
                }
            }
        )
    }

    /// Opens the interactive splat viewer for a trained dataset (renders the
    /// saved training checkpoint through the vendored msplat engine).
    private func previewGaussianSplat(call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard
            let args = call.arguments as? [String: Any],
            let datasetPath = (args["datasetPath"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
            !datasetPath.isEmpty
        else {
            result(FlutterError(code: "INVALID_ARGS",
                                message: "Missing dataset path.",
                                details: nil))
            return
        }

        #if canImport(MsplatCore)
        guard #available(iOS 16.0, *), GaussianSplatPreview.isSupported else {
            result(FlutterError(code: "UNSUPPORTED",
                                message: "Gaussian splat preview is not supported on this device.",
                                details: nil))
            return
        }
        if let validationError = GaussianSplatPreview.validatePreviewable(datasetPath: datasetPath) {
            result(FlutterError(code: "NOT_PREVIEWABLE",
                                message: validationError.localizedDescription,
                                details: nil))
            return
        }

        DispatchQueue.main.async {
            guard let rootVC = self.topViewController() else {
                result(FlutterError(code: "NO_VC", message: "No root view controller.", details: nil))
                return
            }
            let viewer = GaussianSplatPreviewViewController(datasetPath: datasetPath)
            viewer.modalPresentationStyle = .fullScreen
            rootVC.present(viewer, animated: true) {
                result(true)
            }
        }
        #else
        result(FlutterError(code: "UNSUPPORTED",
                            message: "Gaussian splat preview is not available in this build of the plugin.",
                            details: nil))
        #endif
    }

    /// Zips a captured dataset folder and presents the system share sheet
    /// (AirDrop, Files, iCloud Drive, …). Resolves with true when the user
    /// completed a share action, false when the sheet was dismissed.
    private func shareGaussianSplatDataset(call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard
            let args = call.arguments as? [String: Any],
            let rawPath = args["path"] as? String
        else {
            result(FlutterError(code: "INVALID_ARGS",
                                message: "Missing dataset path.",
                                details: nil))
            return
        }

        let path = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        let folderURL = URL(fileURLWithPath: path)
        var isDirectory: ObjCBool = false
        guard
            !path.isEmpty,
            FileManager.default.fileExists(atPath: folderURL.path, isDirectory: &isDirectory),
            isDirectory.boolValue
        else {
            result(FlutterError(code: "FILE_NOT_FOUND",
                                message: "Dataset folder does not exist.",
                                details: nil))
            return
        }

        DispatchQueue.global(qos: .userInitiated).async {
            let zipURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("\(folderURL.lastPathComponent).zip")
            try? FileManager.default.removeItem(at: zipURL)

            // Coordinated "for uploading" reads of a directory hand back a
            // zipped copy — no archiving dependency needed.
            var coordinatorError: NSError?
            var copyError: Error?
            var archived = false
            NSFileCoordinator().coordinate(
                readingItemAt: folderURL,
                options: [.forUploading],
                error: &coordinatorError
            ) { archiveURL in
                do {
                    try FileManager.default.copyItem(at: archiveURL, to: zipURL)
                    archived = true
                } catch {
                    copyError = error
                }
            }

            DispatchQueue.main.async {
                guard archived else {
                    let message = coordinatorError?.localizedDescription
                        ?? copyError?.localizedDescription
                        ?? "Could not archive the dataset."
                    result(FlutterError(code: "ZIP_FAILED", message: message, details: nil))
                    return
                }
                guard let rootVC = self.topViewController() else {
                    result(FlutterError(code: "NO_VC", message: "No root view controller.", details: nil))
                    return
                }

                let activityVC = UIActivityViewController(
                    activityItems: [zipURL],
                    applicationActivities: nil
                )
                activityVC.completionWithItemsHandler = { _, completed, _, activityError in
                    if let activityError {
                        result(FlutterError(code: "SHARE_FAILED",
                                            message: activityError.localizedDescription,
                                            details: nil))
                    } else {
                        result(completed)
                    }
                }
                if let popover = activityVC.popoverPresentationController {
                    popover.sourceView = rootVC.view
                    popover.sourceRect = CGRect(
                        x: rootVC.view.bounds.midX,
                        y: rootVC.view.bounds.midY,
                        width: 1,
                        height: 1
                    )
                    popover.permittedArrowDirections = []
                }
                rootVC.present(activityVC, animated: true)
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
                    DispatchQueue.main.async {
                        let currentHostingVC = hostingVC
                        let finish: () -> Void = {
                            result(usdzPath)
                            hostingVC = nil
                        }

                        guard let currentHostingVC = currentHostingVC else {
                            finish()
                            return
                        }

                        currentHostingVC.dismiss(animated: true) {
                            finish()
                        }
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
