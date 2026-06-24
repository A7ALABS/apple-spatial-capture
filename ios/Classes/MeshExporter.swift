import ARKit
import ModelIO
import Foundation

struct MeshExporter {

    /// Maps a world-space position to an accumulated RGB color, or `nil` when no
    /// color was captured for that location during scanning.
    typealias VertexColorProvider = (SIMD3<Float>) -> SIMD3<Float>?

    static func preferredExportExtension() -> String {
        let candidates = ["usdz", "obj"]
        if let supported = candidates.first(where: { MDLAsset.canExportFileExtension($0) }) {
            return supported
        }
        return "usdz"
    }

    /// Converts an array of `ARMeshAnchor`s into a model file at `outputURL`,
    /// baking per-vertex colors sampled across the whole scan via `colorProvider`.
    ///
    /// Colors are stored as a vertex-color attribute (exported as the USD
    /// `displayColor` primvar). Unlike an external texture, this data is embedded
    /// directly in the geometry, so it survives ModelIO's USDZ packaging and
    /// renders in QuickLook / RealityKit without a separate image file.
    static func export(
        meshAnchors: [ARMeshAnchor],
        to outputURL: URL,
        colorProvider: VertexColorProvider? = nil
    ) throws {
        guard !meshAnchors.isEmpty else {
            throw ExportError.noMeshData
        }

        guard MDLAsset.canExportFileExtension(outputURL.pathExtension) else {
            throw ExportError.unsupportedFormat(outputURL.pathExtension)
        }

        let asset = buildAsset(meshAnchors: meshAnchors, colorProvider: colorProvider)
        do {
            try asset.export(to: outputURL)
        } catch {
            // Surface the real failure instead of silently shipping a colorless
            // model — the previous fallback hid the cause of missing colors.
            print("[LiDAR] Mesh export failed: \(error.localizedDescription)")
            throw error
        }
    }

    private static func buildAsset(
        meshAnchors: [ARMeshAnchor],
        colorProvider: VertexColorProvider?
    ) -> MDLAsset {
        let asset = MDLAsset()
        let allocator = MDLMeshBufferDataAllocator()

        for anchor in meshAnchors {
            let geometry = anchor.geometry

            let vertexCount  = geometry.vertices.count
            let vertexStride = geometry.vertices.stride
            let vertexPtr    = geometry.vertices.buffer.contents()
                .advanced(by: geometry.vertices.offset)
            let vertexBuf = allocator.newBuffer(
                with: Data(bytes: vertexPtr, count: vertexStride * vertexCount),
                type: .vertex
            )

            let normalCount  = geometry.normals.count
            let normalStride = geometry.normals.stride
            let normalPtr    = geometry.normals.buffer.contents()
                .advanced(by: geometry.normals.offset)
            let normalBuf = allocator.newBuffer(
                with: Data(bytes: normalPtr, count: normalStride * normalCount),
                type: .vertex
            )

            let colorResult = makeColorBuffer(
                allocator: allocator,
                vertexPointer: vertexPtr,
                vertexStride: vertexStride,
                vertexCount: vertexCount,
                anchorTransform: anchor.transform,
                colorProvider: colorProvider
            )
            let colorBuf = colorResult.buffer
            let useVertexColors = colorResult.useVertexColors

            let faceCount      = geometry.faces.count
            let bytesPerIndex  = geometry.faces.bytesPerIndex
            let indicesPerFace = geometry.faces.indexCountPerPrimitive
            let indexBuf = allocator.newBuffer(
                with: Data(
                    bytes: geometry.faces.buffer.contents(),
                    count:  bytesPerIndex * indicesPerFace * faceCount
                ),
                type: .index
            )

            let descriptor = MDLVertexDescriptor()

            let posAttr = MDLVertexAttribute()
            posAttr.name        = MDLVertexAttributePosition
            posAttr.format      = .float3
            posAttr.offset      = 0
            posAttr.bufferIndex = 0
            descriptor.attributes[0] = posAttr
            let posLayout = MDLVertexBufferLayout(); posLayout.stride = vertexStride
            descriptor.layouts[0] = posLayout

            let normAttr = MDLVertexAttribute()
            normAttr.name        = MDLVertexAttributeNormal
            normAttr.format      = .float3
            normAttr.offset      = 0
            normAttr.bufferIndex = 1
            descriptor.attributes[1] = normAttr
            let normLayout = MDLVertexBufferLayout(); normLayout.stride = normalStride
            descriptor.layouts[1] = normLayout

            if colorBuf != nil {
                let colorAttr = MDLVertexAttribute()
                colorAttr.name        = MDLVertexAttributeColor
                colorAttr.format      = .float3
                colorAttr.offset      = 0
                colorAttr.bufferIndex = 2
                descriptor.attributes[2] = colorAttr
                let colorLayout = MDLVertexBufferLayout()
                colorLayout.stride = MemoryLayout<Float>.size * 3
                descriptor.layouts[2] = colorLayout
            }

            let indexDepth: MDLIndexBitDepth = bytesPerIndex == 4 ? .uint32 : .uint16
            let material = makeMaterial(useVertexColors: useVertexColors)
            let submesh = MDLSubmesh(
                indexBuffer:  indexBuf,
                indexCount:   faceCount * indicesPerFace,
                indexType:    indexDepth,
                geometryType: .triangles,
                material:     material
            )

            var buffers = [vertexBuf, normalBuf]
            if let colorBuf {
                buffers.append(colorBuf)
            }
            let mesh = MDLMesh(
                vertexBuffers: buffers,
                vertexCount:   vertexCount,
                descriptor:    descriptor,
                submeshes:     [submesh]
            )
            mesh.transform = MDLTransform(matrix: anchor.transform)

            asset.add(mesh)
        }

        return asset
    }

    /// Builds a per-vertex color buffer by looking each world-space vertex up in
    /// the accumulated scan colors. Returns `(nil, false)` when no colors are
    /// available so the mesh exports as plain geometry instead of all-gray.
    private static func makeColorBuffer(
        allocator: MDLMeshBufferDataAllocator,
        vertexPointer: UnsafeMutableRawPointer,
        vertexStride: Int,
        vertexCount: Int,
        anchorTransform: simd_float4x4,
        colorProvider: VertexColorProvider?
    ) -> (buffer: MDLMeshBuffer?, useVertexColors: Bool) {
        guard let colorProvider else {
            return (nil, false)
        }

        let fallback = SIMD3<Float>(0.93, 0.93, 0.93)
        var colors = [Float](repeating: 0, count: vertexCount * 3)
        var sampledAnyColor = false

        for i in 0..<vertexCount {
            let ptr = vertexPointer.advanced(by: i * vertexStride)
            let x = ptr.load(as: Float.self)
            let y = ptr.advanced(by: MemoryLayout<Float>.size).load(as: Float.self)
            let z = ptr.advanced(by: MemoryLayout<Float>.size * 2).load(as: Float.self)

            let world = anchorTransform * SIMD4<Float>(x, y, z, 1)
            let worldPos = SIMD3<Float>(world.x, world.y, world.z)
            let sampled = colorProvider(worldPos)
            let color = sampled ?? fallback
            if sampled != nil { sampledAnyColor = true }

            let base = i * 3
            colors[base]     = color.x
            colors[base + 1] = color.y
            colors[base + 2] = color.z
        }

        guard sampledAnyColor else {
            return (nil, false)
        }

        let colorBuffer = colors.withUnsafeBytes { bytes in
            allocator.newBuffer(with: Data(bytes), type: .vertex)
        }
        return (colorBuffer, true)
    }

    /// LiDAR reconstruction provides geometry only. Add a PBR material whose base
    /// color is white when per-vertex colors are present (so `displayColor` shows
    /// through), or a neutral gray when the scan produced no color data.
    private static func makeMaterial(useVertexColors: Bool) -> MDLMaterial {
        let material = MDLMaterial(name: "LiDARMaterial", scatteringFunction: MDLScatteringFunction())

        let baseColorValue: SIMD4<Float> = useVertexColors
            ? SIMD4<Float>(1.0, 1.0, 1.0, 1.0)
            : SIMD4<Float>(0.93, 0.93, 0.93, 1.0)
        let baseColor = MDLMaterialProperty(
            name: "baseColor",
            semantic: .baseColor,
            float4: baseColorValue
        )
        let roughness = MDLMaterialProperty(
            name: "roughness",
            semantic: .roughness,
            float: 0.78
        )
        let metallic = MDLMaterialProperty(
            name: "metallic",
            semantic: .metallic,
            float: 0.02
        )

        material.setProperty(baseColor)
        material.setProperty(roughness)
        material.setProperty(metallic)
        return material
    }

    enum ExportError: LocalizedError {
        case noMeshData
        case unsupportedFormat(String)

        var errorDescription: String? {
            switch self {
            case .noMeshData:           return "No LiDAR mesh data captured."
            case .unsupportedFormat(let ext): return "Cannot export to .\(ext) on this device."
            }
        }
    }
}
