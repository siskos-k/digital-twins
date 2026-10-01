import SwiftUI
import SceneKit
import RoomPlan
import RoomTwinCore

struct ReviewView: View {
    private let captured: CapturedRoom?
    @ObservedObject var library: LibraryModel
    @State private var saved: SavedRoom?
    @State private var name = ""
    @State private var modelURL: URL?
    @State private var previewDirectory: URL?
    @State private var error: String?
    @State private var busy = false
    @State private var sharing: ShareItems?
    init(captured: CapturedRoom, library: LibraryModel) {
        self.captured = captured; self.library = library
        _name = State(initialValue: "Room \(Date().formatted(date: .abbreviated, time: .omitted))")
    }
    init(saved: SavedRoom, library: LibraryModel) {
        captured = nil; self.library = library
        _saved = State(initialValue: saved); _name = State(initialValue: saved.name)
        _modelURL = State(initialValue: library.store.modelURL(for: saved))
    }
    private var elements: [RoomElement] {
        if let saved { return saved.elements }
        guard let captured else { return [] }
        let surfaces = captured.walls + captured.doors + captured.windows + captured.openings
        return surfaces.map { RoomElement(id: $0.identifier, kind: String(describing: $0.category).capitalized, width: $0.dimensions.x, height: $0.dimensions.y, depth: $0.dimensions.z) }
            + captured.objects.map { RoomElement(id: $0.identifier, kind: String(describing: $0.category).capitalized, width: $0.dimensions.x, height: $0.dimensions.y, depth: $0.dimensions.z) }
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Group {
                    if let modelURL {
                        ModelViewer(url: modelURL, onError: { error = $0 })
                    } else { ProgressView("Preparing model…").frame(maxWidth: .infinity) }
                }.frame(height: 300).background(Color(.secondarySystemBackground)).clipShape(RoundedRectangle(cornerRadius: 16))
                Text("Drag to rotate · Pinch to zoom").font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity)
                if saved == nil {
                    TextField("Room name", text: $name).textFieldStyle(.roundedBorder).disabled(busy)
                    Button {
                        save()
                    } label: { Label(busy ? "Saving…" : "Save room", systemImage: "tray.and.arrow.down").frame(maxWidth: .infinity) }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                    .disabled(busy || modelURL == nil || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                } else {
                    Label("Saved on this iPhone", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    Button {
                        guard let saved else { return }
                        do { sharing = ShareItems(urls: try library.store.exportURLs(for: saved)) }
                        catch { self.error = error.localizedDescription }
                    } label: { Label("Export model and room data", systemImage: "square.and.arrow.up").frame(maxWidth: .infinity) }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                }
                Text("Captured dimensions").font(.headline)
                Text("Estimated dimensions in metres. Verify measurements before using them for planning.").font(.footnote).foregroundStyle(.secondary)
                ForEach(elements) { element in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(element.kind).font(.subheadline.bold())
                        Text(String(format: "Width %.2f m · Height %.2f m · Depth %.2f m", element.width, element.height, element.depth))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Divider()
                }
            }.padding()
        }
        .navigationTitle(saved?.name ?? "Review room")
        .navigationBarTitleDisplayMode(.inline)
        .task { await preparePreview() }
        .onDisappear { cleanupPreview() }
        .sheet(item: $sharing) { ShareSheet(urls: $0.urls, onError: { error = $0 }) }
        .alert("Unable to complete action", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK", role: .cancel) { error = nil }
            if modelURL == nil { Button("Retry preview") { Task { await preparePreview() } } }
        } message: { Text(error ?? "") }
    }
    @MainActor private func preparePreview() async {
        guard modelURL == nil, let captured else { return }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("DigitalTwins-\(UUID())", isDirectory: true)
        do {
            let url = try await Task.detached(priority: .userInitiated) {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let url = folder.appendingPathComponent("model.usdz")
                try captured.export(to: url, exportOptions: .parametric)
                return url
            }.value
            if Task.isCancelled { try? FileManager.default.removeItem(at: folder); return }
            previewDirectory = folder; modelURL = url
        } catch {
            try? FileManager.default.removeItem(at: folder)
            self.error = "Could not generate the preview: \(error.localizedDescription)"
        }
    }
    private func cleanupPreview() {
        if let previewDirectory { try? FileManager.default.removeItem(at: previewDirectory) }
        previewDirectory = nil
        if saved == nil { modelURL = nil }
    }
    private func save() {
        guard let captured, let modelURL, !busy else { return }
        busy = true
        let store = library.store, roomName = name, roomElements = elements
        Task { @MainActor in
            defer { busy = false }
            do {
                let room = try await Task.detached(priority: .userInitiated) {
                    let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                    let json = try encoder.encode(captured)
                    return try store.save(name: roomName, elements: roomElements, capturedJSON: json) { destination in
                        try FileManager.default.copyItem(at: modelURL, to: destination)
                    }
                }.value
                saved = room; self.modelURL = store.modelURL(for: room); library.reload()
                cleanupPreview()
            } catch { self.error = "Could not save this room: \(error.localizedDescription). You can try again." }
        }
    }
}

struct ModelViewer: UIViewRepresentable {
    let url: URL
    let onError: (String) -> Void
    func makeUIView(context: Context) -> SCNView {
        let view = SCNView()
        view.backgroundColor = .secondarySystemBackground
        view.allowsCameraControl = true
        view.autoenablesDefaultLighting = true
        view.defaultCameraController.interactionMode = .orbitTurntable
        do {
            let scene = try SCNScene(url: url)
            view.scene = scene
            let bounds = scene.rootNode.boundingBox
            let centre = SCNVector3((bounds.min.x + bounds.max.x) / 2, (bounds.min.y + bounds.max.y) / 2, (bounds.min.z + bounds.max.z) / 2)
            let extent = max(bounds.max.x - bounds.min.x, bounds.max.y - bounds.min.y, bounds.max.z - bounds.min.z, 1)
            let camera = SCNNode(); camera.camera = SCNCamera(); camera.camera?.zFar = 1000
            camera.position = SCNVector3(centre.x + extent, centre.y + extent, centre.z + extent * 1.5)
            camera.look(at: centre)
            scene.rootNode.addChildNode(camera); view.pointOfView = camera
            view.defaultCameraController.target = centre
        } catch {
            DispatchQueue.main.async { onError("Could not open the 3D model: \(error.localizedDescription)") }
        }
        return view
    }
    func updateUIView(_ uiView: SCNView, context: Context) {}
}

struct ShareItems: Identifiable { let id = UUID(); let urls: [URL] }
struct ShareSheet: UIViewControllerRepresentable {
    let urls: [URL]
    let onError: (String) -> Void
    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: urls, applicationActivities: nil)
        controller.completionWithItemsHandler = { _, _, _, error in
            if let error { DispatchQueue.main.async { onError("Export failed: \(error.localizedDescription)") } }
        }
        return controller
    }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
