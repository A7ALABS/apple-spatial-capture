import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
#if os(iOS)
import Flutter
#elseif os(macOS)
import FlutterMacOS
#endif

/// Embedded splat viewport driven from Flutter over the method channel:
/// open a checkpoint-backed render session, request orbit frames as JPEG
/// bytes, close when the widget goes away. The full-screen native preview
/// (GaussianSplatPreviewViewController) is unchanged; this powers the
/// in-app Splat Studio viewport, which draws its own overlays Flutter-side
/// (mirroring the web studio's render-image-then-overlay architecture).
enum SplatViewportChannel {
    /// Closes every live viewport session. Training calls this before it
    /// starts: a viewport session plus a trainer is two full engine
    /// instances, which jetsams iPhones.
    static func closeAllSessions() {
        #if canImport(MsplatCore)
        if #available(iOS 16.0, macOS 14.0, *) {
            Sessions.removeAll().forEach { $0.close() }
        }
        #endif
    }

    static func open(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        #if canImport(MsplatCore)
        guard #available(iOS 16.0, macOS 14.0, *) else {
            result(FlutterError(
                code: "UNSUPPORTED",
                message: "Splat preview requires iOS 16 or macOS 14.",
                details: nil
            ))
            return
        }
        guard
            let args = call.arguments as? [String: Any],
            let rawPath = args["datasetPath"] as? String,
            !rawPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            result(FlutterError(
                code: "INVALID_ARGS", message: "datasetPath is required.", details: nil
            ))
            return
        }
        let path = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                Sessions.removeAll().forEach { $0.close() }
                let session = try GaussianSplatPreviewSession(datasetPath: path)
                let id = Sessions.store(session)
                let payload: [String: Any] = [
                    "sessionId": id,
                    "splatCount": session.splatCount,
                    "orbitRadius": Double(session.orbitRadius),
                ]
                DispatchQueue.main.async { result(payload) }
            } catch {
                DispatchQueue.main.async {
                    result(FlutterError(
                        code: "VIEWPORT_OPEN_FAILED",
                        message: error.localizedDescription,
                        details: nil
                    ))
                }
            }
        }
        #else
        result(FlutterError(
            code: "UNSUPPORTED",
            message: "Splat rendering is not available in this build of the plugin.",
            details: nil
        ))
        #endif
    }

    /// Opens a viewport session for a standalone `.ply` on disk (a splat
    /// downloaded from the cloud), rendered natively without a dataset or
    /// checkpoint. View-only.
    static func openPly(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        #if canImport(MsplatCore)
        guard #available(iOS 16.0, macOS 14.0, *) else {
            result(FlutterError(
                code: "UNSUPPORTED",
                message: "Splat preview requires iOS 16 or macOS 14.",
                details: nil
            ))
            return
        }
        guard
            let args = call.arguments as? [String: Any],
            let rawPath = args["plyPath"] as? String,
            !rawPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            result(FlutterError(
                code: "INVALID_ARGS", message: "plyPath is required.", details: nil
            ))
            return
        }
        let path = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                Sessions.removeAll().forEach { $0.close() }
                let session = try GaussianSplatPreviewSession(plyPath: path)
                let id = Sessions.store(session)
                let payload: [String: Any] = [
                    "sessionId": id,
                    "splatCount": session.splatCount,
                    "orbitRadius": Double(session.orbitRadius),
                ]
                DispatchQueue.main.async { result(payload) }
            } catch {
                DispatchQueue.main.async {
                    result(FlutterError(
                        code: "VIEWPORT_OPEN_FAILED",
                        message: error.localizedDescription,
                        details: nil
                    ))
                }
            }
        }
        #else
        result(FlutterError(
            code: "UNSUPPORTED",
            message: "Splat rendering is not available in this build of the plugin.",
            details: nil
        ))
        #endif
    }

    static func render(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        #if canImport(MsplatCore)
        guard #available(iOS 16.0, macOS 14.0, *) else {
            result(nil)
            return
        }
        guard
            let args = call.arguments as? [String: Any],
            let id = args["sessionId"] as? Int
        else {
            result(FlutterError(
                code: "INVALID_ARGS", message: "sessionId is required.", details: nil
            ))
            return
        }
        guard let session = Sessions.get(id) else {
            result(FlutterError(
                code: "INVALID_SESSION",
                message: "Viewport session \(id) is closed.",
                details: nil
            ))
            return
        }
        let azimuth = Float((args["azimuth"] as? NSNumber)?.doubleValue ?? 0)
        let elevation = Float((args["elevation"] as? NSNumber)?.doubleValue ?? 0.35)
        let distanceScale = Float((args["distanceScale"] as? NSNumber)?.doubleValue ?? 1)
        DispatchQueue.global(qos: .userInteractive).async {
            var camera = GaussianSplatOrbitCamera(
                center: session.orbitCenter,
                distance: max(0.05, session.orbitRadius * min(8, max(0.1, distanceScale)))
            )
            camera.azimuth = azimuth
            camera.elevation = elevation
            guard
                let image = session.renderFrameSync(pose: camera.pose()),
                let jpeg = jpegData(from: image)
            else {
                DispatchQueue.main.async { result(nil) }
                return
            }
            DispatchQueue.main.async {
                result(FlutterStandardTypedData(bytes: jpeg))
            }
        }
        #else
        result(nil)
        #endif
    }

    static func close(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        #if canImport(MsplatCore)
        if #available(iOS 16.0, macOS 14.0, *),
           let args = call.arguments as? [String: Any],
           let id = args["sessionId"] as? Int {
            Sessions.remove(id)?.close()
        }
        #endif
        result(nil)
    }

    #if canImport(MsplatCore)
    @available(iOS 16.0, macOS 14.0, *)
    private enum Sessions {
        private static let lock = NSLock()
        nonisolated(unsafe) private static var sessions:
            [Int: GaussianSplatPreviewSession] = [:]
        nonisolated(unsafe) private static var nextId = 1

        static func store(_ session: GaussianSplatPreviewSession) -> Int {
            lock.lock()
            defer { lock.unlock() }
            let id = nextId
            nextId += 1
            sessions[id] = session
            return id
        }

        static func get(_ id: Int) -> GaussianSplatPreviewSession? {
            lock.lock()
            defer { lock.unlock() }
            return sessions[id]
        }

        static func remove(_ id: Int) -> GaussianSplatPreviewSession? {
            lock.lock()
            defer { lock.unlock() }
            return sessions.removeValue(forKey: id)
        }

        static func removeAll() -> [GaussianSplatPreviewSession] {
            lock.lock()
            defer { lock.unlock() }
            let all = Array(sessions.values)
            sessions.removeAll()
            return all
        }
    }
    #endif

    // ── Editing ─────────────────────────────────────────────────────────

    #if canImport(MsplatCore)
    /// Shared plumbing: resolves the session, runs `body` off the main
    /// thread, replies with its payload.
    @available(iOS 16.0, macOS 14.0, *)
    private static func withSession(
        _ call: FlutterMethodCall,
        result: @escaping FlutterResult,
        body: @escaping (GaussianSplatPreviewSession, [String: Any]) -> Any?
    ) {
        guard
            let args = call.arguments as? [String: Any],
            let id = args["sessionId"] as? Int
        else {
            result(FlutterError(
                code: "INVALID_ARGS", message: "sessionId is required.", details: nil
            ))
            return
        }
        guard let session = Sessions.get(id) else {
            result(FlutterError(
                code: "INVALID_SESSION",
                message: "Viewport session \(id) is closed.",
                details: nil
            ))
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let payload = body(session, args)
            DispatchQueue.main.async { result(payload) }
        }
    }
    #endif

    static func cleanup(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        #if canImport(MsplatCore)
        if #available(iOS 16.0, macOS 14.0, *) {
            withSession(call, result: result) { session, args in
                let minOpacity = Float((args["minOpacity"] as? NSNumber)?.doubleValue ?? 0)
                let maxScale = Float((args["maxWorldScale"] as? NSNumber)?.doubleValue ?? 0)
                return session.cleanupSync(minOpacity: minOpacity, maxWorldScale: maxScale)
            }
            return
        }
        #endif
        result(nil)
    }

    static func crop(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        #if canImport(MsplatCore)
        if #available(iOS 16.0, macOS 14.0, *) {
            withSession(call, result: result) { session, args in
                let keep = Float((args["keepFraction"] as? NSNumber)?.doubleValue ?? 0.85)
                return session.cropPercentileSync(keepFraction: keep)
            }
            return
        }
        #endif
        result(nil)
    }

    static func snapshot(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        #if canImport(MsplatCore)
        if #available(iOS 16.0, macOS 14.0, *) {
            withSession(call, result: result) { session, args in
                guard let path = args["path"] as? String, !path.isEmpty else { return nil }
                session.snapshotSync(to: path)
                return nil
            }
            return
        }
        #endif
        result(nil)
    }

    static func restore(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        #if canImport(MsplatCore)
        if #available(iOS 16.0, macOS 14.0, *) {
            withSession(call, result: result) { session, args in
                guard let path = args["path"] as? String, !path.isEmpty else { return nil }
                return session.restoreSync(from: path)
            }
            return
        }
        #endif
        result(nil)
    }

    static func saveEdits(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        #if canImport(MsplatCore)
        if #available(iOS 16.0, macOS 14.0, *) {
            withSession(call, result: result) { session, args in
                guard let datasetPath = args["datasetPath"] as? String,
                      !datasetPath.isEmpty else { return nil }
                return session.saveEditsSync(datasetPath: datasetPath)
            }
            return
        }
        #endif
        result(nil)
    }

    private static func jpegData(from image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data, UTType.jpeg.identifier as CFString, 1, nil
        ) else { return nil }
        CGImageDestinationAddImage(
            destination, image,
            [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary
        )
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}
