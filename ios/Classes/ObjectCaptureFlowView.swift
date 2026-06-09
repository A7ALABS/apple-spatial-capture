import SwiftUI
import RealityKit

@available(iOS 17.0, *)
@MainActor
final class ObjectCaptureSessionStore: ObservableObject {
    let session = ObjectCaptureSession()
}

@available(iOS 17.0, *)
struct ObjectCaptureFlowView: View {
    let outputDirectory: URL
    /// Returns either a model path, or an error message.
    let completion: (String?, String?) -> Void

    @StateObject private var sessionStore = ObjectCaptureSessionStore()
    @State private var phase: Phase = .capturing
    @State private var progress: Double = 0
    @State private var errorMessage: String?
    @State private var isFinishingCapture = false
    @State private var didComplete = false
    @State private var autoStartedDetecting = false
    @State private var shotsTaken = 0
    @State private var maxShots = 1
    @State private var scanPassCompleted = false
    @State private var feedbackHints: [String] = []
    @State private var captureStep: CaptureStep = .preparing

    enum Phase { case capturing, reconstructing, failed, done }
    enum CaptureStep { case preparing, ready, detecting, capturing, finishing, completed, failed }

    private var imagesDirectory: URL {
        outputDirectory.appendingPathComponent("Images")
    }
    private var usdzURL: URL {
        outputDirectory.appendingPathComponent("model.usdz")
    }

    // MARK: - Body

    var body: some View {
        ZStack {
            switch phase {
            case .capturing:
                ObjectCaptureView(session: sessionStore.session)
                    .ignoresSafeArea()
                captureOverlay
            case .reconstructing:
                reconstructingOverlay
            case .failed:
                failedOverlay
            case .done:
                Color.black.ignoresSafeArea()
            }
        }
        .onAppear(perform: startCaptureSession)
        .task { await monitorCaptureSession() }
    }

    // MARK: - Subviews

    private var captureOverlay: some View {
        GeometryReader { geometry in
            let isLandscape = geometry.size.width > geometry.size.height
            let topPadding = max(geometry.safeAreaInsets.top + 12, 20)
            let panelMaxWidth = isLandscape
                ? max(340, geometry.size.width - 340)
                : max(0, geometry.size.width - 40)

            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 12) {
                    cancelButton

                    if isLandscape {
                        scanControls(isLandscape: true, panelMaxWidth: panelMaxWidth)
                    } else {
                        Spacer(minLength: 0)
                    }
                }

                if !isLandscape {
                    scanControls(isLandscape: false, panelMaxWidth: panelMaxWidth)
                }

                Spacer(minLength: 0)
            }
            .padding(.top, topPadding)
            .padding(.horizontal, 20)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .animation(.easeInOut(duration: 0.25), value: feedbackHints)
        }
    }

    @ViewBuilder
    private func scanControls(isLandscape: Bool, panelMaxWidth: CGFloat) -> some View {
        if isLandscape {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 10) {
                    feedbackHint
                    scanProgressPanel(maxWidth: panelMaxWidth)
                }

                primaryCaptureButton
            }
        } else {
            VStack(spacing: 10) {
                feedbackHint
                scanProgressPanel(maxWidth: panelMaxWidth)
                primaryCaptureButton
            }
        }
    }

    @ViewBuilder
    private var feedbackHint: some View {
        if let hint = feedbackHints.first {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundColor(.orange)
                Text(hint)
                    .font(.footnote.weight(.medium))
                    .foregroundColor(.white)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(Color.black.opacity(0.65))
            .cornerRadius(20)
            .transition(.opacity)
        }
    }

    private var cancelButton: some View {
        Button(action: cancel) {
            Image(systemName: "xmark")
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(.white)
                .frame(width: 36, height: 36)
                .background(Color.black.opacity(0.55))
                .clipShape(Circle())
        }
    }

    private var primaryCaptureButton: some View {
        Button(primaryActionLabel) {
            primaryCaptureAction()
        }
        .font(.headline)
        .foregroundColor(.white)
        .padding(.horizontal, 28)
        .padding(.vertical, 14)
        .background(Color.blue)
        .cornerRadius(14)
        .disabled(isPrimaryActionDisabled)
    }

    private func scanProgressPanel(maxWidth: CGFloat) -> some View {
        let fraction = min(Double(shotsTaken) / Double(max(maxShots, 1)), 1.0)
        let completed = scanPassCompleted

        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: scanStatusIcon)
                    .font(.system(size: 14))
                    .foregroundColor(scanStatusColor)
                Text(scanStatusTitle)
                    .font(.subheadline.bold())
                    .foregroundColor(scanStatusColor)
                Spacer()
                Text("\(shotsTaken) photo\(shotsTaken == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.75))
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.white.opacity(0.15))
                        .frame(height: 6)
                    Capsule()
                        .fill(completed ? Color.green : Color.blue)
                        .frame(width: geo.size.width * fraction, height: 6)
                        .animation(.easeOut(duration: 0.3), value: fraction)
                }
            }
            .frame(height: 6)

            Text(scanGuidanceText)
            .font(.caption)
            .foregroundColor(completed ? .green.opacity(0.9) : .white.opacity(0.6))
            .multilineTextAlignment(.leading)
            .animation(.easeInOut, value: completed)
        }
        .padding(14)
        .background(Color.black.opacity(0.65))
        .cornerRadius(14)
        .frame(maxWidth: maxWidth, alignment: .leading)
    }

    private func feedbackMessage(_ feedback: ObjectCaptureSession.Feedback) -> String? {
        switch feedback {
        case .objectTooClose:      return "Move further from the object"
        case .objectTooFar:        return "Move closer to the object"
        case .environmentTooDark:  return "Environment is too dark — find better lighting"
        case .environmentLowLight: return "More light recommended"
        case .movingTooFast:       return "Move more slowly"
        case .outOfFieldOfView:    return "Keep the object in frame"
        case .objectNotDetected:   return "Center the object and keep a plain background"
        case .overCapturing:       return "You can finish now or move to a new angle"
        case .objectNotFlippable:  return "Skip flip capture unless the object can be safely flipped"
        @unknown default:          return nil
        }
    }

    private var reconstructingOverlay: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 28) {
                Image(systemName: "cube.transparent")
                    .font(.system(size: 56))
                    .foregroundColor(.blue)
                    .symbolEffect(.pulse)

                Text("Reconstructing 3D Model")
                    .font(.title3).bold().foregroundColor(.white)

                VStack(spacing: 10) {
                    ProgressView(value: progress)
                        .progressViewStyle(.linear)
                        .tint(.blue)
                        .frame(width: 280)
                    Text("\(Int(progress * 100))%")
                        .font(.headline).foregroundColor(.blue)
                }

                Text("Photogrammetry running on-device.\nThis may take a few minutes.")
                    .font(.footnote)
                    .foregroundColor(.white.opacity(0.55))
                    .multilineTextAlignment(.center)

                if let err = errorMessage {
                    Text(err)
                        .font(.caption).foregroundColor(.red)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }
            }
        }
    }

    private var failedOverlay: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 16) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 44))
                    .foregroundColor(.orange)

                Text("Couldn’t Generate 3D Model")
                    .font(.title3).bold().foregroundColor(.white)

                Text(errorMessage ?? "Unknown error.")
                    .font(.footnote)
                    .foregroundColor(.white.opacity(0.75))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)

                HStack(spacing: 12) {
                    Button("Cancel") { cancel() }
                        .foregroundColor(.white)
                        .padding(.horizontal, 22)
                        .padding(.vertical, 10)
                        .background(Color.white.opacity(0.12))
                        .cornerRadius(10)

                    Button("Try Again") { retryGeneration() }
                        .foregroundColor(.white)
                        .padding(.horizontal, 22)
                        .padding(.vertical, 10)
                        .background(Color.blue)
                        .cornerRadius(10)
                }
                .padding(.top, 6)
            }
        }
    }

    // MARK: - Capture session

    private func startCaptureSession() {
        do {
            try FileManager.default.createDirectory(at: imagesDirectory, withIntermediateDirectories: true)
        } catch {
            completeWith(path: nil, error: "Could not create capture directory: \(error.localizedDescription)")
            return
        }
        var config = ObjectCaptureSession.Configuration()
        config.checkpointDirectory = outputDirectory.appendingPathComponent("Checkpoints")
        sessionStore.session.start(imagesDirectory: imagesDirectory, configuration: config)
        refreshCaptureStats()
    }

    private func finishCapture() {
        guard !isFinishingCapture else { return }
        isFinishingCapture = true
        sessionStore.session.finish()
    }

    private func monitorCaptureSession() async {
        while !Task.isCancelled {
            refreshCaptureStats()
            switch sessionStore.session.state {
            case .ready:
                if !autoStartedDetecting {
                    autoStartedDetecting = sessionStore.session.startDetecting()
                }
            case .completed:
                await MainActor.run {
                    phase = .reconstructing
                    progress = 0
                    errorMessage = nil
                    isFinishingCapture = false
                }
                await runPhotogrammetry()
                return
            case .failed(let error):
                print("[ObjectCapture] Capture failed: \(error.localizedDescription)")
                await MainActor.run {
                    phase = .failed
                    isFinishingCapture = false
                    errorMessage = "Capture failed: \(error.localizedDescription)"
                }
                return
            default:
                break
            }
            try? await Task.sleep(nanoseconds: 200_000_000) // 200 ms
        }
    }

    // MARK: - Photogrammetry reconstruction

    private func runPhotogrammetry() async {
        do {
            let imageCount = countCapturedImages()

            guard imageCount > 0 else {
                await MainActor.run {
                    phase = .failed
                    errorMessage = "No capture photos were saved. Try scanning again with better lighting."
                }
                return
            }

            if FileManager.default.fileExists(atPath: usdzURL.path) {
                try? FileManager.default.removeItem(at: usdzURL)
            }

            var config = PhotogrammetrySession.Configuration()
            config.sampleOrdering = .sequential
            config.featureSensitivity = .normal

            let photogrammetry = try PhotogrammetrySession(
                input: imagesDirectory,
                configuration: config
            )

            let request = PhotogrammetrySession.Request.modelFile(
                url: usdzURL,
                detail: .reduced
            )

            try photogrammetry.process(requests: [request])

            var requestCompleted = false
            var producedModelURL: URL?
            for try await output in photogrammetry.outputs {
                switch output {
                case .requestProgress(_, fractionComplete: let fraction):
                    await MainActor.run { progress = fraction }

                case .requestComplete(_, let result):
                    requestCompleted = true
                    switch result {
                    case .modelFile(let url):
                        producedModelURL = url
                    default:
                        break
                    }
                    await MainActor.run { phase = .done }
                    let finalURL = producedModelURL ?? usdzURL
                    guard FileManager.default.fileExists(atPath: finalURL.path) else {
                        await MainActor.run {
                            phase = .failed
                            errorMessage = "Generation completed but model file could not be found."
                        }
                        return
                    }
                    await MainActor.run { completeWith(path: finalURL.path, error: nil) }
                    return

                case .requestError(_, let error):
                    print("[Photogrammetry] Request error: \(error.localizedDescription)")
                    await MainActor.run {
                        phase = .failed
                        errorMessage = "Generation failed: \(error.localizedDescription)"
                    }
                    return

                case .processingComplete:
                    break   // outputs stream ends naturally after this

                case .processingCancelled:
                    await MainActor.run {
                        phase = .failed
                        errorMessage = "Generation was cancelled."
                    }
                    return

                default:
                    break
                }
            }

            if !requestCompleted {
                await MainActor.run {
                    phase = .failed
                    errorMessage = "Generation ended without producing a model file."
                }
            }
        } catch {
            print("[Photogrammetry] Session error: \(error.localizedDescription)")
            await MainActor.run {
                phase = .failed
                errorMessage = "Session error: \(error.localizedDescription)"
            }
        }
    }

    private func retryGeneration() {
        progress = 0
        errorMessage = nil
        phase = .reconstructing
        Task { await runPhotogrammetry() }
    }

    private func cancel() {
        sessionStore.session.cancel()
        completeWith(path: nil, error: phase == .failed ? errorMessage : nil)
    }

    private func completeWith(path: String?, error: String?) {
        guard !didComplete else { return }
        didComplete = true
        completion(path, error)
    }

    private var primaryActionLabel: String {
        if isFinishingCapture { return "Finishing…" }
        switch captureStep {
        case .ready:
            return "Detect Object"
        case .detecting:
            return "Start Scan"
        case .capturing:
            return scanPassCompleted ? "Generate Object" : "Finish Capture"
        case .preparing:
            return "Preparing Camera…"
        case .finishing:
            return "Finishing…"
        case .completed:
            return "Generating…"
        case .failed:
            return "Capture Failed"
        }
    }

    private var isPrimaryActionDisabled: Bool {
        if isFinishingCapture { return true }
        switch captureStep {
        case .ready, .detecting, .capturing:
            return false
        default:
            return true
        }
    }

    private var scanStatusIcon: String {
        switch captureStep {
        case .ready:
            return "scope"
        case .detecting:
            return "viewfinder.circle.fill"
        case .capturing, .finishing:
            return scanPassCompleted ? "checkmark.circle.fill" : "camera.fill"
        case .completed:
            return "checkmark.circle.fill"
        case .failed:
            return "exclamationmark.circle.fill"
        case .preparing:
            return "clock.fill"
        }
    }

    private var scanStatusTitle: String {
        switch captureStep {
        case .ready:
            return "Align object"
        case .detecting:
            return "Detecting object bounds…"
        case .capturing:
            return scanPassCompleted ? "Ready to generate" : "Capturing…"
        case .finishing:
            return "Finishing capture…"
        case .completed:
            return "Capture complete"
        case .failed:
            return "Capture failed"
        case .preparing:
            return "Preparing camera…"
        }
    }

    private var scanStatusColor: Color {
        switch captureStep {
        case .completed:
            return .green
        case .capturing where scanPassCompleted:
            return .green
        case .failed:
            return .orange
        default:
            return .white
        }
    }

    private var scanGuidanceText: String {
        switch captureStep {
        case .ready:
            return "Center the object and keep space around it so the detection box can lock."
        case .detecting:
            return "Once the object box looks correct, tap Start Scan."
        case .capturing:
            return scanPassCompleted
                ? "All angles covered — tap Generate Object when ready."
                : "Walk slowly around the object at low, mid, and overhead angles."
        case .finishing:
            return "Saving captured photos before reconstruction."
        case .completed:
            return "Starting photogrammetry reconstruction."
        case .failed:
            return "Capture failed. Try again with better lighting and a clear background."
        case .preparing:
            return "Initializing object capture session."
        }
    }

    private func primaryCaptureAction() {
        switch captureStep {
        case .ready:
            _ = sessionStore.session.startDetecting()
        case .detecting:
            sessionStore.session.startCapturing()
        case .capturing:
            finishCapture()
        default:
            break
        }
    }

    private func refreshCaptureStats() {
        shotsTaken = sessionStore.session.numberOfShotsTaken
        maxShots = max(sessionStore.session.maximumNumberOfInputImages, 1)
        scanPassCompleted = sessionStore.session.userCompletedScanPass
        feedbackHints = sessionStore.session.feedback.compactMap { feedbackMessage($0) }

        if isFinishingCapture {
            captureStep = .finishing
            return
        }

        switch sessionStore.session.state {
        case .ready:
            captureStep = .ready
        case .detecting:
            captureStep = .detecting
        case .capturing:
            captureStep = .capturing
        case .completed:
            captureStep = .completed
        case .failed:
            captureStep = .failed
        default:
            captureStep = .preparing
        }
    }

    private func countCapturedImages() -> Int {
        let imageExtensions = Set(["jpg", "jpeg", "heic", "heif", "png"])
        guard let enumerator = FileManager.default.enumerator(
            at: imagesDirectory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return 0
        }

        var count = 0
        for case let fileURL as URL in enumerator {
            guard imageExtensions.contains(fileURL.pathExtension.lowercased()) else { continue }
            let isRegularFile = (try? fileURL.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) ?? false
            if isRegularFile {
                count += 1
            }
        }
        return count
    }
}
