import Foundation
import RoomTwinCore

/// Explicitly synthetic geometry for exploring the UI without LiDAR hardware.
enum SampleRoom {
    static func create(in store: RoomStore) async throws -> SavedRoom {
        guard let source = Bundle.main.url(forResource: "SampleRoom", withExtension: "usdz") else {
            throw EquipmentError.invalid("The sample model is missing from the app bundle.")
        }
        return try await Task.detached(priority: .userInitiated) {
            try store.save(name: "Sample room · simulated", elements: [], capturedJSON: Data("{\"source\":\"simulated\",\"sampleVersion\":2,\"description\":\"Synthetic room; not a RoomPlan scan\"}".utf8)) { destination in
                try FileManager.default.copyItem(at: source, to: destination)
            }
        }.value
    }
}
