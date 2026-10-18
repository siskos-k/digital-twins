import SwiftUI
import Security
import RoomTwinCore

private enum TokenStorage {
    static let service = "personal.ntua.DigitalTwins.collector"
    static var query: [String: Any] { [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: "api-token"] }
    static func read() -> String {
        var parameters = query
        parameters[kSecReturnData as String] = true
        var result: CFTypeRef?
        guard SecItemCopyMatching(parameters as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return "" }
        return String(decoding: data, as: UTF8.self)
    }
    static func write(_ token: String) throws {
        let status: OSStatus
        if token.isEmpty {
            status = SecItemDelete(query as CFDictionary)
        } else {
            let attributes: [String: Any] = [kSecValueData as String: Data(token.utf8), kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
            let update = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
            if update == errSecItemNotFound { status = SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil) }
            else { status = update }
        }
        guard status == errSecSuccess || (token.isEmpty && status == errSecItemNotFound) else {
            throw EquipmentError.invalid("Could not store the API token securely (\(status)).")
        }
    }
}

enum CollectorConfiguration {
    static var endpoint: String { UserDefaults.standard.string(forKey: "collectorURL") ?? "" }
    static var configured: Bool { !endpoint.isEmpty && !TokenStorage.read().isEmpty }
    static func client() throws -> TelemetryClient { try TelemetryClient(endpoint: endpoint, token: TokenStorage.read()) }
}

struct IoTSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var endpoint = CollectorConfiguration.endpoint
    @State private var token = TokenStorage.read()
    @State private var status: String?
    @State private var testing = false
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("http://your-mac.local:8080", text: $endpoint).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    SecureField("API token", text: $token).textInputAutocapitalization(.never).autocorrectionDisabled()
                } header: { Text("Local collector") } footer: { Text("Use the collector on your trusted local network. HTTP sends data without encryption; use HTTPS for other networks. The token is stored in this iPhone's Keychain.") }
                Section {
                    Button(testing ? "Checking…" : "Test connection") {
                        testing = true
                        Task { @MainActor in
                            defer { testing = false }
                            do {
                                let health = try await TelemetryClient(endpoint: endpoint, token: token).health()
                                status = health.mqttConnected ? "Collector reachable · MQTT connected" : "Collector reachable · MQTT disconnected"
                                if let lastError = health.lastError { status = (status ?? "") + "\n" + lastError }
                            } catch { status = error.localizedDescription }
                        }
                    }.disabled(testing)
                    if let status { Text(status).font(.footnote) }
                }
            }
            .navigationTitle("IoT settings").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        do {
                            if !endpoint.isEmpty { _ = try TelemetryClient(endpoint: endpoint, token: token) }
                            try TokenStorage.write(token)
                            UserDefaults.standard.set(endpoint.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "collectorURL")
                            dismiss()
                        } catch { status = error.localizedDescription }
                    }
                }
            }
        }
    }
}
