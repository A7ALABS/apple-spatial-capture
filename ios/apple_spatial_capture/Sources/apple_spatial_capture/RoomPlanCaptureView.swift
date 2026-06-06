import SwiftUI
import RoomPlan

@available(iOS 16.0, *)
struct RoomPlanCaptureView: View {
    let completion: (String?) -> Void

    @StateObject private var coordinator = RoomPlanCoordinator()
    @State private var exportError: String?

    var body: some View {
        ZStack {
            RoomCaptureViewRepresentable(coordinator: coordinator)
                .ignoresSafeArea()

            VStack(spacing: 0) {
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

                Spacer()

                if coordinator.isProcessing {
                    processingView
                        .padding(.bottom, 50)
                } else {
                    VStack(spacing: 12) {
                        Text("Move slowly along walls and point at doors/windows")
                            .font(.subheadline)
                            .foregroundColor(.white)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 24)
                            .padding(.vertical, 10)
                            .background(Color.black.opacity(0.55))
                            .cornerRadius(12)

                        Button(action: finishAndExport) {
                            Label("Finish Room Scan", systemImage: "square.and.arrow.down")
                                .font(.headline)
                                .foregroundColor(.white)
                                .padding(.horizontal, 36)
                                .padding(.vertical, 14)
                                .background(Color.green)
                                .cornerRadius(14)
                        }
                    }
                    .padding(.bottom, 50)
                }

                if let err = exportError {
                    Text(err)
                        .font(.footnote)
                        .foregroundColor(.red)
                        .padding(.horizontal, 20)
                        .padding(.bottom, 10)
                }
            }
        }
        .onDisappear { coordinator.stop() }
    }

    private var processingView: some View {
        VStack(spacing: 12) {
            ProgressView()
                .progressViewStyle(CircularProgressViewStyle(tint: .white))
            Text("Processing room layout…")
                .font(.headline)
                .foregroundColor(.white)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
        .background(Color.black.opacity(0.65))
        .cornerRadius(12)
    }

    private func finishAndExport() {
        exportError = nil
        coordinator.finishCapture { result in
            switch result {
            case .success(let path):
                completion(path)
            case .failure(let error):
                exportError = "Export failed: \(error.localizedDescription)"
            }
        }
    }

    private func cancel() {
        coordinator.stop()
        completion(nil)
    }
}

@available(iOS 16.0, *)
final class RoomPlanCoordinator: NSObject, ObservableObject, RoomCaptureViewDelegate, RoomCaptureSessionDelegate {
    @Published var isProcessing: Bool = false

    fileprivate weak var captureView: RoomCaptureView?
    private var completion: ((Result<String, Error>) -> Void)?

    override init() {
        super.init()
    }

    required init?(coder: NSCoder) {
        super.init()
    }

    func encode(with coder: NSCoder) {}

    func start(captureView: RoomCaptureView) {
        self.captureView = captureView
        captureView.delegate = self
        captureView.captureSession.delegate = self
        captureView.captureSession.run(configuration: RoomCaptureSession.Configuration())
    }

    func stop() {
        captureView?.captureSession.stop()
    }

    func finishCapture(completion: @escaping (Result<String, Error>) -> Void) {
        self.completion = completion
        DispatchQueue.main.async {
            self.isProcessing = true
            self.captureView?.captureSession.stop()
        }
    }

    func captureView(shouldPresent roomDataForProcessing: CapturedRoomData, error: Error?) -> Bool {
        return true
    }

    func captureView(didPresent processedResult: CapturedRoom, error: Error?) {
        if let error {
            DispatchQueue.main.async {
                self.isProcessing = false
                self.completion?(.failure(error))
                self.completion = nil
            }
            return
        }

        let exportURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("roomplan_\(UUID().uuidString).usdz")

        do {
            try processedResult.export(to: exportURL, exportOptions: .model)
            DispatchQueue.main.async {
                self.isProcessing = false
                self.completion?(.success(exportURL.path))
                self.completion = nil
            }
        } catch {
            DispatchQueue.main.async {
                self.isProcessing = false
                self.completion?(.failure(error))
                self.completion = nil
            }
        }
    }
}

@available(iOS 16.0, *)
struct RoomCaptureViewRepresentable: UIViewRepresentable {
    let coordinator: RoomPlanCoordinator

    func makeUIView(context: Context) -> RoomCaptureView {
        let view = RoomCaptureView(frame: .zero)
        coordinator.start(captureView: view)
        return view
    }

    func updateUIView(_ uiView: RoomCaptureView, context: Context) {}
}
