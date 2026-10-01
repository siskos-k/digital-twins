import SwiftUI
import RoomPlan

@MainActor
final class ScannerModel: NSObject, ObservableObject, RoomCaptureViewDelegate, RoomCaptureSessionDelegate {
    @Published var instruction = "Move slowly around the room. Capture each wall, doorway, and piece of furniture."
    @Published var processing = false
    @Published var result: CapturedRoom?
    @Published var error: String?
    private(set) var captureView: RoomCaptureView?
    private var ended = false
    override init() { super.init() }
    nonisolated required init?(coder: NSCoder) { super.init() }
    nonisolated func encode(with coder: NSCoder) {}
    func start(_ view: RoomCaptureView) {
        captureView = view
        view.delegate = self
        view.captureSession.delegate = self
        var configuration = RoomCaptureSession.Configuration()
        configuration.isCoachingEnabled = true
        view.captureSession.run(configuration: configuration)
    }
    func finish() {
        guard !ended, !processing else { return }
        processing = true
        instruction = "Preparing your 3D room…"
        captureView?.captureSession.stop()
    }
    func cancel() {
        ended = true
        captureView?.captureSession.stop()
    }
    func fail(_ message: String) {
        guard !ended, result == nil else { return }
        ended = true; processing = false; error = message
        captureView?.captureSession.stop()
    }
    nonisolated func captureView(shouldPresent roomDataForProcessing: CapturedRoomData, error: Error?) -> Bool {
        if let error { Task { @MainActor in self.fail(error.localizedDescription) }; return false }
        return true
    }
    nonisolated func captureView(didPresent processedResult: CapturedRoom, error: Error?) {
        Task { @MainActor in
            guard !self.ended else { return }
            if let error { self.fail(error.localizedDescription); return }
            guard !processedResult.walls.isEmpty else { self.fail("No walls were captured. Try again and move slowly around the room."); return }
            self.result = processedResult; self.processing = false; self.ended = true
        }
    }
    nonisolated func captureSession(_ session: RoomCaptureSession, didEndWith data: CapturedRoomData, error: Error?) {
        if let error { Task { @MainActor in self.fail(error.localizedDescription) } }
    }
    nonisolated func captureSession(_ session: RoomCaptureSession, didProvide instruction: RoomCaptureSession.Instruction) {
        let message: String
        switch instruction {
        case .moveCloseToWall: message = "Move closer to the wall."
        case .moveAwayFromWall: message = "Step back from the wall."
        case .slowDown: message = "Move more slowly to improve capture."
        case .turnOnLight: message = "Turn on more lights to improve capture."
        case .lowTexture: message = "Point at a corner or furniture to help tracking."
        case .normal: message = "Continue around the room, capturing all walls and furniture."
        @unknown default: message = "Move slowly around the room."
        }
        Task { @MainActor in if !self.processing && !self.ended { self.instruction = message } }
    }

}

struct CaptureSurface: UIViewRepresentable {
    let model: ScannerModel
    func makeUIView(context: Context) -> RoomCaptureView {
        let view = RoomCaptureView(frame: .zero)
        model.start(view)
        return view
    }
    func updateUIView(_ uiView: RoomCaptureView, context: Context) {}
    static func dismantleUIView(_ uiView: RoomCaptureView, coordinator: ()) { uiView.captureSession.stop() }
}

struct ScanFlow: View {
    @ObservedObject var library: LibraryModel
    @StateObject private var scanner = ScannerModel()
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var phase
    var body: some View {
        NavigationStack {
            Group {
                if let result = scanner.result {
                    ReviewView(captured: result, library: library)
                } else if let error = scanner.error {
                    ContentUnavailableView {
                        Label("Scan stopped", systemImage: "exclamationmark.triangle")
                    } description: { Text(error) } actions: {
                        Button("Return to rooms") { dismiss() }.buttonStyle(.borderedProminent)
                    }
                } else {
                    CaptureSurface(model: scanner)
                        .safeAreaInset(edge: .bottom) {
                            VStack(spacing: 12) {
                                Text(scanner.instruction).font(.callout).multilineTextAlignment(.center)
                                if scanner.processing { ProgressView() }
                                Button("Finish scan") { scanner.finish() }
                                    .buttonStyle(.borderedProminent).controlSize(.large).disabled(scanner.processing)
                            }.frame(maxWidth: .infinity).padding().background(.regularMaterial)
                        }
                }
            }
            .navigationTitle(scanner.result == nil ? "Scan one room" : "Review room")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(scanner.result == nil ? "Cancel" : "Close") { scanner.cancel(); dismiss() }
                }
            }
            .onChange(of: phase) { _, value in
                if value != .active && scanner.result == nil { scanner.fail("Scanning was interrupted. Start a new scan and keep the app open.") }
            }
        }.interactiveDismissDisabled()
    }
}
