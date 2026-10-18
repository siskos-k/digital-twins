import SwiftUI
import SceneKit
import RoomTwinCore

enum ExploreMode: String, CaseIterable { case orbit = "Overview", walk = "Walk inside" }

struct RoomExplorer: View {
    let room: SavedRoom
    let url: URL
    @StateObject private var inventory: EquipmentRoomModel
    @State private var mode = ExploreMode.orbit
    @State private var placing = false
    @State private var moving: Equipment?
    @State private var editor: Equipment?
    @State private var selected: Equipment?
    @State private var reset = UUID()
    @State private var error: String?
    @State private var settings = false
    @Environment(\.dismiss) private var dismiss
    init(room: SavedRoom, url: URL) {
        self.room = room; self.url = url
        _inventory = StateObject(wrappedValue: EquipmentRoomModel(roomID: room.id))
    }
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("View", selection: $mode) { ForEach(ExploreMode.allCases, id: \.self) { Text($0.rawValue).tag($0) } }.pickerStyle(.segmented).padding()
                ExplorerSurface(url: url, mode: mode, placing: placing, devices: inventory.devices, reset: reset,
                    onPlace: { position in
                        if var device = moving {
                            device.position = position
                            Task { if await inventory.save(device) { placing = false; moving = nil } }
                        } else {
                            editor = Equipment(roomID: room.id, position: position)
                            placing = false
                        }
                    }, onSelect: { selected = $0 }, onError: { error = $0 })
                    .frame(maxWidth: .infinity, maxHeight: .infinity).accessibilityLabel("Interactive 3D room").accessibilityIdentifier("roomScene")
                VStack(spacing: 10) {
                    Text(placing ? "Tap a surface to \(moving == nil ? "place equipment" : "move the marker")." : mode == .walk ? "Drag to look around. Tap the floor to move. Tap a marker for equipment." : "Drag to rotate. Pinch to zoom. Tap a marker for equipment.")
                        .font(.footnote).multilineTextAlignment(.center)
                    HStack {
                        Button(placing ? "Cancel placement" : "Add equipment", systemImage: placing ? "xmark" : "plus.circle") {
                            placing.toggle(); moving = nil
                        }.buttonStyle(.borderedProminent)
                        Button("Reset view", systemImage: "arrow.counterclockwise") { reset = UUID() }.buttonStyle(.bordered)
                    }
                }.padding().background(.bar)
                if !inventory.devices.isEmpty {
                    ScrollView(.horizontal) {
                        HStack {
                            ForEach(inventory.devices) { device in
                                Button { selected = device } label: { Label(device.name, systemImage: device.kind.symbol) }.buttonStyle(.bordered)
                            }
                        }.padding(.horizontal)
                    }.frame(height: 52)
                }
                if let error = inventory.error { Text(error).font(.caption).foregroundStyle(.red).padding(.horizontal) }
            }
            .navigationTitle(room.name).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
                ToolbarItem(placement: .primaryAction) { Button("IoT settings", systemImage: "network") { settings = true } }
            }
            .task { await inventory.load() }
            .sheet(item: $editor) { EquipmentEditor(inventory: inventory, device: $0) }
            .sheet(item: $selected) { device in
                EquipmentDetail(id: device.id, inventory: inventory, move: { moving = $0; placing = true })
            }
            .sheet(isPresented: $settings) { IoTSettingsView() }
            .alert("Room navigation", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("OK", role: .cancel) { error = nil }
            } message: { Text(error ?? "") }
        }
    }
}

struct ExplorerSurface: UIViewRepresentable {
    let url: URL
    let mode: ExploreMode
    let placing: Bool
    let devices: [Equipment]
    let reset: UUID
    let onPlace: (RoomPosition) -> Void
    let onSelect: (Equipment) -> Void
    let onError: (String) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> SCNView {
        let view = SCNView()
        view.backgroundColor = .secondarySystemBackground
        view.autoenablesDefaultLighting = true
        view.defaultCameraController.interactionMode = .orbitTurntable
        context.coordinator.view = view
        do { try context.coordinator.load() }
        catch { DispatchQueue.main.async { onError("Could not open this room: \(error.localizedDescription)") } }
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tap(_:)))
        view.addGestureRecognizer(tap)
        let pan = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.pan(_:)))
        pan.maximumNumberOfTouches = 1
        pan.delegate = context.coordinator
        view.addGestureRecognizer(pan)
        return view
    }
    func updateUIView(_ uiView: SCNView, context: Context) {
        let coordinator = context.coordinator
        let changed = coordinator.parent.mode != mode || coordinator.parent.reset != reset
        coordinator.parent = self
        uiView.allowsCameraControl = mode == .orbit && !placing
        if changed { coordinator.resetCamera() }
        coordinator.updateMarkers()
    }
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var parent: ExplorerSurface
        weak var view: SCNView?
        let camera = SCNNode()
        let markers = SCNNode()
        var minimum = SCNVector3Zero, maximum = SCNVector3Zero
        var yaw: Float = 0, pitch: Float = 0
        var shownDevices: [Equipment] = []
        init(_ parent: ExplorerSurface) { self.parent = parent }
        func load() throws {
            guard let view else { return }
            let scene = try SCNScene(url: parent.url)
            view.scene = scene
            let bounds = scene.rootNode.boundingBox
            minimum = bounds.min; maximum = bounds.max
            scene.rootNode.enumerateChildNodes { node, _ in
                node.categoryBitMask = 1
                node.geometry?.materials.forEach { $0.isDoubleSided = true }
            }
            camera.camera = SCNCamera(); camera.camera?.zNear = 0.05; camera.camera?.zFar = 1000; camera.camera?.fieldOfView = 75; camera.camera?.projectionDirection = .vertical
            scene.rootNode.addChildNode(camera)
            scene.rootNode.addChildNode(markers)
            let floor = SCNNode(geometry: SCNPlane(width: CGFloat(max(maximum.x - minimum.x, 1)), height: CGFloat(max(maximum.z - minimum.z, 1))))
            floor.name = "navigation-floor"; floor.categoryBitMask = 2
            floor.eulerAngles.x = -.pi / 2
            floor.position = SCNVector3((minimum.x + maximum.x) / 2, minimum.y + 0.005, (minimum.z + maximum.z) / 2)
            floor.geometry?.firstMaterial?.diffuse.contents = UIColor.systemTeal.withAlphaComponent(0.12)
            floor.geometry?.firstMaterial?.isDoubleSided = true
            scene.rootNode.addChildNode(floor)
            resetCamera(); updateMarkers()
        }
        func resetCamera() {
            guard let view else { return }
            let centre = SCNVector3((minimum.x + maximum.x) / 2, (minimum.y + maximum.y) / 2, (minimum.z + maximum.z) / 2)
            let extent = max(maximum.x - minimum.x, maximum.y - minimum.y, maximum.z - minimum.z, 1)
            view.pointOfView = camera
            if parent.mode == .orbit {
                camera.position = SCNVector3(centre.x + extent, centre.y + extent, centre.z + extent * 1.5)
                camera.look(at: centre)
                view.defaultCameraController.target = centre
            } else {
                let floorCentre = SCNVector3(centre.x, minimum.y + min(1.6, max((maximum.y - minimum.y) * 0.6, 0.5)), centre.z)
                camera.position = nearestFreePosition(to: floorCentre) ?? floorCentre
                yaw = -0.25; pitch = -0.45; camera.eulerAngles = SCNVector3(pitch, yaw, 0)
            }
        }
        func updateMarkers() {
            guard shownDevices != parent.devices else { return }
            shownDevices = parent.devices
            markers.childNodes.forEach { $0.removeFromParentNode() }
            for device in parent.devices {
                let marker = SCNNode(geometry: SCNSphere(radius: 0.13))
                marker.name = device.id.uuidString; marker.categoryBitMask = 4
                marker.position = SCNVector3(device.position.x, device.position.y, device.position.z)
                marker.geometry?.firstMaterial?.diffuse.contents = UIColor.systemOrange
                marker.geometry?.firstMaterial?.emission.contents = UIColor.systemOrange.withAlphaComponent(0.4)
                let label = SCNText(string: device.name, extrusionDepth: 0)
                label.font = .systemFont(ofSize: 0.16, weight: .semibold)
                label.flatness = 0.2
                label.firstMaterial?.diffuse.contents = UIColor.label
                let text = SCNNode(geometry: label); text.position = SCNVector3(0.16, 0.12, 0); text.categoryBitMask = 4
                text.constraints = [SCNBillboardConstraint()]
                marker.addChildNode(text); markers.addChildNode(marker)
            }
        }
        @objc func tap(_ gesture: UITapGestureRecognizer) {
            guard let view else { return }
            let point = gesture.location(in: view)
            let hits = view.hitTest(point, options: [.categoryBitMask: parent.placing ? 3 : 7, .backFaceCulling: false, .searchMode: SCNHitTestSearchMode.all.rawValue])

            if !parent.placing {
                for hit in hits where hit.node.categoryBitMask == 4 {
                    var node: SCNNode? = hit.node
                    while let candidate = node {
                        if let device = parent.devices.first(where: { $0.id.uuidString == candidate.name }) { parent.onSelect(device); return }
                        node = candidate.parent
                    }
                }
            }
            guard let hit = hits.first(where: { $0.node.categoryBitMask != 4 }) else { return }
            if parent.placing {
                let position = hit.worldCoordinates
                let normal = hit.worldNormal
                parent.onPlace(RoomPosition(x: position.x + normal.x * 0.08, y: position.y + normal.y * 0.08, z: position.z + normal.z * 0.08))
            } else if parent.mode == .walk {
                guard hit.node.name == "navigation-floor" || (hit.worldNormal.y > 0.7 && abs(hit.worldCoordinates.y - minimum.y) < 0.15) else { return }
                let target = SCNVector3(hit.worldCoordinates.x, camera.position.y, hit.worldCoordinates.z)
                // Conservative room-scale movement; no teleporting through walls or captured furniture.
                guard clearPath(from: camera.position, to: target) else { parent.onError("That path crosses a wall or object. Choose a closer floor position."); return }
                SCNTransaction.begin(); SCNTransaction.animationDuration = 0.35; camera.position = target; SCNTransaction.commit()
            }
        }
        private func clearPath(from start: SCNVector3, to end: SCNVector3) -> Bool {
            guard let root = view?.scene?.rootNode else { return false }
            // Check at camera and waist height to include low furniture.
            for offset: Float in [0, -0.8] {
                let a = SCNVector3(start.x, start.y + offset, start.z)
                let b = SCNVector3(end.x, end.y + offset, end.z)
                if !root.hitTestWithSegment(from: a, to: b, options: [SCNHitTestOption.categoryBitMask.rawValue: 1, SCNHitTestOption.backFaceCulling.rawValue: false]).isEmpty { return false }
            }
            return true
        }
        private func nearestFreePosition(to centre: SCNVector3) -> SCNVector3? {
            // Prefer a floor point whose vertical clearance is free of captured furniture.
            for dx: Float in [0, -0.5, 0.5, -1, 1] {
                for dz: Float in [0, -0.5, 0.5, -1, 1] {
                    let x = centre.x + dx, z = centre.z + dz
                    guard x > minimum.x + 0.15, x < maximum.x - 0.15, z > minimum.z + 0.15, z < maximum.z - 0.15 else { continue }
                    let floor = SCNVector3(x, minimum.y + 0.1, z)
                    let eye = SCNVector3(x, centre.y, z)
                    if view?.scene?.rootNode.hitTestWithSegment(from: floor, to: eye, options: [SCNHitTestOption.categoryBitMask.rawValue: 1, SCNHitTestOption.backFaceCulling.rawValue: false]).isEmpty == true { return eye }
                }
            }
            return nil
        }
        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool { parent.mode == .walk && !parent.placing }
        @objc func pan(_ gesture: UIPanGestureRecognizer) {
            guard parent.mode == .walk, !parent.placing else { return }
            let translation = gesture.translation(in: view)
            yaw -= Float(translation.x) * 0.005
            pitch = max(-1.1, min(1.1, pitch - Float(translation.y) * 0.005))
            camera.eulerAngles = SCNVector3(pitch, yaw, 0)
            gesture.setTranslation(.zero, in: view)
        }
    }
}
