import SwiftUI
import Charts
import RoomTwinCore

@MainActor
final class EquipmentRoomModel: ObservableObject {
    @Published var devices: [Equipment] = []
    @Published var error: String?
    private var store: EquipmentStore?
    let roomID: UUID
    init(roomID: UUID) {
        self.roomID = roomID
        do {
            let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            store = try EquipmentStore(url: root.appendingPathComponent("equipment.sqlite"))
        } catch { self.error = error.localizedDescription }
    }
    func load() async {
        guard let store else { return }
        do { devices = try await store.devices(roomID: roomID) }
        catch { self.error = error.localizedDescription }
    }
    func save(_ device: Equipment) async -> Bool {
        guard let store else { error = "Equipment database is unavailable."; return false }
        do { try await store.save(device); await load(); return true }
        catch { self.error = error.localizedDescription; return false }
    }
    func delete(_ device: Equipment) async -> Bool {
        guard let store else { return false }
        do { try await store.delete(id: device.id); await load(); return true }
        catch { self.error = error.localizedDescription; return false }
    }
    func cache(_ readings: [TelemetryReading], id: UUID) async throws {
        guard let store else { throw EquipmentError.invalid("Equipment database is unavailable.") }
        try await store.cache(readings, for: id)
    }
    func readings(id: UUID) async throws -> [TelemetryReading] {
        guard let store else { throw EquipmentError.invalid("Equipment database is unavailable.") }
        return try await store.readings(deviceID: id)
    }
}

struct EquipmentEditor: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var inventory: EquipmentRoomModel
    @State var device: Equipment
    @State private var saving = false
    var body: some View {
        NavigationStack {
            Form {
                Section("Equipment") {
                    TextField("Name", text: $device.name)
                    Picker("Category", selection: $device.kind) { ForEach(EquipmentKind.allCases) { Text($0.rawValue).tag($0) } }
                    TextField("Manufacturer", text: $device.manufacturer)
                    TextField("Model", text: $device.model)
                    TextField("Notes", text: $device.notes, axis: .vertical)
                }
                Section("Position in room · metres") {
                    Text(String(format: "x %.2f · y %.2f · z %.2f", device.position.x, device.position.y, device.position.z))
                    Text("Use Move marker on the equipment details screen to change its position.").font(.footnote).foregroundStyle(.secondary)
                }
                if let error = inventory.error { Text(error).foregroundStyle(.red) }
            }
            .navigationTitle("Equipment").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(saving) }
                ToolbarItem(placement: .confirmationAction) {
                    Button(saving ? "Saving…" : "Save") {
                        saving = true
                        Task { @MainActor in if await inventory.save(device) { dismiss() }; saving = false }
                    }.disabled(saving || device.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }.interactiveDismissDisabled(saving)
    }
}

struct EquipmentDetail: View {
    let id: UUID
    @ObservedObject var inventory: EquipmentRoomModel
    let move: (Equipment) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var readings: [TelemetryReading] = []
    @State private var status = "Stored on this iPhone"
    @Environment(\.scenePhase) private var scenePhase
    @State private var editing: Equipment?
    @State private var confirmDelete = false
    @State private var simulating = false
    @State private var selectedMetric = ""
    private var device: Equipment? { inventory.devices.first { $0.id == id } }
    private var latest: [TelemetryReading] {
        Dictionary(grouping: readings, by: \.metric).values.compactMap { $0.max { $0.timestamp < $1.timestamp } }.sorted { $0.metric < $1.metric }
    }
    var body: some View {
        NavigationStack {
            List {
                if let device {
                    Section {
                        Label(device.kind.rawValue, systemImage: device.kind.symbol)
                        if !device.manufacturer.isEmpty || !device.model.isEmpty { Text("\(device.manufacturer) \(device.model)") }
                        if !device.notes.isEmpty { Text(device.notes) }
                        Button("Edit equipment") { editing = device }
                        Button("Move marker") { move(device); dismiss() }
                    }
                    Section("Local demo readings") {
                        Button(simulating ? "Stop demo readings" : "Start demo readings") { simulating.toggle() }
                        Text("Generated on this iPhone for demonstration. These are not measurements from a physical device.").font(.footnote).foregroundStyle(.secondary)
                        Text(status).font(.footnote).foregroundStyle(.secondary)
                        if latest.isEmpty { Text("No readings yet").foregroundStyle(.secondary) }
                        ForEach(latest) { reading in
                            VStack(alignment: .leading) {
                                HStack {
                                    Text(reading.metric)
                                    Spacer()
                                    Text("\(reading.value, specifier: "%.2f") \(reading.unit)").monospacedDigit()
                                }
                                Text("\(reading.source == "simulated" ? "SIMULATED · " : "")\(reading.date.formatted())\(Date().timeIntervalSince(reading.date) > 60 ? " · Stale" : "")")
                                    .font(.caption).foregroundStyle(reading.source == "simulated" ? .orange : .secondary)
                            }
                        }
                    }
                    if !readings.isEmpty {
                        Section("History · latest 500 readings") {
                            let metrics = Array(Set(readings.map(\.metric))).sorted()
                            Picker("Measurement", selection: $selectedMetric) { ForEach(metrics, id: \.self) { Text($0).tag($0) } }
                            Chart(readings.filter { $0.metric == selectedMetric }.sorted { $0.timestamp < $1.timestamp }) {
                                LineMark(x: .value("Time", $0.date), y: .value($0.unit, $0.value), series: .value("Source", $0.source))
                            }.frame(height: 180)
                            Text("History is stored locally. Demo generation stops when this screen closes or the app leaves the foreground.").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Section { Button("Delete equipment", role: .destructive) { confirmDelete = true } }
                    if let error = inventory.error { Text(error).foregroundStyle(.red) }
                }
            }
            .navigationTitle(device?.name ?? "Equipment").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .sheet(item: $editing) { EquipmentEditor(inventory: inventory, device: $0) }
            .confirmationDialog("Delete this equipment and its cached readings?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete", role: .destructive) { if let device { Task { if await inventory.delete(device) { dismiss() } } } }
            }
            .task {
                do { readings = try await inventory.readings(id: id); chooseMetric() }
                catch { status = error.localizedDescription }
            }
            .task(id: simulating) {
                guard simulating else { return }
                while !Task.isCancelled, scenePhase == .active, let device {
                    do {
                        try await inventory.cache(DemoTelemetry.readings(for: device), id: id)
                        readings = try await inventory.readings(id: id); chooseMetric()
                        status = "SIMULATED · saved on this iPhone"
                        try await Task.sleep(for: .seconds(2))
                    } catch is CancellationError { return }
                    catch { status = error.localizedDescription; simulating = false; return }
                }
            }
            .onChange(of: scenePhase) { _, value in if value != .active { simulating = false } }
        }
    }
    private func chooseMetric() { if !readings.contains(where: { $0.metric == selectedMetric }) { selectedMetric = latest.first?.metric ?? "" } }
}
