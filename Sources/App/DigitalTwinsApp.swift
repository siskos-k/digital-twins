import SwiftUI
import RoomPlan
import RoomTwinCore
import AVFoundation

@main
struct DigitalTwinsApp: App {
    var body: some Scene { WindowGroup { LibraryView() } }
}

@MainActor
final class LibraryModel: ObservableObject {
    @Published var rooms: [SavedRoom] = []
    @Published var error: String?
    let store: RoomStore
    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        store = RoomStore(root: base.appendingPathComponent("Rooms", isDirectory: true))
        reload()
    }
    func reload() {
        do { rooms = try store.list() }
        catch { self.error = "Could not load saved rooms: \(error.localizedDescription)" }
    }
}

struct LibraryView: View {
    @StateObject private var library = LibraryModel()
    @State private var scanning = false
    @State private var requestingPermission = false
    private let supported = RoomCaptureSession.isSupported
    var body: some View {
        NavigationStack {
            Group {
                if library.rooms.isEmpty {
                    ContentUnavailableView("Your rooms, in 3D", systemImage: "cube.transparent", description: Text("Scan one room, inspect its dimensions, and keep a digital copy on your iPhone."))
                } else {
                    List(library.rooms) { room in
                        NavigationLink {
                            ReviewView(saved: room, library: library)
                        } label: {
                            Label {
                                VStack(alignment: .leading) {
                                    Text(room.name).font(.headline)
                                    Text(room.createdAt, style: .date).font(.caption).foregroundStyle(.secondary)
                                    Text("\(room.elements.count) captured elements").font(.caption).foregroundStyle(.secondary)
                                }
                            } icon: { Image(systemName: "cube") }
                        }
                    }
                }
            }
            .navigationTitle("Digital Twins")
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 12) {
                    if !supported { Text("Scanning requires a LiDAR-equipped iPhone. Saved rooms can still be reviewed and exported.").font(.footnote).foregroundStyle(.secondary) }
                    Button(action: requestScan) {
                        Label(requestingPermission ? "Requesting camera access…" : "Scan a room", systemImage: "viewfinder").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                    .disabled(!supported || requestingPermission)
                }.padding().background(.bar)
            }
            .fullScreenCover(isPresented: $scanning, onDismiss: library.reload) {
                ScanFlow(library: library)
            }
            .alert("Unable to continue", isPresented: Binding(get: { library.error != nil }, set: { if !$0 { library.error = nil } })) {
                if AVCaptureDevice.authorizationStatus(for: .video) == .denied {
                    Button("Open Settings") { if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) } }
                }
                Button("OK", role: .cancel) { library.error = nil }
            } message: { Text(library.error ?? "") }
        }
    }
    private func requestScan() {
        requestingPermission = true
        Task { @MainActor in
            let allowed = await AVCaptureDevice.requestAccess(for: .video)
            requestingPermission = false
            if allowed { scanning = true }
            else { library.error = "Camera access is required to scan a room. Enable it in Settings, then try again." }
        }
    }
}
