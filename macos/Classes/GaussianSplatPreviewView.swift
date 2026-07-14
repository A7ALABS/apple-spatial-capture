import Foundation
import simd
#if os(iOS)
import UIKit
#else
import AppKit
#endif
#if canImport(MsplatCore)
import MsplatCore
#endif

/// Interactive viewer for a trained Gaussian splat. Reuses the vendored
/// msplat engine as the renderer: the training checkpoint saved next to the
/// splat is reloaded and rendered from an orbit camera driven by drag/pinch
/// gestures. No extra rendering dependency needed.
enum GaussianSplatPreview {
    static var isSupported: Bool { GaussianSplatTraining.isSupported }

    /// Checks a dataset folder has everything needed for preview and returns
    /// a readable error when it doesn't.
    static func validatePreviewable(datasetPath: String) -> Error? {
        let datasetURL = URL(fileURLWithPath: datasetPath)
        var isDirectory: ObjCBool = false
        guard
            FileManager.default.fileExists(atPath: datasetURL.path, isDirectory: &isDirectory),
            isDirectory.boolValue
        else {
            return GaussianSplatTraining.error("Dataset folder does not exist: \(datasetPath)")
        }
        let checkpointURL = datasetURL
            .appendingPathComponent(GaussianSplatTraining.checkpointFileName)
        guard let handle = FileHandle(forReadingAtPath: checkpointURL.path) else {
            return GaussianSplatTraining.error(
                "No trained splat found in this dataset — run training first "
                    + "(with checkpoint saving enabled)."
            )
        }
        defer { try? handle.close() }
        // "MSPL" magic, little-endian — reject anything the engine would
        // refuse (its C boundary would otherwise crash on a corrupt file).
        let header = handle.readData(ofLength: 4)
        guard header == Data([0x4D, 0x53, 0x50, 0x4C]) else {
            return GaussianSplatTraining.error("The saved splat checkpoint is corrupt.")
        }
        return nil
    }
}

#if canImport(MsplatCore)

/// Owns the msplat dataset/trainer handles for a preview and renders poses
/// serially, latest-request-wins.
@available(iOS 16.0, macOS 14.0, *)
final class GaussianSplatPreviewSession {
    let orbitCenter: SIMD3<Float>
    let orbitRadius: Float

    private let dataset: MsplatDataset
    private let trainer: MsplatTrainer
    private let temporaryManifestURL: URL?
    private let renderQueue = DispatchQueue(
        label: "apple_spatial_capture.gaussian_splat.preview",
        qos: .userInteractive
    )
    private var pendingPose: [Float]?
    private var isRendering = false
    private var buffer: [UInt8] = []
    private var renderWidth: Int32 = 0
    private var renderHeight: Int32 = 0
    private var isClosed = false

    /// Loads the checkpoint and prepares a lightweight render context.
    /// Blocking — call off the main thread.
    init(datasetPath: String) throws {
        if let validationError = GaussianSplatPreview.validatePreviewable(datasetPath: datasetPath) {
            throw validationError
        }
        guard let metallib = GaussianSplatTraining.metallibPath() else {
            throw GaussianSplatTraining.error("Metal shader library is missing from the plugin bundle.")
        }
        msplat_set_metallib_path(metallib)

        let datasetURL = URL(fileURLWithPath: datasetPath)
        let manifest = try GaussianSplatTraining.readManifest(datasetURL: datasetURL)
        guard !manifest.frames.isEmpty else {
            throw GaussianSplatTraining.error("The dataset manifest has no cameras to preview with.")
        }

        (orbitCenter, orbitRadius) = Self.estimateOrbit(frames: manifest.frames)

        // The engine eagerly loads every manifest image, so preview through a
        // tiny trimmed manifest: intrinsics come from one camera; only a few
        // small images are decoded.
        let manifestURL = try GaussianSplatTraining.writeTrimmedManifest(
            datasetURL: datasetURL,
            manifest: manifest,
            keeping: min(3, manifest.frames.count)
        )
        temporaryManifestURL = manifestURL
        // Render at roughly 1k on the long side for a crisp preview.
        let longSide = max(manifest.width, manifest.height)
        let downscale = max(1, (longSide / 1024).rounded())

        guard let dataset = msplat_dataset_create(
            manifestURL.path, downscale, false, 8
        ) else {
            try? FileManager.default.removeItem(at: manifestURL)
            throw GaussianSplatTraining.error("Could not load the dataset for preview.")
        }
        guard msplat_dataset_num_train(dataset) > 0 else {
            msplat_dataset_destroy(dataset)
            try? FileManager.default.removeItem(at: manifestURL)
            throw GaussianSplatTraining.error("The dataset contains no usable cameras.")
        }

        var config = msplat_default_config()
        config.bgColor = (0, 0, 0)
        // Render at the cameras' full (downscaled) resolution — the default
        // coarse-to-fine schedule would quarter it at step 0.
        config.numDownscales = 0
        guard let trainer = msplat_trainer_create(dataset, config) else {
            msplat_dataset_destroy(dataset)
            try? FileManager.default.removeItem(at: manifestURL)
            throw GaussianSplatTraining.error("Could not initialize the splat renderer.")
        }

        let checkpointURL = datasetURL
            .appendingPathComponent(GaussianSplatTraining.checkpointFileName)
        msplat_trainer_load_checkpoint(trainer, checkpointURL.path)
        // View/edit sessions never train; free Adam moments (~2/3 of
        // per-gaussian memory) so large splats fit on iPhone.
        msplat_trainer_release_optimizer_state(trainer)

        self.dataset = dataset
        self.trainer = trainer
    }

    /// Renders a standalone `.ply` splat (e.g. one downloaded from the cloud)
    /// with no dataset folder or checkpoint: a synthetic single camera
    /// provides intrinsics, and the orbit is estimated from the gaussians
    /// themselves. View-only. Blocking — call off the main thread.
    init(plyPath: String, width: Int = 1024, height: Int = 768) throws {
        guard let handle = FileHandle(forReadingAtPath: plyPath) else {
            throw GaussianSplatTraining.error("Splat file not found: \(plyPath)")
        }
        // Sniff the "ply" magic instead of trusting the file extension, so
        // downloads with temp names load without a rename — and corrupt
        // files fail here instead of inside the engine's C boundary.
        let magic = handle.readData(ofLength: 3)
        try? handle.close()
        guard magic == Data([0x70, 0x6C, 0x79]) else {
            throw GaussianSplatTraining.error(
                "Not a PLY splat file: \(plyPath)"
            )
        }
        guard let metallib = GaussianSplatTraining.metallibPath() else {
            throw GaussianSplatTraining.error("Metal shader library is missing from the plugin bundle.")
        }
        msplat_set_metallib_path(metallib)

        temporaryManifestURL = nil
        guard let dataset = msplat_dataset_create_synthetic(
            Int32(width), Int32(height), 50.0
        ) else {
            throw GaussianSplatTraining.error("Could not create the splat renderer.")
        }

        var config = msplat_default_config()
        config.bgColor = (0, 0, 0)
        config.numDownscales = 0
        guard let trainer = msplat_trainer_create(dataset, config) else {
            msplat_dataset_destroy(dataset)
            throw GaussianSplatTraining.error("Could not initialize the splat renderer.")
        }
        msplat_trainer_load_ply(trainer, plyPath)
        guard msplat_trainer_splat_count(trainer) > 0 else {
            msplat_trainer_destroy(trainer)
            msplat_dataset_destroy(dataset)
            throw GaussianSplatTraining.error("The splat file contains no gaussians.")
        }
        msplat_trainer_release_optimizer_state(trainer)

        (orbitCenter, orbitRadius) = Self.estimateOrbitFromGaussians(trainer: trainer)

        self.dataset = dataset
        self.trainer = trainer
    }

    var splatCount: Int { Int(msplat_trainer_splat_count(trainer)) }

    /// Renders `pose` (row-major 4×4 camera-to-world, OpenGL convention) and
    /// delivers a CGImage on the main queue. Requests arriving while a frame
    /// is in flight are coalesced to the newest pose.
    func requestRender(pose: [Float], completion: @escaping (CGImage?) -> Void) {
        renderQueue.async { [self] in
            pendingPose = pose
            guard !isRendering else { return }
            isRendering = true
            while let next = pendingPose, !isClosed {
                pendingPose = nil
                let image = renderLocked(pose: next)
                DispatchQueue.main.async { completion(image) }
            }
            isRendering = false
        }
    }

    /// Synchronous render for the Flutter-embedded viewport, whose method
    /// channel needs exactly one frame per call (the Dart side enforces
    /// one-in-flight/latest-wins). Blocking — call off the main thread.
    func renderFrameSync(pose: [Float]) -> CGImage? {
        var image: CGImage?
        renderQueue.sync {
            guard !isClosed else { return }
            image = renderLocked(pose: pose)
        }
        return image
    }

    // ── Editing (Splat Studio) ──────────────────────────────────────────

    /// Removes low-opacity / oversized / non-finite gaussians. Returns the
    /// new gaussian count. Blocking — call off the main thread.
    func cleanupSync(minOpacity: Float, maxWorldScale: Float) -> Int {
        var count = 0
        renderQueue.sync {
            guard !isClosed else { return }
            count = Int(msplat_trainer_cleanup(trainer, minOpacity, maxWorldScale))
        }
        return count
    }

    /// Keeps the `keepFraction` of gaussians closest to the subject
    /// (median center, percentile radius — model space is normalized, so
    /// absolute radii are meaningless). Returns the new gaussian count.
    func cropPercentileSync(keepFraction: Float) -> Int {
        var count = 0
        renderQueue.sync {
            guard !isClosed else { return }
            let n = Int(msplat_trainer_splat_count(trainer))
            guard n > 0 else { return }
            var means = [Float](repeating: 0, count: n * 3)
            let read = Int(msplat_trainer_read_means(trainer, &means, Int32(n)))
            guard read > 0 else { return }
            var center = [Float](repeating: 0, count: 3)
            var axis = [Float](repeating: 0, count: read)
            for a in 0..<3 {
                for i in 0..<read { axis[i] = means[i * 3 + a] }
                axis.sort()
                center[a] = axis[read / 2]
            }
            var distances = [Float]()
            distances.reserveCapacity(read)
            for i in 0..<read {
                let dx = means[i * 3] - center[0]
                let dy = means[i * 3 + 1] - center[1]
                let dz = means[i * 3 + 2] - center[2]
                let d2 = dx * dx + dy * dy + dz * dz
                if d2.isFinite { distances.append(d2) }
            }
            guard !distances.isEmpty else { return }
            distances.sort()
            let clamped = min(max(keepFraction, 0.05), 1.0)
            let index = min(distances.count - 1,
                            Int(Float(distances.count) * clamped))
            let radius = distances[index].squareRoot()
            count = Int(msplat_trainer_crop_sphere(trainer, &center, radius))
        }
        return count
    }

    /// Saves an undo snapshot (full checkpoint) to `path`.
    func snapshotSync(to path: String) {
        renderQueue.sync {
            guard !isClosed else { return }
            msplat_trainer_save_checkpoint(trainer, path)
        }
    }

    /// Restores an undo snapshot. Returns the restored gaussian count.
    func restoreSync(from path: String) -> Int {
        var count = 0
        renderQueue.sync {
            guard !isClosed else { return }
            msplat_trainer_load_checkpoint(trainer, path)
            // Checkpoint loading recreates the Adam optimizer buffers,
            // tripling memory; view/edit sessions never train, so drop them
            // again or the first undo reintroduces the jetsam risk.
            msplat_trainer_release_optimizer_state(trainer)
            count = Int(msplat_trainer_splat_count(trainer))
        }
        return count
    }

    /// Writes the edited scene back into the dataset: splat.ply, the
    /// preview checkpoint, and splat.splat when one already exists.
    func saveEditsSync(datasetPath: String) -> [String: Any] {
        var payload: [String: Any] = [:]
        renderQueue.sync {
            guard !isClosed else { return }
            let root = URL(fileURLWithPath: datasetPath)
            let ply = root.appendingPathComponent("splat.ply")
            msplat_trainer_export_ply(trainer, ply.path)
            let checkpoint = root.appendingPathComponent(
                GaussianSplatTraining.checkpointFileName)
            msplat_trainer_save_checkpoint(trainer, checkpoint.path)
            let splat = root.appendingPathComponent("splat.splat")
            if FileManager.default.fileExists(atPath: splat.path) {
                msplat_trainer_export_splat(trainer, splat.path)
            }
            payload["splatPath"] = ply.path
            payload["splatCount"] = Int(msplat_trainer_splat_count(trainer))
        }
        return payload
    }

    private func renderLocked(pose: [Float]) -> CGImage? {
        if renderWidth == 0 {
            pose.withUnsafeBufferPointer { ptr in
                msplat_trainer_render_pose_to_buffer(
                    trainer, ptr.baseAddress!, 0, nil, &renderWidth, &renderHeight
                )
            }
            guard renderWidth > 0, renderHeight > 0 else { return nil }
            buffer = [UInt8](repeating: 0, count: Int(renderWidth) * Int(renderHeight) * 4)
        }

        var width: Int32 = 0
        var height: Int32 = 0
        pose.withUnsafeBufferPointer { posePtr in
            buffer.withUnsafeMutableBufferPointer { pixelPtr in
                msplat_trainer_render_pose_to_buffer(
                    trainer, posePtr.baseAddress!, 0,
                    pixelPtr.baseAddress!, &width, &height
                )
            }
        }
        guard width > 0, height > 0 else { return nil }

        let data = Data(buffer)
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        return CGImage(
            width: Int(width),
            height: Int(height),
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: Int(width) * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        )
    }

    func close() {
        renderQueue.async { [self] in
            guard !isClosed else { return }
            isClosed = true
            msplat_trainer_destroy(trainer)
            msplat_dataset_destroy(dataset)
            msplat_cleanup()
            if let manifest = temporaryManifestURL {
                try? FileManager.default.removeItem(at: manifest)
            }
        }
    }

    /// Orbit for a standalone splat with no cameras: center is the mean of
    /// the (finite) gaussian positions, radius the mean distance from it.
    private static func estimateOrbitFromGaussians(
        trainer: MsplatTrainer
    ) -> (SIMD3<Float>, Float) {
        let count = Int(msplat_trainer_splat_count(trainer))
        guard count > 0 else { return (SIMD3<Float>(0, 0, 0), 2.5) }
        var means = [Float](repeating: 0, count: count * 3)
        let read = Int(msplat_trainer_read_means(trainer, &means, Int32(count)))
        guard read > 0 else { return (SIMD3<Float>(0, 0, 0), 2.5) }

        var sum = SIMD3<Float>(0, 0, 0)
        var finite = 0
        for i in 0..<read {
            let p = SIMD3(means[i * 3], means[i * 3 + 1], means[i * 3 + 2])
            if p.x.isFinite && p.y.isFinite && p.z.isFinite {
                sum += p
                finite += 1
            }
        }
        guard finite > 0 else { return (SIMD3<Float>(0, 0, 0), 2.5) }
        let center = sum / Float(finite)

        var distSum: Float = 0
        for i in 0..<read {
            let p = SIMD3(means[i * 3], means[i * 3 + 1], means[i * 3 + 2])
            let d = simd_length(p - center)
            if d.isFinite { distSum += d }
        }
        let radius = max(0.5, (distSum / Float(finite)) * 2.5)
        return (center, radius)
    }

    /// Estimates the subject center as the point closest to all camera view
    /// rays (least squares), and the orbit radius as the mean camera
    /// distance from it.
    private static func estimateOrbit(
        frames: [[String: Any]]
    ) -> (SIMD3<Float>, Float) {
        var positions: [SIMD3<Float>] = []
        var forwards: [SIMD3<Float>] = []
        for frame in frames {
            guard
                let matrix = frame["transform_matrix"] as? [[Any]],
                matrix.count == 4
            else { continue }
            func value(_ row: Int, _ column: Int) -> Float {
                (matrix[row][column] as? NSNumber)?.floatValue ?? 0
            }
            positions.append(SIMD3(value(0, 3), value(1, 3), value(2, 3)))
            // Camera looks along -Z of its pose (OpenGL convention).
            forwards.append(-SIMD3(value(0, 2), value(1, 2), value(2, 2)))
        }
        guard positions.count >= 2 else {
            let position = positions.first ?? SIMD3(0, 0, 2)
            return (position + (forwards.first ?? SIMD3(0, 0, -1)) * 1.5, 1.5)
        }

        var lhs = simd_float3x3()
        var rhs = SIMD3<Float>(0, 0, 0)
        let identity = matrix_identity_float3x3
        for (position, forward) in zip(positions, forwards) {
            let direction = simd_normalize(forward)
            let projector = identity - simd_float3x3(
                SIMD3(direction.x * direction.x, direction.x * direction.y, direction.x * direction.z),
                SIMD3(direction.y * direction.x, direction.y * direction.y, direction.y * direction.z),
                SIMD3(direction.z * direction.x, direction.z * direction.y, direction.z * direction.z)
            )
            lhs += projector
            rhs += projector * position
        }
        let center = simd_determinant(lhs) > 1e-6
            ? lhs.inverse * rhs
            : positions.reduce(SIMD3(0, 0, 0), +) / Float(positions.count)
        let radius = positions.map { simd_distance($0, center) }
            .reduce(0, +) / Float(positions.count)
        return (center, max(radius, 0.3))
    }
}

/// Orbit camera state shared by both platform view controllers.
@available(iOS 16.0, macOS 14.0, *)
struct GaussianSplatOrbitCamera {
    var center: SIMD3<Float>
    var azimuth: Float = 0
    var elevation: Float = 0.35
    var distance: Float

    /// Row-major 4×4 camera-to-world in the OpenGL convention msplat expects.
    func pose() -> [Float] {
        let clampedElevation = max(-1.45, min(1.45, elevation))
        let position = center + distance * SIMD3(
            cos(clampedElevation) * sin(azimuth),
            sin(clampedElevation),
            cos(clampedElevation) * cos(azimuth)
        )
        let forward = simd_normalize(center - position)
        let worldUp = SIMD3<Float>(0, 1, 0)
        var right = simd_cross(forward, worldUp)
        if simd_length(right) < 1e-4 {
            right = SIMD3(1, 0, 0)
        }
        right = simd_normalize(right)
        let up = simd_cross(right, forward)

        // Columns: x=right, y=up, z=-forward, t=position; emitted row-major.
        let columns = (right, up, -forward, position)
        return [
            columns.0.x, columns.1.x, columns.2.x, columns.3.x,
            columns.0.y, columns.1.y, columns.2.y, columns.3.y,
            columns.0.z, columns.1.z, columns.2.z, columns.3.z,
            0, 0, 0, 1,
        ]
    }
}

#if os(iOS)

/// Full-screen splat viewer: drag to orbit, pinch to zoom.
@available(iOS 16.0, *)
final class GaussianSplatPreviewViewController: UIViewController {
    private let datasetPath: String
    private var session: GaussianSplatPreviewSession?
    private var camera: GaussianSplatOrbitCamera?
    private let imageView = UIImageView()
    private let statusLabel = UILabel()
    private let spinner = UIActivityIndicatorView(style: .large)

    init(datasetPath: String) {
        self.datasetPath = datasetPath
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        imageView.frame = view.bounds
        imageView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        imageView.contentMode = .scaleAspectFit
        view.addSubview(imageView)

        spinner.color = .white
        spinner.center = view.center
        spinner.autoresizingMask = [
            .flexibleLeftMargin, .flexibleRightMargin,
            .flexibleTopMargin, .flexibleBottomMargin,
        ]
        spinner.startAnimating()
        view.addSubview(spinner)

        statusLabel.textColor = .white
        statusLabel.font = .systemFont(ofSize: 13, weight: .medium)
        statusLabel.textAlignment = .center
        statusLabel.numberOfLines = 0
        statusLabel.frame = CGRect(
            x: 24, y: view.bounds.midY + 44,
            width: view.bounds.width - 48, height: 60
        )
        statusLabel.autoresizingMask = [.flexibleWidth, .flexibleTopMargin, .flexibleBottomMargin]
        view.addSubview(statusLabel)

        let closeButton = UIButton(type: .system)
        closeButton.setImage(UIImage(systemName: "xmark"), for: .normal)
        closeButton.tintColor = .white
        closeButton.backgroundColor = UIColor.black.withAlphaComponent(0.55)
        closeButton.layer.cornerRadius = 18
        closeButton.frame = CGRect(x: 20, y: 60, width: 36, height: 36)
        closeButton.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
        view.addSubview(closeButton)

        view.addGestureRecognizer(
            UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        )
        view.addGestureRecognizer(
            UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        )

        openSession()
    }

    private func openSession() {
        let path = datasetPath
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                let session = try GaussianSplatPreviewSession(datasetPath: path)
                DispatchQueue.main.async {
                    guard let self else { session.close(); return }
                    self.session = session
                    self.camera = GaussianSplatOrbitCamera(
                        center: session.orbitCenter,
                        distance: session.orbitRadius
                    )
                    self.statusLabel.text = "\(session.splatCount) gaussians — drag to orbit, pinch to zoom"
                    self.renderCurrentPose()
                }
            } catch {
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.spinner.stopAnimating()
                    self.statusLabel.text = error.localizedDescription
                }
            }
        }
    }

    private func renderCurrentPose() {
        guard let session, let camera else { return }
        session.requestRender(pose: camera.pose()) { [weak self] image in
            guard let self, let image else { return }
            if self.spinner.isAnimating {
                self.spinner.stopAnimating()
                UIView.animate(
                    withDuration: 0.6,
                    delay: 2.0,
                    options: [],
                    animations: { self.statusLabel.alpha = 0 },
                    completion: nil
                )
            }
            self.imageView.image = UIImage(cgImage: image)
        }
    }

    @objc private func handlePan(_ recognizer: UIPanGestureRecognizer) {
        guard camera != nil else { return }
        let translation = recognizer.translation(in: view)
        recognizer.setTranslation(.zero, in: view)
        camera?.azimuth -= Float(translation.x) * 0.008
        camera?.elevation += Float(translation.y) * 0.008
        renderCurrentPose()
    }

    @objc private func handlePinch(_ recognizer: UIPinchGestureRecognizer) {
        guard let camera else { return }
        self.camera?.distance = max(0.15, camera.distance / Float(recognizer.scale))
        recognizer.scale = 1
        renderCurrentPose()
    }

    @objc private func closeTapped() {
        session?.close()
        session = nil
        dismiss(animated: true)
    }
}

#else

/// macOS splat viewer window content: drag to orbit, scroll to zoom.
@available(macOS 14.0, *)
final class GaussianSplatPreviewViewController: NSViewController {
    private let datasetPath: String
    private var session: GaussianSplatPreviewSession?
    private var camera: GaussianSplatOrbitCamera?
    private let imageView = NSImageView()
    private let statusLabel = NSTextField(labelWithString: "Loading splat…")

    init(datasetPath: String) {
        self.datasetPath = datasetPath
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 960, height: 720))
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor.black.cgColor

        imageView.frame = root.bounds
        imageView.autoresizingMask = [.width, .height]
        imageView.imageScaling = .scaleProportionallyUpOrDown
        root.addSubview(imageView)

        statusLabel.textColor = .white
        statusLabel.alignment = .center
        statusLabel.frame = NSRect(x: 24, y: 20, width: root.bounds.width - 48, height: 20)
        statusLabel.autoresizingMask = [.width, .maxYMargin]
        root.addSubview(statusLabel)

        view = root
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        guard session == nil else { return }
        openSession()
    }

    private func openSession() {
        let path = datasetPath
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                let session = try GaussianSplatPreviewSession(datasetPath: path)
                DispatchQueue.main.async {
                    guard let self else { session.close(); return }
                    self.session = session
                    self.camera = GaussianSplatOrbitCamera(
                        center: session.orbitCenter,
                        distance: session.orbitRadius
                    )
                    self.statusLabel.stringValue =
                        "\(session.splatCount) gaussians — drag to orbit, scroll to zoom"
                    self.renderCurrentPose()
                }
            } catch {
                DispatchQueue.main.async {
                    self?.statusLabel.stringValue = error.localizedDescription
                }
            }
        }
    }

    private func renderCurrentPose() {
        guard let session, let camera else { return }
        session.requestRender(pose: camera.pose()) { [weak self] image in
            guard let self, let image else { return }
            self.imageView.image = NSImage(
                cgImage: image,
                size: NSSize(width: image.width, height: image.height)
            )
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard camera != nil else { return }
        camera?.azimuth -= Float(event.deltaX) * 0.008
        camera?.elevation += Float(event.deltaY) * 0.008
        renderCurrentPose()
    }

    override func scrollWheel(with event: NSEvent) {
        guard let camera else { return }
        let factor = Float(1 - event.scrollingDeltaY * 0.01)
        self.camera?.distance = max(0.15, camera.distance * max(0.5, min(2, factor)))
        renderCurrentPose()
    }

    func closeSession() {
        session?.close()
        session = nil
    }
}

#endif
#endif
