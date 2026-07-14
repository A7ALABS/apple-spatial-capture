import Foundation
import Metal
import os
#if canImport(MsplatCore)
import MsplatCore
#endif

/// Options for on-device Gaussian-splat training, parsed from the
/// method-channel payload.
struct GaussianSplatTrainingOptions {
    var iterations: Int32 = 3000
    var shDegree: Int32 = 3
    var downscaleFactor: Float = 1.0
    var maxImages: Int = 0
    var exportSplatFile: Bool = false
    /// Save a reloadable engine checkpoint next to the splat so the result
    /// can be previewed later. Costs disk space (~700 bytes per gaussian).
    var saveCheckpoint: Bool = true

    static func parse(from raw: [String: Any]?) -> GaussianSplatTrainingOptions {
        var options = GaussianSplatTrainingOptions()
        guard let raw else { return options }
        if let value = raw["iterations"] as? NSNumber {
            options.iterations = Int32(max(100, min(30_000, value.intValue)))
        }
        if let value = raw["shDegree"] as? NSNumber {
            options.shDegree = Int32(max(0, min(3, value.intValue)))
        }
        if let value = raw["downscaleFactor"] as? NSNumber {
            options.downscaleFactor = max(1.0, min(8.0, value.floatValue))
        }
        if let value = raw["maxImages"] as? NSNumber {
            options.maxImages = max(0, value.intValue)
        }
        if let value = raw["exportSplatFile"] as? Bool {
            options.exportSplatFile = value
        }
        if let value = raw["saveCheckpoint"] as? Bool {
            options.saveCheckpoint = value
        }
        return options
    }
}

/// On-device 3D Gaussian Splatting training backed by the vendored msplat
/// engine (https://github.com/rayanht/msplat, Apache 2.0) — fused Metal
/// compute kernels, no Python/CUDA. Trains from a captured dataset's
/// nerfstudio `transforms.json` (or a binary COLMAP model) and writes a
/// standard splat `.ply`.
///
/// Supported on Apple-silicon Macs (macOS 14+). iPhone/iPad support (iOS 16+,
/// Apple GPU family 8) is experimental: the engine was built for desktop
/// memory budgets, so large captures may exhaust memory on phones.
enum GaussianSplatTraining {
    struct Progress {
        let iteration: Int
        let totalIterations: Int
        let splatCount: Int
        let msPerStep: Float
    }

    static let checkpointFileName = "splat_checkpoint.msplat"

    private static let queue = DispatchQueue(
        label: "apple_spatial_capture.gaussian_splat.training",
        qos: .userInitiated
    )
    private static let runningLock = NSLock()
    private static var isRunning = false
    private static var cancelRequested = false

    /// Requests the active training run stop at the next iteration. The run
    /// still exports what it has trained so far and resolves normally with
    /// `cancelled: true`. Returns false when no run is active.
    static func requestCancel() -> Bool {
        runningLock.lock()
        defer { runningLock.unlock() }
        guard isRunning else { return false }
        cancelRequested = true
        return true
    }

    private static func isCancelRequested() -> Bool {
        runningLock.lock()
        defer { runningLock.unlock() }
        return cancelRequested
    }

    static var isSupported: Bool {
        #if canImport(MsplatCore)
        guard #available(iOS 16.0, macOS 14.0, *) else { return false }
        guard metallibPath() != nil else { return false }
        guard let device = MTLCreateSystemDefaultDevice() else { return false }
        #if os(iOS)
        // Experimental on iOS: require a recent Apple GPU so the engine's
        // desktop-sized threadgroups and memory footprint have a chance.
        return device.supportsFamily(.apple8)
        #else
        return device.supportsFamily(.apple7)
        #endif
        #else
        return false
        #endif
    }

    /// What the memory planner decided to feed the engine.
    struct TrainingPlan {
        /// Dataset folder handed to msplat (the original, or a temp folder
        /// with a trimmed manifest referencing the original images).
        let datasetPathForEngine: String
        /// Temp folder to delete after training, when frames were trimmed.
        let temporaryDatasetURL: URL?
        let downscaleFactor: Float
        let usedImageCount: Int
        let totalImageCount: Int
        /// Hard ceiling on live gaussian count during training (0 = unlimited,
        /// used on macOS). On iOS this is derived from the memory left after
        /// images, so densification growth can't jetsam the process.
        let maxGaussians: Int
        /// Human-readable description when the plan deviates from the request.
        let notice: String?
    }

    /// Trains a splat from `datasetPath` and calls back on an arbitrary
    /// queue. On success the payload contains the output splat path and
    /// training statistics. `notice` receives a message when the memory
    /// planner reduces resolution or frame count to fit the device.
    static func train(
        datasetPath: String,
        options: GaussianSplatTrainingOptions,
        notice: @escaping (String) -> Void,
        progress: @escaping (Progress) -> Void,
        completion: @escaping (Result<[String: Any], Error>) -> Void
    ) {
        #if canImport(MsplatCore)
        guard #available(iOS 16.0, macOS 14.0, *), isSupported else {
            completion(.failure(error(
                "Gaussian splat training is not supported on this device."
            )))
            return
        }

        runningLock.lock()
        if isRunning {
            runningLock.unlock()
            completion(.failure(error("A training run is already in progress.")))
            return
        }
        isRunning = true
        cancelRequested = false
        runningLock.unlock()

        // A live viewport session plus a trainer is two full engine
        // instances — enough to jetsam an iPhone. Close any open viewports
        // before training; their render calls will report INVALID_SESSION.
        SplatViewportChannel.closeAllSessions()

        queue.async {
            defer {
                runningLock.lock()
                isRunning = false
                runningLock.unlock()
            }

            let datasetURL = URL(fileURLWithPath: datasetPath)
            do {
                try validateDataset(at: datasetURL)
            } catch {
                completion(.failure(error))
                return
            }

            guard let metallib = metallibPath() else {
                completion(.failure(error("Metal shader library is missing from the plugin bundle.")))
                return
            }
            msplat_set_metallib_path(metallib)

            let plan: TrainingPlan
            do {
                plan = try makeTrainingPlan(datasetURL: datasetURL, options: options)
            } catch {
                completion(.failure(error))
                return
            }
            defer {
                if let temporaryDatasetURL = plan.temporaryDatasetURL {
                    try? FileManager.default.removeItem(at: temporaryDatasetURL)
                }
            }
            if let planNotice = plan.notice {
                notice(planNotice)
            }

            let startDate = Date()
            let dataset = msplat_dataset_create(
                plan.datasetPathForEngine,
                plan.downscaleFactor,
                false,
                8
            )
            guard let dataset else {
                completion(.failure(error("Could not load the dataset.")))
                return
            }
            defer { msplat_dataset_destroy(dataset) }

            let cameraCount = msplat_dataset_num_train(dataset)
            guard cameraCount > 0 else {
                completion(.failure(error("The dataset contains no usable cameras.")))
                return
            }

            var config = msplat_default_config()
            config.iterations = options.iterations
            config.shDegree = options.shDegree
            config.downscaleFactor = plan.downscaleFactor
            // Coarse-to-fine: start at 1/4 resolution and reach full
            // resolution over the first two-thirds of the run.
            config.numDownscales = options.iterations >= 1_500 ? 2 : 0
            config.resolutionSchedule = max(
                1,
                options.iterations / (config.numDownscales + 1)
            )
            config.bgColor = (0, 0, 0)
            #if os(iOS)
            // Slow densification on iPhone: the desktop default keeps splitting
            // gaussians until iterations/2, which at 7000 iterations grows the
            // model far past what the phone can hold. A higher gradient
            // threshold and an earlier screen-size-split cutoff make long runs
            // refine rather than balloon; the ceiling below is the hard guard.
            config.densifyGradThresh = max(config.densifyGradThresh, 0.0004)
            config.stopScreenSizeAt = min(
                config.stopScreenSizeAt,
                Int32(max(1, options.iterations / 3))
            )
            #endif

            let trainer = msplat_trainer_create(dataset, config)
            guard let trainer else {
                completion(.failure(error("Could not initialize the trainer.")))
                return
            }
            defer {
                msplat_trainer_destroy(trainer)
                msplat_cleanup()
            }

            let total = Int(options.iterations)
            let reportEvery = max(1, total / 100)
            var lastStats = MsplatStats(iteration: 0, splatCount: 0, msPerStep: 0)
            var wasCancelled = false
            var hitGaussianLimit = false
            for i in 0..<total {
                if isCancelRequested() {
                    wasCancelled = true
                    break
                }
                lastStats = msplat_trainer_step(trainer)
                // Hard memory guard: a densification round can jump the count,
                // so stop as soon as it reaches the device ceiling and keep
                // what we have rather than let the next round OOM the process.
                if plan.maxGaussians > 0,
                   Int(lastStats.splatCount) >= plan.maxGaussians {
                    hitGaussianLimit = true
                    notice(
                        "Reached this device's splat budget "
                            + "(~\(plan.maxGaussians / 1000)k gaussians) at iteration "
                            + "\(lastStats.iteration); stopping early to protect memory. "
                            + "Train on a Mac for a denser result."
                    )
                    break
                }
                if i % reportEvery == 0 || i == total - 1 {
                    progress(Progress(
                        iteration: Int(lastStats.iteration),
                        totalIterations: total,
                        splatCount: Int(lastStats.splatCount),
                        msPerStep: lastStats.msPerStep
                    ))
                }
            }

            let plyURL = datasetURL.appendingPathComponent("splat.ply")
            msplat_trainer_export_ply(trainer, plyURL.path)
            guard FileManager.default.fileExists(atPath: plyURL.path) else {
                completion(.failure(error("Training finished but the splat file was not written.")))
                return
            }

            var payload: [String: Any] = [
                "splatPath": plyURL.path,
                "iterations": Int(lastStats.iteration),
                "splatCount": Int(lastStats.splatCount),
                "cameraCount": Int(cameraCount),
                "totalImageCount": plan.totalImageCount,
                "downscaleFactor": Double(plan.downscaleFactor),
                "elapsedSeconds": Int(Date().timeIntervalSince(startDate).rounded()),
                "cancelled": wasCancelled,
                "hitGaussianLimit": hitGaussianLimit,
            ]

            if options.exportSplatFile {
                let splatURL = datasetURL.appendingPathComponent("splat.splat")
                msplat_trainer_export_splat(trainer, splatURL.path)
                if FileManager.default.fileExists(atPath: splatURL.path) {
                    payload["splatFilePath"] = splatURL.path
                }
            }

            if options.saveCheckpoint {
                let checkpointURL = datasetURL.appendingPathComponent(Self.checkpointFileName)
                msplat_trainer_save_checkpoint(trainer, checkpointURL.path)
                if FileManager.default.fileExists(atPath: checkpointURL.path) {
                    payload["checkpointPath"] = checkpointURL.path
                }
            }

            completion(.success(payload))
        }
        #else
        completion(.failure(error(
            "Gaussian splat training is not available in this build of the plugin."
        )))
        #endif
    }

    // MARK: - Memory planning

    /// The engine keeps every training image resident as float32 RGB, plus
    /// pyramid levels and cached GPU tensors — roughly 3× the base image.
    private static let bytesPerPixelBudget = 3.0 * 4.0 * 3.0
    /// Never trim below this many views; below it splat quality collapses.
    private static let minPlannedImages = 30
    /// Keep the long image side at or above ~480 px; prefer dropping frames
    /// over dropping below this resolution.
    private static let minLongSidePixels: Float = 480
    /// Peak GPU memory per live gaussian while training: parameters, Adam
    /// moments, gradients and densification scratch, including msplat's
    /// up-to-2x buffer-capacity over-allocation. Deliberately conservative so
    /// the ceiling stays under the real jetsam limit even mid-densification.
    private static let bytesPerTrainingGaussian = 2200.0
    /// Fraction of available headroom to spend on images + model together;
    /// the rest absorbs transient rasterization/gradient buffers and slack.
    private static let trainingFootprintFraction = 0.78
    /// Floor for the gaussian ceiling — below this splats aren't worth it.
    private static let minTrainingGaussians = 120_000

    /// Sizes the run to the device. On iOS the process has a hard jetsam
    /// memory ceiling, so the plan raises the downscale factor (keeping all
    /// views) and then evenly subsamples frames until the estimated image
    /// memory fits the available headroom. On macOS the request is honored
    /// as-is apart from an explicit `maxImages` cap.
    private static func makeTrainingPlan(
        datasetURL: URL,
        options: GaussianSplatTrainingOptions
    ) throws -> TrainingPlan {
        let manifest = try readManifest(datasetURL: datasetURL)
        let totalFrames = manifest.frames.count

        var frameBudget = totalFrames
        if options.maxImages > 0 {
            frameBudget = min(frameBudget, max(minPlannedImages, options.maxImages))
        }
        var factor = options.downscaleFactor
        var notice: String?

        #if os(iOS)
        let memoryBudget = Double(os_proc_available_memory()) * 0.45
        if memoryBudget > 0 {
            let perImageBytes = { (f: Float) -> Double in
                Double(manifest.width / f) * Double(manifest.height / f) * bytesPerPixelBudget
            }
            // Raise the downscale factor first (all views beat resolution for
            // splat quality), but keep the long side at a usable resolution.
            let longSide = Float(max(manifest.width, manifest.height))
            let maxReasonableFactor = max(options.downscaleFactor, longSide / minLongSidePixels)
            let candidates: [Float] = [1, 1.5, 2, 3, 4, 6, 8]
                .filter { $0 >= options.downscaleFactor && $0 <= maxReasonableFactor }
            var fitted = false
            for candidate in candidates
            where perImageBytes(candidate) * Double(frameBudget) <= memoryBudget {
                factor = candidate
                fitted = true
                break
            }
            if !fitted {
                factor = candidates.last ?? max(options.downscaleFactor, maxReasonableFactor)
                let maxFrames = Int(memoryBudget / perImageBytes(factor))
                guard maxFrames >= min(minPlannedImages, frameBudget) else {
                    throw error(
                        "Not enough memory available to train on this device "
                            + "(~\(Int(memoryBudget / 1_048_576)) MB free). Close other apps and retry.",
                        code: "OUT_OF_MEMORY"
                    )
                }
                frameBudget = min(frameBudget, maxFrames)
            }
        }
        #endif

        // Cap live gaussian count to the memory left after images, so
        // densification growth on long (e.g. 7000-iteration) runs can't
        // exceed the jetsam limit. Unlimited on macOS.
        var maxGaussians = 0
        #if os(iOS)
        let available = Double(os_proc_available_memory())
        if available > 0 {
            let imageBytes = Double(manifest.width / factor)
                * Double(manifest.height / factor)
                * bytesPerPixelBudget * Double(frameBudget)
            let modelBudget = max(0, available * trainingFootprintFraction - imageBytes)
            maxGaussians = max(minTrainingGaussians,
                               Int(modelBudget / bytesPerTrainingGaussian))
        }
        #endif

        if factor > options.downscaleFactor || frameBudget < totalFrames {
            var parts: [String] = []
            if frameBudget < totalFrames {
                parts.append("\(frameBudget) of \(totalFrames) images")
            } else {
                parts.append("all \(totalFrames) images")
            }
            if factor > 1 {
                parts.append("at 1/\(factorLabel(factor)) resolution")
            }
            notice = "Fitting device memory: training with " + parts.joined(separator: " ")
        }

        if frameBudget >= totalFrames {
            return TrainingPlan(
                datasetPathForEngine: datasetURL.path,
                temporaryDatasetURL: nil,
                downscaleFactor: factor,
                usedImageCount: totalFrames,
                totalImageCount: totalFrames,
                maxGaussians: maxGaussians,
                notice: notice
            )
        }

        let trimmedURL = try writeTrimmedManifest(
            datasetURL: datasetURL,
            manifest: manifest,
            keeping: frameBudget
        )
        return TrainingPlan(
            datasetPathForEngine: trimmedURL.path,
            temporaryDatasetURL: trimmedURL,
            downscaleFactor: factor,
            usedImageCount: frameBudget,
            totalImageCount: totalFrames,
            maxGaussians: maxGaussians,
            notice: notice
        )
    }

    private static func factorLabel(_ factor: Float) -> String {
        factor == factor.rounded()
            ? String(Int(factor))
            : String(format: "%.1f", factor)
    }

    struct Manifest {
        let root: [String: Any]
        let frames: [[String: Any]]
        let width: Float
        let height: Float
    }

    static func readManifest(datasetURL: URL) throws -> Manifest {
        let transformsURL = datasetURL.appendingPathComponent("transforms.json")
        guard FileManager.default.fileExists(atPath: transformsURL.path) else {
            // Binary-COLMAP datasets skip planning; loadable but not trimmable.
            return Manifest(root: [:], frames: [], width: 1920, height: 1440)
        }
        let data = try Data(contentsOf: transformsURL)
        guard
            let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let frames = root["frames"] as? [[String: Any]],
            !frames.isEmpty
        else {
            throw error("transforms.json is malformed or has no frames.")
        }
        let width = (frames.first?["w"] as? NSNumber ?? root["w"] as? NSNumber)?.floatValue ?? 1920
        let height = (frames.first?["h"] as? NSNumber ?? root["h"] as? NSNumber)?.floatValue ?? 1440
        return Manifest(root: root, frames: frames, width: width, height: height)
    }

    /// Writes a temp dataset folder whose transforms.json keeps an evenly
    /// spaced subset of frames, rewriting image and point-cloud paths to
    /// absolute paths into the original dataset (the loader accepts them),
    /// so no images are copied.
    static func writeTrimmedManifest(
        datasetURL: URL,
        manifest: Manifest,
        keeping count: Int
    ) throws -> URL {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("gs_train_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempURL, withIntermediateDirectories: true)

        let total = manifest.frames.count
        let stride = Double(total) / Double(count)
        var selected: [[String: Any]] = []
        selected.reserveCapacity(count)
        for i in 0..<count {
            var frame = manifest.frames[min(total - 1, Int(Double(i) * stride))]
            if let filePath = frame["file_path"] as? String, !filePath.hasPrefix("/") {
                frame["file_path"] = datasetURL.appendingPathComponent(filePath).path
            }
            selected.append(frame)
        }

        var root = manifest.root
        root["frames"] = selected
        if let plyPath = root["ply_file_path"] as? String, !plyPath.hasPrefix("/") {
            root["ply_file_path"] = datasetURL.appendingPathComponent(plyPath).path
        }

        let data = try JSONSerialization.data(withJSONObject: root)
        try data.write(to: tempURL.appendingPathComponent("transforms.json"), options: .atomic)
        return tempURL
    }

    // MARK: - Dataset validation

    /// msplat's C boundary does not catch C++ exceptions, so a malformed
    /// dataset would take down the app. Validate the load-bearing structure
    /// here and fail with a readable error instead.
    private static func validateDataset(at datasetURL: URL) throws {
        var isDirectory: ObjCBool = false
        guard
            FileManager.default.fileExists(atPath: datasetURL.path, isDirectory: &isDirectory),
            isDirectory.boolValue
        else {
            throw error("Dataset folder does not exist: \(datasetURL.path)")
        }

        let transformsURL = datasetURL.appendingPathComponent("transforms.json")
        let colmapBinURL = datasetURL
            .appendingPathComponent("sparse").appendingPathComponent("0")
            .appendingPathComponent("cameras.bin")
        let colmapTextURL = datasetURL
            .appendingPathComponent("sparse").appendingPathComponent("0")
            .appendingPathComponent("cameras.txt")

        if FileManager.default.fileExists(atPath: transformsURL.path) {
            let data = try Data(contentsOf: transformsURL)
            guard
                let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let frames = json["frames"] as? [[String: Any]],
                !frames.isEmpty
            else {
                throw error("transforms.json is malformed or has no frames.")
            }
            return
        }

        if FileManager.default.fileExists(atPath: colmapBinURL.path) {
            return
        }

        if FileManager.default.fileExists(atPath: colmapTextURL.path) {
            throw error(
                "This dataset only has a COLMAP text model, which the training engine cannot read. "
                    + "Capture with the nerfstudio (or both) dataset format to train on device."
            )
        }

        throw error(
            "No trainable dataset found. Expected transforms.json (nerfstudio) or sparse/0/cameras.bin (COLMAP binary)."
        )
    }

    // MARK: - Metal shader library lookup

    /// Finds the vendored msplat metallib in both packagings: Swift Package
    /// Manager (Bundle.module) and CocoaPods (resource bundle).
    static func metallibPath() -> String? {
        #if SWIFT_PACKAGE
        if let path = Bundle.module.path(forResource: "default", ofType: "metallib") {
            return path
        }
        #endif

        let candidates = [Bundle(for: GaussianSplatTrainingBundleToken.self), Bundle.main]
        for bundle in candidates {
            if let resourceBundleURL = bundle.url(
                forResource: "apple_spatial_capture_msplat",
                withExtension: "bundle"
            ),
               let resourceBundle = Bundle(url: resourceBundleURL),
               let path = resourceBundle.path(forResource: "default", ofType: "metallib") {
                return path
            }
            if let path = bundle.path(forResource: "default", ofType: "metallib") {
                return path
            }
        }
        return nil
    }

    /// Key in NSError userInfo carrying a stable machine-readable code that
    /// the plugin surfaces as the FlutterError code (e.g. OUT_OF_MEMORY), so
    /// apps don't have to string-match error messages.
    static let errorCodeKey = "AppleSpatialCaptureErrorCode"

    static func error(_ message: String, code: String? = nil) -> NSError {
        var userInfo: [String: Any] = [NSLocalizedDescriptionKey: message]
        if let code {
            userInfo[errorCodeKey] = code
        }
        return NSError(
            domain: "GaussianSplatTraining",
            code: 3001,
            userInfo: userInfo
        )
    }
}

private final class GaussianSplatTrainingBundleToken {}
