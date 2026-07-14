import Cocoa
import FlutterMacOS
import RealityKit

public class AppleSpatialCapturePlugin: NSObject, FlutterPlugin, FlutterStreamHandler {
    private static let channelName = "apple_spatial_capture"
    private static let progressChannelName = "apple_spatial_capture/progress"
    private static let pipelineTotalSteps = 6
    private var progressEventSink: FlutterEventSink?
    /// Keeps splat preview windows (and their delegates) alive until closed.
    private var splatPreviewWindows: [SplatPreviewWindowContext] = []

    private enum OutputFormat {
        case usdz
        case obj
    }

    private struct PipelineStepInfo {
        let index: Int
        let label: String
    }

    private struct TextureQualityProfile {
        let label: String
    }

    @available(macOS 12.0, *)
    private struct PhotogrammetryRunOptions {
        let detail: PhotogrammetrySession.Request.Detail
        let featureSensitivity: PhotogrammetrySession.Configuration.FeatureSensitivity
        let sampleOrdering: PhotogrammetrySession.Configuration.SampleOrdering
        let useObjectMasking: Bool
        let textureQuality: TextureQualityProfile
        let outputFormat: OutputFormat
    }

    private actor ExportProgressState {
        var done = false

        func markDone() {
            done = true
        }

        func isDone() -> Bool {
            done
        }
    }

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

        func snapshot() -> (
            done: Bool,
            exportStarted: Bool,
            lastOutputAt: Date,
            cancelReason: String?
        ) {
            (done, exportStarted, lastOutputAt, cancelReason)
        }
    }

    public static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(
            name: channelName,
            binaryMessenger: registrar.messenger
        )
        let progressChannel = FlutterEventChannel(
            name: progressChannelName,
            binaryMessenger: registrar.messenger
        )
        let instance = AppleSpatialCapturePlugin()
        registrar.addMethodCallDelegate(instance, channel: channel)
        progressChannel.setStreamHandler(instance)
    }

    public func onListen(
        withArguments arguments: Any?,
        eventSink events: @escaping FlutterEventSink
    ) -> FlutterError? {
        progressEventSink = events
        return nil
    }

    public func onCancel(withArguments arguments: Any?) -> FlutterError? {
        progressEventSink = nil
        return nil
    }

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        // Gaussian-splatting methods are routed together (see the router)
        // so this dispatch stays focused on photogrammetry and previews.
        if handleGaussianSplatMethod(call, result: result) { return }

        switch call.method {
        case "isObjectCaptureSupported", "isSupported":
            if #available(macOS 12.0, *) {
                result(isPhotogrammetryRuntimeSupported())
            } else {
                result(false)
            }

        case "startPhotogrammetryFromImages":
            startPhotogrammetryFromImages(call: call, result: result)

        case "startObjectCapture", "startCapture":
            result(FlutterError(
                code: "UNSUPPORTED",
                message: "Guided Object Capture is available on supported iOS and iPadOS devices. Use photo reconstruction on macOS.",
                details: nil
            ))

        case "isLiDARSupported", "isRoomPlanSupported":
            result(false)

        case "startLiDARCapture":
            result(FlutterError(
                code: "UNSUPPORTED",
                message: "LiDAR mesh capture is available on supported iOS and iPadOS devices.",
                details: nil
            ))

        case "startRoomPlanCapture":
            result(FlutterError(
                code: "UNSUPPORTED",
                message: "RoomPlan capture is available on supported iOS and iPadOS devices.",
                details: nil
            ))

        case "previewCapturedModel":
            previewCapturedModel(call: call, result: result)

        case "previewRemoteModel":
            previewRemoteModel(call: call, result: result)

        default:
            result(FlutterMethodNotImplemented)
        }
    }

    // MARK: - Gaussian Splat routing

    /// Routes every Gaussian-splatting method — training, full-screen
    /// preview, and the embedded viewport channel — in one place. Capture and
    /// sharing are iOS-only and report UNSUPPORTED here. Returns true when
    /// `call` was a splat method and has been answered via `result`.
    private func handleGaussianSplatMethod(
        _ call: FlutterMethodCall,
        result: @escaping FlutterResult
    ) -> Bool {
        switch call.method {
        case "isGaussianSplatCaptureSupported":
            result(false)
        case "startGaussianSplatCapture", "shareGaussianSplatDataset":
            result(FlutterError(
                code: "UNSUPPORTED",
                message: "Gaussian splat dataset capture is available on supported iOS and iPadOS devices.",
                details: nil
            ))
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

    private func startPhotogrammetryFromImages(
        call: FlutterMethodCall,
        result: @escaping FlutterResult
    ) {
        guard #available(macOS 12.0, *) else {
            result(FlutterError(
                code: "UNSUPPORTED",
                message: "Photogrammetry requires macOS 12.0+.",
                details: nil
            ))
            return
        }

        guard isPhotogrammetryRuntimeSupported() else {
            result(FlutterError(
                code: "UNSUPPORTED",
                message: "Photogrammetry is not supported on this Mac.",
                details: nil
            ))
            return
        }

        guard
            let args = call.arguments as? [String: Any],
            let rawImagePaths = args["imagePaths"] as? [String]
        else {
            result(FlutterError(
                code: "INVALID_ARGS",
                message: "Missing selected image paths.",
                details: nil
            ))
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

        guard rawNormalizedPaths.count >= 3 else {
            result(FlutterError(
                code: "INSUFFICIENT_IMAGES",
                message: "Select at least 3 photos to generate a model.",
                details: nil
            ))
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

        if options.useObjectMasking {
            emitProgress(
                operationId: operationId,
                stage: "info",
                message: "Object masking is not applied by the macOS reconstruction path."
            )
        }
        emitProgress(
            operationId: operationId,
            stage: "info",
            message: "Texture quality: \(options.textureQuality.label). Output: \(options.outputFormat == .obj ? "OBJ" : "USDZ")."
        )

        let outputDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("objectcapture_macos_\(UUID().uuidString)", isDirectory: true)
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
            try FileManager.default.createDirectory(
                at: imagesDirectory,
                withIntermediateDirectories: true
            )
            if options.outputFormat == .obj {
                try FileManager.default.createDirectory(
                    at: modelURL,
                    withIntermediateDirectories: true
                )
            }
            try copySelectedImagesToInputDirectory(
                imagePaths: rawNormalizedPaths,
                imagesDirectory: imagesDirectory,
                operationId: operationId
            )
            emitProgress(
                operationId: operationId,
                stage: "ingesting",
                message: "Original images copied for macOS photogrammetry.",
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
            result(FlutterError(
                code: "FILE_PREP_FAILED",
                message: "Could not prepare selected photos: \(error.localizedDescription)",
                details: nil
            ))
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
                self.emitProgress(
                    operationId: operationId,
                    stage: "completed",
                    message: "3D model generated.",
                    progress: 1.0,
                    stepIndex: Self.pipelineTotalSteps,
                    stepLabel: "Completed"
                )
                DispatchQueue.main.async {
                    result(generatedURL.path)
                }
            } catch {
                self.emitProgress(
                    operationId: operationId,
                    stage: "failed",
                    message: error.localizedDescription
                )
                DispatchQueue.main.async {
                    result(FlutterError(
                        code: "PHOTOGRAMMETRY_FAILED",
                        message: error.localizedDescription,
                        details: nil
                    ))
                }
            }
        }
    }

    @available(macOS 12.0, *)
    private func isPhotogrammetryRuntimeSupported() -> Bool {
        if #available(macOS 13.0, *) {
            return PhotogrammetrySession.isSupported
        }
        return true
    }

    private func copySelectedImagesToInputDirectory(
        imagePaths: [String],
        imagesDirectory: URL,
        operationId: String?
    ) throws {
        let supportedExtensions: Set<String> = ["jpg", "jpeg", "heic", "heif", "png", "tif", "tiff"]
        var copiedCount = 0

        for (index, imagePath) in imagePaths.enumerated() {
            let sourceURL = URL(fileURLWithPath: imagePath)
            let didStartAccessing = sourceURL.startAccessingSecurityScopedResource()
            defer {
                if didStartAccessing {
                    sourceURL.stopAccessingSecurityScopedResource()
                }
            }

            do {
                _ = try sourceURL.checkResourceIsReachable()
            } catch {
                emitProgress(
                    operationId: operationId,
                    stage: "info",
                    message: "Could not access \(sourceURL.lastPathComponent): \(error.localizedDescription)"
                )
                continue
            }

            let ext = sourceURL.pathExtension.lowercased()
            guard supportedExtensions.contains(ext) else {
                emitProgress(
                    operationId: operationId,
                    stage: "info",
                    message: "Skipped unsupported file type: \(sourceURL.lastPathComponent)"
                )
                continue
            }

            let destinationURL = imagesDirectory
                .appendingPathComponent(String(format: "image_%04d", index + 1))
                .appendingPathExtension(ext)

            if FileManager.default.fileExists(atPath: destinationURL.path) {
                try? FileManager.default.removeItem(at: destinationURL)
            }

            do {
                try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
            } catch {
                emitProgress(
                    operationId: operationId,
                    stage: "info",
                    message: "Could not copy \(sourceURL.lastPathComponent): \(error.localizedDescription)"
                )
                continue
            }
            copiedCount += 1
        }

        if copiedCount < 3 {
            throw NSError(
                domain: "ObjectCapture",
                code: 1001,
                userInfo: [NSLocalizedDescriptionKey: "Need at least 3 valid image files. Copied \(copiedCount) of \(imagePaths.count) selected file(s)."]
            )
        }
    }

    @available(macOS 12.0, *)
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
                try? await Task.sleep(nanoseconds: 15_000_000_000)
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

        guard requestCompleted || processingCompleted else {
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

        try? FileManager.default.removeItem(at: inputDirectory)

        if requestCompleted || processingCompleted {
            let totalSeconds = Int(Date().timeIntervalSince(requestStartDate).rounded())
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
        let exists = FileManager.default.fileExists(
            atPath: outputURL.path,
            isDirectory: &isDirectory
        )
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

        if let candidateURL {
            return candidateURL
        }

        return outputURL
    }

    private func previewCapturedModel(
        call: FlutterMethodCall,
        result: @escaping FlutterResult
    ) {
        guard
            let args = call.arguments as? [String: Any],
            let path = args["path"] as? String,
            !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            result(FlutterError(
                code: "INVALID_ARGS",
                message: "Missing model file path.",
                details: nil
            ))
            return
        }

        let fileURL = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            result(FlutterError(
                code: "FILE_NOT_FOUND",
                message: "Model file does not exist.",
                details: nil
            ))
            return
        }

        openModel(fileURL: fileURL, result: result)
    }

    private func previewRemoteModel(
        call: FlutterMethodCall,
        result: @escaping FlutterResult
    ) {
        guard
            let args = call.arguments as? [String: Any],
            let rawURL = args["url"] as? String,
            let remoteURL = URL(string: rawURL),
            let scheme = remoteURL.scheme?.lowercased(),
            scheme == "http" || scheme == "https"
        else {
            result(FlutterError(
                code: "INVALID_ARGS",
                message: "Missing or invalid remote URL.",
                details: nil
            ))
            return
        }

        let forcedType = (args["fileType"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let normalizedType: String? = {
            guard let forcedType else { return nil }
            return ["glb", "gltf", "usdz", "obj"].contains(forcedType) ? forcedType : nil
        }()

        let providedName = (args["fileName"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let defaultName = remoteURL.lastPathComponent.isEmpty
            ? "model.usdz"
            : remoteURL.lastPathComponent
        var fileName = (providedName?.isEmpty == false) ? providedName! : defaultName
        fileName = fileName.replacingOccurrences(of: "/", with: "_")
        if let normalizedType, URL(fileURLWithPath: fileName).pathExtension.isEmpty {
            fileName += ".\(normalizedType)"
        }

        let destinationURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("preview_\(UUID().uuidString)_\(fileName)")

        let task = URLSession.shared.downloadTask(with: remoteURL) { tempURL, _, error in
            if let error = error {
                result(FlutterError(
                    code: "DOWNLOAD_FAILED",
                    message: error.localizedDescription,
                    details: nil
                ))
                return
            }

            guard let tempURL = tempURL else {
                result(FlutterError(
                    code: "DOWNLOAD_FAILED",
                    message: "No file downloaded.",
                    details: nil
                ))
                return
            }

            do {
                if FileManager.default.fileExists(atPath: destinationURL.path) {
                    try FileManager.default.removeItem(at: destinationURL)
                }
                try FileManager.default.moveItem(at: tempURL, to: destinationURL)
            } catch {
                result(FlutterError(
                    code: "FILE_MOVE_FAILED",
                    message: error.localizedDescription,
                    details: nil
                ))
                return
            }

            self.openModel(fileURL: destinationURL, result: result)
        }
        task.resume()
    }

    private func openModel(fileURL: URL, result: @escaping FlutterResult) {
        DispatchQueue.main.async {
            let didOpen = NSWorkspace.shared.open(fileURL)
            if didOpen {
                result(true)
            } else {
                result(FlutterError(
                    code: "PREVIEW_FAILED",
                    message: "macOS could not open this model file.",
                    details: nil
                ))
            }
        }
    }

    @available(macOS 12.0, *)
    private func parsePhotogrammetryRunOptions(
        from raw: [String: Any]?
    ) -> PhotogrammetryRunOptions {
        let textureQualityRaw = (raw?["textureQuality"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let detailRaw = (raw?["detail"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let detail: PhotogrammetrySession.Request.Detail = {
            switch detailRaw {
            case "preview":
                return .preview
            case "medium":
                return .medium
            case "full":
                return .full
            case "raw":
                return .raw
            case "reduced":
                return .reduced
            case .none:
                switch textureQualityRaw {
                case "high":
                    return .full
                case "medium":
                    return .medium
                default:
                    return .reduced
                }
            default:
                return .reduced
            }
        }()

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
            outputFormat: outputFormat
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

    /// Lists dataset folders under Documents/GaussianSplatDatasets, newest
    /// first, so apps can offer a picker instead of a typed path.
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

    /// Opens the interactive splat viewer window for a trained dataset
    /// (renders the saved training checkpoint through the vendored msplat
    /// engine).
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
        guard #available(macOS 14.0, *), GaussianSplatPreview.isSupported else {
            result(FlutterError(code: "UNSUPPORTED",
                                message: "Gaussian splat preview requires an Apple-silicon Mac on macOS 14+.",
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
            let viewer = GaussianSplatPreviewViewController(datasetPath: datasetPath)
            let window = NSWindow(contentViewController: viewer)
            window.title = "Gaussian Splat Preview"
            window.setContentSize(NSSize(width: 960, height: 720))
            window.styleMask = [.titled, .closable, .resizable]
            window.isReleasedWhenClosed = false
            let delegate = SplatPreviewWindowDelegate(viewer: viewer) { [weak self] in
                self?.splatPreviewWindows.removeAll { $0.window == window }
            }
            self.splatPreviewWindows.append(
                SplatPreviewWindowContext(window: window, delegate: delegate)
            )
            window.delegate = delegate
            window.center()
            window.makeKeyAndOrderFront(nil)
            result(true)
        }
        #else
        result(FlutterError(code: "UNSUPPORTED",
                            message: "Gaussian splat preview is not available in this build of the plugin.",
                            details: nil))
        #endif
    }

    /// Trains a Gaussian splat from a captured dataset using the vendored
    /// msplat Metal engine, streaming progress over the event channel.
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
                                message: "Gaussian splat training requires an Apple-silicon Mac on macOS 14+.",
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
        NSLog("[AppleSpatialCapture][Photogrammetry] \(stage): \(message)")
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
}

/// Pairs a splat preview window with its delegate so both stay alive for the
/// window's lifetime.
final class SplatPreviewWindowContext {
    let window: NSWindow
    let delegate: NSObject

    init(window: NSWindow, delegate: NSObject) {
        self.window = window
        self.delegate = delegate
    }
}

#if canImport(MsplatCore)
@available(macOS 14.0, *)
final class SplatPreviewWindowDelegate: NSObject, NSWindowDelegate {
    private let viewer: GaussianSplatPreviewViewController
    private let onClose: () -> Void

    init(viewer: GaussianSplatPreviewViewController, onClose: @escaping () -> Void) {
        self.viewer = viewer
        self.onClose = onClose
    }

    func windowWillClose(_ notification: Notification) {
        viewer.closeSession()
        onClose()
    }
}
#endif
