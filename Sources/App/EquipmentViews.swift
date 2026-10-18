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
        do {
            if let existing = devices.first(where: { $0.id == device.id }), let endpoint = existing.collectorEndpoint, existing.topic != device.topic {
                guard CollectorConfiguration.endpoint == endpoint else { throw EquipmentError.invalid("Select the original collector in IoT settings before changing a linked topic.") }
                try await CollectorConfiguration.client().register(device)
            }
            try await store.save(device); await load(); return true
        }
        catch { self.error = error.localizedDescription; return false }
    }
    func delete(_ device: Equipment) async -> Bool {
        guard let store else { return false }
        do {
            // Remove remote registration first so a deleted device stops collecting.
            if let endpoint = device.collectorEndpoint {
                guard CollectorConfiguration.endpoint == endpoint else { throw EquipmentError.invalid("Select the original collector in IoT settings before deleting linked equipment.") }
                try await CollectorConfiguration.client().delete(id: device.id)
            }
            try await store.delete(id: device.id); await load(); return true
        } catch { self.error = error.localizedDescription; return false }
    }
    func markRegistered(_ device: Equipment) async throws {
        guard let store, var current = devices.first(where: { $0.id == device.id }), current.topic == device.topic else {
            throw EquipmentError.invalid("Equipment changed during connection. Connect again.")
        }
        current.collectorEndpoint = CollectorConfiguration.endpoint
        try await store.save(current)
        await load()
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
                Section("MQTT") {
                    TextField("Exact topic, e.g. room1/sensor1", text: $device.topic).textInputAutocapitalization(.never).autocorrectionDisabled()
                    Text("Leave blank for inventory only. After saving, open the equipment and tap Connect & refresh to register its topic with the collector.").font(.footnote).foregroundStyle(.secondary)
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
    @State private var status = "Cached readings"
    @State private var editing: Equipment?
    @State private var showSettings = false
    @State private var confirmDelete = false
    @State private var refreshing = false
    @State private var connected = false
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
                    Section("MQTT readings") {
                        if device.topic.isEmpty { Text("No MQTT topic configured. Edit this equipment to add one.").foregroundStyle(.secondary) }
                        else {
                            Text(device.topic).font(.caption.monospaced())
                            Button(refreshing ? "Refreshing…" : "Connect & refresh") { Task { await refresh(device, register: true) } }.disabled(refreshing)
                            Button("IoT settings") { showSettings = true }
                        }
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
                            Text("Values remain cached when the collector is unavailable. Readings older than 60 seconds are labelled stale.").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Section { Button("Delete equipment", role: .destructive) { confirmDelete = true } }
                    if let error = inventory.error { Text(error).foregroundStyle(.red) }
                }
            }
            .navigationTitle(device?.name ?? "Equipment").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .sheet(item: $editing) { EquipmentEditor(inventory: inventory, device: $0) }
            .sheet(isPresented: $showSettings) { IoTSettingsView() }
            .confirmationDialog("Delete this equipment and its cached readings?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete", role: .destructive) { if let device { Task { if await inventory.delete(device) { dismiss() } } } }
            }
            .task {
                do { readings = try await inventory.readings(id: id); chooseMetric() }
                catch { status = error.localizedDescription }
                // A successful manual connection enables polling while this screen is open.
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(5)) } catch { return }
                    if connected, let device { await refresh(device) }
                }
            }
        }
    }
    private func chooseMetric() { if !readings.contains(where: { $0.metric == selectedMetric }) { selectedMetric = latest.first?.metric ?? "" } }
    @MainActor private func refresh(_ device: Equipment, register: Bool = false) async {
        guard !refreshing else { return }
        refreshing = true; defer { refreshing = false }
        do {
            if let endpoint = device.collectorEndpoint, endpoint != CollectorConfiguration.endpoint {
                throw EquipmentError.invalid("Select this equipment's original collector in IoT settings.")
            }
            let client = try CollectorConfiguration.client()
            if register {
                try await client.register(device)
                try await inventory.markRegistered(device)
            }
            let health = try await client.health()
            let values = try await client.readings(id: id)
            try await inventory.cache(values, id: id)
            readings = try await inventory.readings(id: id); chooseMetric(); connected = true
            status = health.mqttConnected ? "Collector online · MQTT connected" : "Collector online · MQTT disconnected (showing stored readings)"
            if let error = health.lastError { status += "\n\(error)" }
        } catch {
            if !Task.isCancelled { status = "Offline / unable to refresh: \(error.localizedDescription). Showing cached readings." }
        }
    }
}
