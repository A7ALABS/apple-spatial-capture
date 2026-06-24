import SwiftUI
import ARKit
import RealityKit
import SceneKit
import CoreImage

/// Full-screen LiDAR scanning view. Reconstructs a USDZ mesh on-device and
/// returns its file path via `completion`, or nil on cancel / failure.
@available(iOS 14.0, *)
struct LiDARMeshCaptureView: View {
    let completion: (String?) -> Void

    @StateObject private var coordinator = LiDARCoordinator()
    @State private var isSaving = false
    @State private var exportError: String?

    var body: some View {
        ZStack {
            LiDARARViewRepresentable(coordinator: coordinator)
                .ignoresSafeArea()

            if isSaving {
                savingOverlay
            } else {
                controls
            }
        }
        .onDisappear { coordinator.stop() }
    }

    // MARK: - Subviews

    private var savingOverlay: some View {
        ZStack {
            Color.black.opacity(0.75).ignoresSafeArea()
            VStack(spacing: 20) {
                ProgressView()
                    .progressViewStyle(CircularProgressViewStyle(tint: .white))
                    .scaleEffect(1.5)
                Text("Generating 3D model…")
                    .font(.headline).foregroundColor(.white)
                Text("Building mesh from LiDAR data")
                    .font(.subheadline).foregroundColor(.white.opacity(0.65))
            }
        }
    }

    private var controls: some View {
        VStack(spacing: 0) {
            // Top bar
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
                .padding(.top, 60)
                Spacer()
            }

            // Status badge
            HStack {
                Spacer()
                statusBadge
                Spacer()
            }
            .padding(.top, 16)

            Spacer()

            // Error message
            if let err = exportError {
                Text(err)
                    .font(.footnote)
                    .foregroundColor(.red)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 8)
            }

            // Action button
            if coordinator.meshRegionCount > 0 {
                Button(action: exportMesh) {
                    Label("Generate 3D Model", systemImage: "cube.fill")
                        .font(.headline)
                        .foregroundColor(.white)
                        .padding(.horizontal, 36)
                        .padding(.vertical, 14)
                        .background(Color.blue)
                        .cornerRadius(14)
                }
                .padding(.bottom, 50)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            } else {
                Text("Point camera at the object and slowly move around it")
                    .font(.subheadline)
                    .foregroundColor(.white)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
                    .padding(.vertical, 10)
                    .background(Color.black.opacity(0.55))
                    .cornerRadius(12)
                    .padding(.bottom, 50)
            }
        }
        .animation(.easeInOut(duration: 0.3), value: coordinator.meshRegionCount)
    }

    private var statusBadge: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(coordinator.meshRegionCount > 0 ? Color.green : Color.orange)
                .frame(width: 8, height: 8)
            Text(coordinator.meshRegionCount > 0
                 ? "\(coordinator.meshRegionCount) regions scanned"
                 : "Scanning…")
                .font(.caption)
                .foregroundColor(.white)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(Color.black.opacity(0.55))
        .cornerRadius(20)
    }

    // MARK: - Actions

    private func exportMesh() {
        exportError = nil
        isSaving = true
        let anchors = coordinator.latestMeshAnchors
        // Snapshot the colors accumulated across the whole scan (taken on the
        // main thread; the closure reads an immutable copy off the main thread).
        let colorProvider = coordinator.makeVertexColorProvider()

        DispatchQueue.global(qos: .userInitiated).async {
            let ext = MeshExporter.preferredExportExtension()
            let outputURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("lidar_\(UUID().uuidString).\(ext)")
            do {
                try MeshExporter.export(
                    meshAnchors: anchors,
                    to: outputURL,
                    colorProvider: colorProvider
                )
                DispatchQueue.main.async {
                    completion(outputURL.path)
                }
            } catch {
                print("[LiDAR] Export error: \(error.localizedDescription)")
                DispatchQueue.main.async {
                    isSaving = false
                    exportError = "Export failed: \(error.localizedDescription)"
                }
            }
        }
    }

    private func cancel() {
        coordinator.stop()
        completion(nil)
    }
}

// MARK: - Coordinator

@available(iOS 14.0, *)
final class LiDARCoordinator: NSObject, ObservableObject, ARSessionDelegate {
    @Published var meshRegionCount: Int = 0
    private(set) var latestMeshAnchors: [ARMeshAnchor] = []
    private(set) var latestFrame: ARFrame?
    private(set) var viewportSize: CGSize = .zero
    private(set) var interfaceOrientation: UIInterfaceOrientation = .portrait
    private var meshAnchorsById: [UUID: ARMeshAnchor] = [:]
    private weak var sceneView: ARSCNView?
    private var meshNodesById: [UUID: SCNNode] = [:]
    private var previewColorSampler: LiveFrameColorSampler?
    private var lastSamplerRefreshTime: TimeInterval = 0
    private static let samplerRefreshInterval: TimeInterval = 0.12
    /// Per-vertex scan colors accumulated across all frames, keyed by world
    /// position so they survive ARKit re-meshing. Used to color the export.
    private let colorAccumulator = ColorAccumulator()

    func start(sceneView: ARSCNView) {
        self.sceneView = sceneView
        updateViewportSize(sceneView.bounds.size)
        sceneView.session.delegate = self
        meshAnchorsById = [:]
        meshNodesById = [:]
        latestMeshAnchors = []
        meshRegionCount = 0
        latestFrame = sceneView.session.currentFrame
        previewColorSampler = nil
        lastSamplerRefreshTime = 0
        colorAccumulator.reset()

        let config = ARWorldTrackingConfiguration()
        if ARWorldTrackingConfiguration.supportsSceneReconstruction(.meshWithClassification) {
            config.sceneReconstruction = .meshWithClassification
        } else if ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) {
            config.sceneReconstruction = .mesh
        }
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.smoothedSceneDepth) {
            config.frameSemantics = .smoothedSceneDepth
        }
        config.environmentTexturing = .automatic
        sceneView.scene = SCNScene()
        sceneView.automaticallyUpdatesLighting = true
        sceneView.rendersContinuously = true
        sceneView.session.run(config, options: [.resetTracking, .removeExistingAnchors])
    }

    func stop() {
        sceneView?.session.pause()
        previewColorSampler = nil
    }

    func updateViewportSize(_ size: CGSize) {
        guard size.width > 1, size.height > 1 else { return }
        viewportSize = size
        refreshPreviewColorSampler(force: true)
    }

    // MARK: ARSessionDelegate

    func session(_ session: ARSession, didAdd anchors: [ARAnchor]) {
        updateMeshAnchorsFromAddedOrUpdated(anchors)
    }
    func session(_ session: ARSession, didUpdate anchors: [ARAnchor]) {
        updateMeshAnchorsFromAddedOrUpdated(anchors)
    }
    func session(_ session: ARSession, didRemove anchors: [ARAnchor]) {
        var changed = false
        for anchor in anchors {
            if meshAnchorsById.removeValue(forKey: anchor.identifier) != nil {
                meshNodesById[anchor.identifier]?.removeFromParentNode()
                meshNodesById.removeValue(forKey: anchor.identifier)
                changed = true
            }
        }
        if changed {
            publishMeshAnchorSnapshot()
        }
    }

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        latestFrame = frame
        if let size = sceneView?.bounds.size {
            updateViewportSize(size)
        }
        var orientationChanged = false
        if let orientation = sceneView?.window?.windowScene?.interfaceOrientation {
            orientationChanged = interfaceOrientation != orientation
            interfaceOrientation = orientation
        }
        refreshPreviewColorSampler(force: orientationChanged)
    }

    private func updateMeshAnchorsFromAddedOrUpdated(_ anchors: [ARAnchor]) {
        var changed = false
        for anchor in anchors {
            guard let meshAnchor = anchor as? ARMeshAnchor else { continue }
            meshAnchorsById[meshAnchor.identifier] = meshAnchor
            upsertMeshNode(for: meshAnchor)
            accumulateColors(for: meshAnchor)
            changed = true
        }
        if changed {
            publishMeshAnchorSnapshot()
        }
    }

    /// Folds the current camera frame's colors into the accumulator for the
    /// vertices of `anchor` that are currently visible and depth-consistent.
    /// Called as anchors are added/refined so coverage grows across the scan.
    private func accumulateColors(for anchor: ARMeshAnchor) {
        guard let sampler = previewColorSampler else { return }
        let mesh = anchor.geometry
        let vertexCount = mesh.vertices.count
        let vertexStride = mesh.vertices.stride
        let vertexPointer = mesh.vertices.buffer.contents().advanced(by: mesh.vertices.offset)
        let transform = anchor.transform

        for i in 0..<vertexCount {
            let ptr = vertexPointer.advanced(by: i * vertexStride)
            let x = ptr.load(as: Float.self)
            let y = ptr.advanced(by: MemoryLayout<Float>.size).load(as: Float.self)
            let z = ptr.advanced(by: MemoryLayout<Float>.size * 2).load(as: Float.self)

            let world = transform * SIMD4<Float>(x, y, z, 1)
            let worldPos = SIMD3<Float>(world.x, world.y, world.z)
            guard let sample = sampler.sampleColorAndWeight(worldPosition: worldPos) else { continue }
            colorAccumulator.ingest(color: sample.color, at: worldPos, weight: sample.weight)
        }
    }

    /// Snapshots the accumulated colors into a lock-free lookup for export.
    func makeVertexColorProvider() -> MeshExporter.VertexColorProvider {
        colorAccumulator.makeLookup()
    }

    private func publishMeshAnchorSnapshot() {
        let anchors = Array(meshAnchorsById.values)
        DispatchQueue.main.async {
            self.latestMeshAnchors = anchors
            self.meshRegionCount = anchors.count
        }
    }

    private func upsertMeshNode(for anchor: ARMeshAnchor) {
        let geometry = Self.scnGeometry(
            from: anchor.geometry,
            anchorTransform: anchor.transform,
            colorSampler: previewColorSampler
        )
        let hasVertexColors = !geometry.sources(for: .color).isEmpty
        let material = SCNMaterial()
        material.diffuse.contents = hasVertexColors
            ? UIColor.white
            : UIColor(
                red: 0.15,
                green: 0.68,
                blue: 0.95,
                alpha: 0.45
            )
        if hasVertexColors {
            material.multiply.contents = UIColor.white
        }
        material.isDoubleSided = true
        material.lightingModel = .physicallyBased
        geometry.materials = [material]

        if let node = meshNodesById[anchor.identifier] {
            node.geometry = geometry
            node.simdTransform = anchor.transform
        } else {
            let node = SCNNode(geometry: geometry)
            node.simdTransform = anchor.transform
            sceneView?.scene.rootNode.addChildNode(node)
            meshNodesById[anchor.identifier] = node
        }
    }

    private func refreshPreviewColorSampler(force: Bool = false) {
        guard
            let frame = latestFrame,
            viewportSize.width > 1,
            viewportSize.height > 1
        else {
            previewColorSampler = nil
            return
        }

        if !force, frame.timestamp - lastSamplerRefreshTime < Self.samplerRefreshInterval {
            return
        }

        previewColorSampler = LiveFrameColorSampler(
            frame: frame,
            viewportSize: viewportSize,
            interfaceOrientation: interfaceOrientation
        )
        lastSamplerRefreshTime = frame.timestamp
    }

    private static func scnGeometry(
        from mesh: ARMeshGeometry,
        anchorTransform: simd_float4x4,
        colorSampler: LiveFrameColorSampler?
    ) -> SCNGeometry {
        let vertices = mesh.vertices
        let normals = mesh.normals
        let faces = mesh.faces

        let vertexSource = SCNGeometrySource(
            buffer: vertices.buffer,
            vertexFormat: vertices.format,
            semantic: .vertex,
            vertexCount: vertices.count,
            dataOffset: vertices.offset,
            dataStride: vertices.stride
        )
        let normalSource = SCNGeometrySource(
            buffer: normals.buffer,
            vertexFormat: normals.format,
            semantic: .normal,
            vertexCount: normals.count,
            dataOffset: normals.offset,
            dataStride: normals.stride
        )
        let colorSource = colorSampler.flatMap {
            Self.colorSource(
                for: mesh,
                anchorTransform: anchorTransform,
                sampler: $0
            )
        }

        let indexData = Data(
            bytesNoCopy: faces.buffer.contents(),
            count: faces.buffer.length,
            deallocator: .none
        )
        let element = SCNGeometryElement(
            data: indexData,
            primitiveType: .triangles,
            primitiveCount: faces.count,
            bytesPerIndex: faces.bytesPerIndex
        )
        var sources = [vertexSource, normalSource]
        if let colorSource {
            sources.append(colorSource)
        }
        return SCNGeometry(sources: sources, elements: [element])
    }

    private static func colorSource(
        for mesh: ARMeshGeometry,
        anchorTransform: simd_float4x4,
        sampler: LiveFrameColorSampler
    ) -> SCNGeometrySource? {
        let vertexCount = mesh.vertices.count
        let vertexStride = mesh.vertices.stride
        let vertexPointer = mesh.vertices.buffer.contents().advanced(by: mesh.vertices.offset)
        let fallback: SIMD3<Float> = SIMD3<Float>(0.93, 0.93, 0.93)
        var colors = [Float](repeating: 0, count: vertexCount * 3)
        var sampledAnyColor = false

        for i in 0..<vertexCount {
            let ptr = vertexPointer.advanced(by: i * vertexStride)
            let x = ptr.load(as: Float.self)
            let y = ptr.advanced(by: MemoryLayout<Float>.size).load(as: Float.self)
            let z = ptr.advanced(by: MemoryLayout<Float>.size * 2).load(as: Float.self)

            let local = SIMD4<Float>(x, y, z, 1)
            let world = anchorTransform * local
            let worldPosition = SIMD3<Float>(world.x, world.y, world.z)
            let sampled = sampler.sampleColor(worldPosition: worldPosition)
            let color = sampled ?? fallback
            if sampled != nil { sampledAnyColor = true }

            let base = i * 3
            colors[base] = color.x
            colors[base + 1] = color.y
            colors[base + 2] = color.z
        }

        guard sampledAnyColor else {
            return nil
        }

        let colorData = colors.withUnsafeBytes { Data($0) }
        return SCNGeometrySource(
            data: colorData,
            semantic: .color,
            vectorCount: vertexCount,
            usesFloatComponents: true,
            componentsPerVector: 3,
            bytesPerComponent: MemoryLayout<Float>.size,
            dataOffset: 0,
            dataStride: MemoryLayout<Float>.size * 3
        )
    }
}

private final class LiveFrameColorSampler {
    private static let ciContext = CIContext(options: nil)
    private let frame: ARFrame
    private let viewportSize: CGSize
    private let interfaceOrientation: UIInterfaceOrientation
    private let inverseDisplayTransform: CGAffineTransform
    private let colorPixels: [UInt8]
    private let colorWidth: Int
    private let colorHeight: Int
    private let colorRowBytes: Int
    private let depthValues: [Float]?
    private let depthWidth: Int
    private let depthHeight: Int

    init?(frame: ARFrame?, viewportSize: CGSize, interfaceOrientation: UIInterfaceOrientation) {
        guard
            let frame,
            viewportSize.width > 1,
            viewportSize.height > 1
        else { return nil }

        let normalizedOrientation: UIInterfaceOrientation = interfaceOrientation == .unknown
            ? .portrait
            : interfaceOrientation
        let ciImage = CIImage(cvPixelBuffer: frame.capturedImage)
        guard let cgImage = Self.ciContext.createCGImage(ciImage, from: ciImage.extent) else {
            return nil
        }
        guard let rasterized = Self.rasterizeRGBA(from: cgImage) else { return nil }

        self.frame = frame
        self.viewportSize = viewportSize
        self.interfaceOrientation = normalizedOrientation
        self.inverseDisplayTransform = frame
            .displayTransform(for: normalizedOrientation, viewportSize: viewportSize)
            .inverted()
        self.colorPixels = rasterized.pixels
        self.colorWidth = rasterized.width
        self.colorHeight = rasterized.height
        self.colorRowBytes = rasterized.rowBytes

        if let depth = Self.extractDepthValues(from: frame) {
            self.depthValues = depth.values
            self.depthWidth = depth.width
            self.depthHeight = depth.height
        } else {
            self.depthValues = nil
            self.depthWidth = 0
            self.depthHeight = 0
        }
    }

    /// Live on-screen preview color (no depth gating, to maximize coverage).
    func sampleColor(worldPosition: SIMD3<Float>) -> SIMD3<Float>? {
        guard let projection = projectImagePoint(worldPosition: worldPosition) else {
            return nil
        }
        return colorAt(imagePoint: projection.imagePoint)
    }

    /// Export-quality sample: depth-gated to reject occluded surfaces, returning
    /// a confidence weight (closer surfaces win) for accumulation.
    func sampleColorAndWeight(worldPosition: SIMD3<Float>) -> (color: SIMD3<Float>, weight: Float)? {
        guard let projection = projectImagePoint(worldPosition: worldPosition) else {
            return nil
        }
        guard isDepthConsistent(
            projectedDepth: projection.depthMeters,
            imagePoint: projection.imagePoint
        ) else {
            return nil
        }
        guard let color = colorAt(imagePoint: projection.imagePoint) else { return nil }
        let weight = projection.depthMeters > 0 ? 1.0 / projection.depthMeters : 0
        return (color, weight)
    }

    private func colorAt(imagePoint: CGPoint) -> SIMD3<Float>? {
        let px = max(0, min(colorWidth - 1, Int(imagePoint.x * CGFloat(colorWidth - 1))))
        let py = max(0, min(colorHeight - 1, Int(imagePoint.y * CGFloat(colorHeight - 1))))
        let offset = py * colorRowBytes + (px * 4)
        guard offset + 2 < colorPixels.count else { return nil }

        let r = Float(colorPixels[offset]) / 255.0
        let g = Float(colorPixels[offset + 1]) / 255.0
        let b = Float(colorPixels[offset + 2]) / 255.0
        return SIMD3<Float>(r, g, b)
    }

    private func projectImagePoint(worldPosition: SIMD3<Float>) -> (imagePoint: CGPoint, depthMeters: Float)? {
        let cameraSpace = frame.camera.transform.inverse * SIMD4<Float>(
            worldPosition.x,
            worldPosition.y,
            worldPosition.z,
            1
        )
        // ARKit camera looks toward negative Z in camera space.
        if cameraSpace.z >= 0 { return nil }
        let depthMeters = -cameraSpace.z

        let projected = frame.camera.projectPoint(
            worldPosition,
            orientation: interfaceOrientation,
            viewportSize: viewportSize
        )
        let viewPoint = CGPoint(
            x: projected.x / viewportSize.width,
            y: projected.y / viewportSize.height
        )
        if viewPoint.x < 0 || viewPoint.x > 1 || viewPoint.y < 0 || viewPoint.y > 1 {
            return nil
        }

        let imagePoint = viewPoint.applying(inverseDisplayTransform)
        if imagePoint.x < 0 || imagePoint.x > 1 || imagePoint.y < 0 || imagePoint.y > 1 {
            return nil
        }
        return (imagePoint, depthMeters)
    }

    /// Rejects samples where the projected vertex is farther than the measured
    /// LiDAR depth at that pixel (i.e. the vertex is occluded in this view).
    private func isDepthConsistent(projectedDepth: Float, imagePoint: CGPoint) -> Bool {
        guard
            let depthValues,
            depthWidth > 0,
            depthHeight > 0
        else { return true }

        let dx = max(0, min(depthWidth - 1, Int(imagePoint.x * CGFloat(depthWidth - 1))))
        let dy = max(0, min(depthHeight - 1, Int(imagePoint.y * CGFloat(depthHeight - 1))))
        let idx = dy * depthWidth + dx
        guard idx >= 0, idx < depthValues.count else { return false }

        let sampledDepth = depthValues[idx]
        guard sampledDepth.isFinite, sampledDepth > 0 else { return false }

        return abs(sampledDepth - projectedDepth) <= 0.18
    }

    private static func rasterizeRGBA(from image: CGImage) -> (pixels: [UInt8], width: Int, height: Int, rowBytes: Int)? {
        let width = image.width
        let height = image.height
        let rowBytes = width * 4
        var pixels = [UInt8](repeating: 0, count: rowBytes * height)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo.byteOrder32Big.rawValue
            | CGImageAlphaInfo.premultipliedLast.rawValue

        let didDraw = pixels.withUnsafeMutableBytes { rawBuffer in
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
            else {
                return false
            }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }

        guard didDraw else { return nil }
        return (pixels, width, height, rowBytes)
    }

    private static func extractDepthValues(from frame: ARFrame) -> (values: [Float], width: Int, height: Int)? {
        let depthMap = frame.smoothedSceneDepth?.depthMap ?? frame.sceneDepth?.depthMap
        guard let depthMap else { return nil }

        CVPixelBufferLockBaseAddress(depthMap, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(depthMap, .readOnly) }

        let width = CVPixelBufferGetWidth(depthMap)
        let height = CVPixelBufferGetHeight(depthMap)
        guard width > 0, height > 0 else { return nil }

        let rowBytes = CVPixelBufferGetBytesPerRow(depthMap)
        let stride = rowBytes / MemoryLayout<Float32>.size
        guard
            let base = CVPixelBufferGetBaseAddress(depthMap)?
                .assumingMemoryBound(to: Float32.self)
        else {
            return nil
        }

        var values = [Float](repeating: 0, count: width * height)
        for y in 0..<height {
            let srcRow = base.advanced(by: y * stride)
            let destOffset = y * width
            for x in 0..<width {
                values[destOffset + x] = srcRow[x]
            }
        }
        return (values, width, height)
    }
}

/// Thread-safe accumulation of per-vertex scan colors keyed by a coarse world
/// voxel. Keying by world position (instead of vertex index) means colors
/// survive ARKit's continuous re-meshing, so the whole scan can be colored at
/// export time rather than from a single final frame.
private final class ColorAccumulator {
    private let voxelSize: Float
    // 21 bits per axis packed into a 64-bit key; biased so quantized negative
    // coordinates stay non-negative within a realistic (±~20 m) scan volume.
    private static let bias: Int64 = 1 << 20
    private static let mask: Int64 = (1 << 21) - 1

    private var voxels: [Int64: (color: SIMD3<Float>, weight: Float)] = [:]
    private let lock = NSLock()

    init(voxelSize: Float = 0.02) {
        self.voxelSize = voxelSize
    }

    func ingest(color: SIMD3<Float>, at worldPosition: SIMD3<Float>, weight: Float) {
        let k = Self.key(for: worldPosition, voxelSize: voxelSize)
        lock.lock()
        if let existing = voxels[k] {
            if weight > existing.weight {
                voxels[k] = (color, weight)
            }
        } else {
            voxels[k] = (color, weight)
        }
        lock.unlock()
    }

    func reset() {
        lock.lock()
        voxels.removeAll(keepingCapacity: false)
        lock.unlock()
    }

    /// Returns a lock-free lookup over an immutable snapshot of the grid, safe to
    /// call from a background export thread. Falls back to the 3×3×3 neighborhood
    /// to tolerate sub-voxel drift between accumulation and export transforms.
    func makeLookup() -> (SIMD3<Float>) -> SIMD3<Float>? {
        lock.lock()
        let snapshot = voxels
        lock.unlock()
        let size = voxelSize

        return { pos in
            let qx = Self.quantize(pos.x, voxelSize: size)
            let qy = Self.quantize(pos.y, voxelSize: size)
            let qz = Self.quantize(pos.z, voxelSize: size)

            if let exact = snapshot[Self.pack(qx, qy, qz)] {
                return exact.color
            }
            var best: (color: SIMD3<Float>, weight: Float)?
            for dz in -1...1 {
                for dy in -1...1 {
                    for dx in -1...1 {
                        if dx == 0, dy == 0, dz == 0 { continue }
                        let key = Self.pack(qx + Int64(dx), qy + Int64(dy), qz + Int64(dz))
                        if let candidate = snapshot[key],
                           best == nil || candidate.weight > best!.weight {
                            best = candidate
                        }
                    }
                }
            }
            return best?.color
        }
    }

    private static func quantize(_ value: Float, voxelSize: Float) -> Int64 {
        let q = Int64((value / voxelSize).rounded()) + bias
        return min(max(q, 0), mask)
    }

    private static func pack(_ qx: Int64, _ qy: Int64, _ qz: Int64) -> Int64 {
        let cx = min(max(qx, 0), mask)
        let cy = min(max(qy, 0), mask)
        let cz = min(max(qz, 0), mask)
        return cx | (cy << 21) | (cz << 42)
    }

    private static func key(for position: SIMD3<Float>, voxelSize: Float) -> Int64 {
        pack(
            quantize(position.x, voxelSize: voxelSize),
            quantize(position.y, voxelSize: voxelSize),
            quantize(position.z, voxelSize: voxelSize)
        )
    }
}

// MARK: - UIViewRepresentable

@available(iOS 14.0, *)
struct LiDARARViewRepresentable: UIViewRepresentable {
    let coordinator: LiDARCoordinator

    func makeUIView(context: Context) -> ARSCNView {
        let sceneView = ARSCNView(frame: .zero)
        sceneView.automaticallyUpdatesLighting = true
        sceneView.antialiasingMode = .multisampling4X
        coordinator.start(sceneView: sceneView)
        return sceneView
    }

    func updateUIView(_ uiView: ARSCNView, context: Context) {
        coordinator.updateViewportSize(uiView.bounds.size)
    }
}
