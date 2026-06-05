import Cocoa
import FlutterMacOS
import RealityKit

public class AppleSpatialCapturePlugin: NSObject, FlutterPlugin, FlutterStreamHandler {
    private static let channelName = "apple_spatial_capture"
    private static let progressChannelName = "apple_spatial_capture/progress"
    private static let pipelineTotalSteps = 6
    private var progressEventSink: FlutterEventSink?

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
                imagesDirectory: imagesDirectory
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
        imagesDirectory: URL
    ) throws {
        let supportedExtensions: Set<String> = ["jpg", "jpeg", "heic", "heif", "png", "tif", "tiff"]
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

    private func emitProgress(
        operationId: String?,
        stage: String,
        message: String,
        progress: Double? = nil,
        etaSeconds: Int? = nil,
        elapsedSeconds: Int? = nil,
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
