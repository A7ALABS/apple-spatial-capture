import ARKit
import ModelIO
import Foundation
import UIKit
import CoreImage

struct MeshExporter {

    static func preferredExportExtension() -> String {
        let candidates = ["usdz", "obj"]
        if let supported = candidates.first(where: { MDLAsset.canExportFileExtension($0) }) {
            return supported
        }
        return "usdz"
    }

    /// Converts an array of ARMeshAnchors into a USDZ file at the given URL.
    static func export(
        meshAnchors: [ARMeshAnchor],
        to outputURL: URL,
        frame: ARFrame? = nil,
        viewportSize: CGSize? = nil,
        interfaceOrientation: UIInterfaceOrientation = .portrait
    ) throws {
        guard !meshAnchors.isEmpty else {
            throw ExportError.noMeshData
        }

        guard MDLAsset.canExportFileExtension(outputURL.pathExtension) else {
            throw ExportError.unsupportedFormat(outputURL.pathExtension)
        }

        let exportExtension = outputURL.pathExtension.lowercased()
        let shouldAttemptTexturedExport = ["usdz", "obj"].contains(exportExtension)

        do {
            let asset = buildAsset(
                meshAnchors: meshAnchors,
                includeTextureAndVertexColorData: shouldAttemptTexturedExport,
                outputURL: outputURL,
                frame: frame,
                viewportSize: viewportSize,
                interfaceOrientation: interfaceOrientation
            )
            try asset.export(to: outputURL)
        } catch {
            guard shouldAttemptTexturedExport else { throw error }

            // USDZ export can fail on some devices when textured vertex data is present.
            // Retry using a plain PBR mesh so scan export still succeeds.
            try? FileManager.default.removeItem(at: outputURL)
            let fallbackAsset = buildAsset(
                meshAnchors: meshAnchors,
                includeTextureAndVertexColorData: false,
                outputURL: outputURL,
                frame: nil,
                viewportSize: nil,
                interfaceOrientation: interfaceOrientation
            )
            try fallbackAsset.export(to: outputURL)
        }
    }

    private static func buildAsset(
        meshAnchors: [ARMeshAnchor],
        includeTextureAndVertexColorData: Bool,
        outputURL: URL,
        frame: ARFrame?,
        viewportSize: CGSize?,
        interfaceOrientation: UIInterfaceOrientation
    ) -> MDLAsset {
        let asset = MDLAsset()
        let allocator = MDLMeshBufferDataAllocator()
        let exportExtension = outputURL.pathExtension.lowercased()
        let shouldWriteTextureImage = exportExtension != "obj"
        let sampler = includeTextureAndVertexColorData
            ? FrameColorSampler(
                frame: frame,
                viewportSize: viewportSize ?? .zero,
                interfaceOrientation: interfaceOrientation
            )
            : nil
        let textureURL = shouldWriteTextureImage
            ? sampler?.writeTextureImage(
                nextTo: outputURL,
                baseName: "lidar_texture_\(UUID().uuidString)"
            )
            : nil
        let shouldIncludeUVData = includeTextureAndVertexColorData && textureURL != nil

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

            let colorBufferAndMaterialFlag = makeColorBuffer(
                allocator: allocator,
                vertexPointer: vertexPtr,
                vertexStride: vertexStride,
                vertexCount: vertexCount,
                anchorTransform: anchor.transform,
                sampler: sampler
            )
            let colorBuf = includeTextureAndVertexColorData
                ? colorBufferAndMaterialFlag.buffer
                : nil
            let useVertexColors = includeTextureAndVertexColorData
                ? colorBufferAndMaterialFlag.useVertexColors
                : false
            let uvBuf = shouldIncludeUVData
                ? makeUVBuffer(
                    allocator: allocator,
                    vertexPointer: vertexPtr,
                    vertexStride: vertexStride,
                    vertexCount: vertexCount,
                    anchorTransform: anchor.transform,
                    sampler: sampler
                )
                : nil

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
            posAttr.name       = MDLVertexAttributePosition
            posAttr.format     = .float3
            posAttr.offset     = 0
            posAttr.bufferIndex = 0
            descriptor.attributes[0] = posAttr
            let posLayout = MDLVertexBufferLayout(); posLayout.stride = vertexStride
            descriptor.layouts[0] = posLayout

            let normAttr = MDLVertexAttribute()
            normAttr.name       = MDLVertexAttributeNormal
            normAttr.format     = .float3
            normAttr.offset     = 0
            normAttr.bufferIndex = 1
            descriptor.attributes[1] = normAttr
            let normLayout = MDLVertexBufferLayout(); normLayout.stride = normalStride
            descriptor.layouts[1] = normLayout

            if let colorBuf {
                let colorAttr = MDLVertexAttribute()
                colorAttr.name = MDLVertexAttributeColor
                colorAttr.format = .float3
                colorAttr.offset = 0
                colorAttr.bufferIndex = 2
                descriptor.attributes[2] = colorAttr
                let colorLayout = MDLVertexBufferLayout()
                colorLayout.stride = MemoryLayout<Float>.size * 3
                descriptor.layouts[2] = colorLayout
            }
            if uvBuf != nil {
                let uvAttr = MDLVertexAttribute()
                uvAttr.name = MDLVertexAttributeTextureCoordinate
                uvAttr.format = .float2
                uvAttr.offset = 0
                uvAttr.bufferIndex = 3
                descriptor.attributes[3] = uvAttr
                let uvLayout = MDLVertexBufferLayout()
                uvLayout.stride = MemoryLayout<Float>.size * 2
                descriptor.layouts[3] = uvLayout
            }

            let indexDepth: MDLIndexBitDepth = bytesPerIndex == 4 ? .uint32 : .uint16
            let material = makeMaterial(
                useVertexColors: useVertexColors,
                textureURL: textureURL
            )
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
            if let uvBuf {
                buffers.append(uvBuf)
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

    private static func makeColorBuffer(
        allocator: MDLMeshBufferDataAllocator,
        vertexPointer: UnsafeMutableRawPointer,
        vertexStride: Int,
        vertexCount: Int,
        anchorTransform: simd_float4x4,
        sampler: FrameColorSampler?
    ) -> (buffer: MDLMeshBuffer?, useVertexColors: Bool) {
        guard let sampler else {
            return (nil, false)
        }

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
            let worldPos = SIMD3<Float>(world.x, world.y, world.z)
            let sampled = sampler.sampleColor(worldPosition: worldPos)
            let color = sampled ?? fallback
            if sampled != nil { sampledAnyColor = true }

            let base = i * 3
            colors[base] = color.x
            colors[base + 1] = color.y
            colors[base + 2] = color.z
        }

        let colorBuffer = colors.withUnsafeBytes { bytes in
            allocator.newBuffer(with: Data(bytes), type: .vertex)
        }
        return (colorBuffer, sampledAnyColor)
    }

    private static func makeUVBuffer(
        allocator: MDLMeshBufferDataAllocator,
        vertexPointer: UnsafeMutableRawPointer,
        vertexStride: Int,
        vertexCount: Int,
        anchorTransform: simd_float4x4,
        sampler: FrameColorSampler?
    ) -> MDLMeshBuffer? {
        guard let sampler else { return nil }

        var uvs = [Float](repeating: 0, count: vertexCount * 2)
        for i in 0..<vertexCount {
            let ptr = vertexPointer.advanced(by: i * vertexStride)
            let x = ptr.load(as: Float.self)
            let y = ptr.advanced(by: MemoryLayout<Float>.size).load(as: Float.self)
            let z = ptr.advanced(by: MemoryLayout<Float>.size * 2).load(as: Float.self)

            let world = anchorTransform * SIMD4<Float>(x, y, z, 1)
            let uv = sampler.projectUV(worldPosition: SIMD3<Float>(world.x, world.y, world.z))
                ?? SIMD2<Float>(0.5, 0.5)
            let base = i * 2
            uvs[base] = uv.x
            uvs[base + 1] = uv.y
        }

        return uvs.withUnsafeBytes { bytes in
            allocator.newBuffer(with: Data(bytes), type: .vertex)
        }
    }

    /// LiDAR reconstruction provides geometry only. Add a PBR material and
    /// switch base color strategy depending on whether we baked vertex colors.
    private static func makeMaterial(useVertexColors: Bool, textureURL: URL?) -> MDLMaterial {
        let material = MDLMaterial(name: "LiDARMaterial", scatteringFunction: MDLScatteringFunction())

        let baseColor: MDLMaterialProperty
        if let textureURL {
            let texture = MDLURLTexture(url: textureURL, name: "LiDARTexture")
            let textureSampler = MDLTextureSampler()
            textureSampler.texture = texture
            baseColor = MDLMaterialProperty(
                name: "baseColor",
                semantic: .baseColor,
                textureSampler: textureSampler
            )
        } else {
            let baseColorValue: SIMD4<Float> = useVertexColors
                ? SIMD4<Float>(1.0, 1.0, 1.0, 1.0)
                : SIMD4<Float>(0.93, 0.93, 0.93, 1.0)
            baseColor = MDLMaterialProperty(
                name: "baseColor",
                semantic: .baseColor,
                float4: baseColorValue
            )
        }
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

private final class FrameColorSampler {
    private let frame: ARFrame
    private let viewportSize: CGSize
    private let interfaceOrientation: UIInterfaceOrientation
    private let inverseDisplayTransform: CGAffineTransform
    private let textureImage: CGImage
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
        let ciContext = CIContext(options: nil)
        let ciImage = CIImage(cvPixelBuffer: frame.capturedImage)
        guard let cgImage = ciContext.createCGImage(ciImage, from: ciImage.extent) else {
            return nil
        }
        guard let rasterized = Self.rasterizeRGBA(from: cgImage) else { return nil }

        self.frame = frame
        self.viewportSize = viewportSize
        self.interfaceOrientation = normalizedOrientation
        self.inverseDisplayTransform = frame
            .displayTransform(for: normalizedOrientation, viewportSize: viewportSize)
            .inverted()
        self.textureImage = cgImage
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

    func sampleColor(worldPosition: SIMD3<Float>) -> SIMD3<Float>? {
        guard let projection = projectImagePoint(worldPosition: worldPosition) else {
            return nil
        }
        guard isDepthConsistent(
            projectedDepth: projection.depthMeters,
            imagePoint: projection.imagePoint
        ) else {
            return nil
        }

        let px = max(0, min(colorWidth - 1, Int(projection.imagePoint.x * CGFloat(colorWidth - 1))))
        let py = max(0, min(colorHeight - 1, Int(projection.imagePoint.y * CGFloat(colorHeight - 1))))
        let offset = py * colorRowBytes + (px * 4)
        guard offset + 2 < colorPixels.count else { return nil }

        let r = Float(colorPixels[offset]) / 255.0
        let g = Float(colorPixels[offset + 1]) / 255.0
        let b = Float(colorPixels[offset + 2]) / 255.0
        return SIMD3<Float>(r, g, b)
    }

    func projectUV(worldPosition: SIMD3<Float>) -> SIMD2<Float>? {
        guard let projection = projectImagePoint(worldPosition: worldPosition) else {
            return nil
        }
        let imagePoint = projection.imagePoint
        return SIMD2<Float>(Float(imagePoint.x), Float(1.0 - imagePoint.y))
    }

    func writeTextureImage(nextTo outputURL: URL, baseName: String) -> URL? {
        let image = UIImage(cgImage: textureImage)
        guard let pngData = image.pngData() else {
            return nil
        }

        let textureURL = outputURL
            .deletingLastPathComponent()
            .appendingPathComponent("\(baseName).png")
        do {
            try pngData.write(to: textureURL, options: .atomic)
            return textureURL
        } catch {
            return nil
        }
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
        let bitmapInfo = CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue

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
