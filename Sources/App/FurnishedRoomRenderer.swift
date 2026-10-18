import Foundation
import RoomPlan
import CryptoKit
import RoomTwinCore

enum RoomAppearance: String, CaseIterable { case furnished = "Furnished", scan = "Scan geometry" }

/// Re-renders the saved CapturedRoom with category/attribute models. Original files are never modified.
actor FurnishedRoomRenderer {
    static let shared = FurnishedRoomRenderer()
    func model(json: Data) async throws -> URL {
        if let metadata = try JSONSerialization.jsonObject(with: json) as? [String: Any], metadata["source"] as? String == "simulated" {
            guard metadata["sampleVersion"] as? Int == 2,
                  let sample = Bundle.main.url(forResource: "SampleRoomFurnished", withExtension: "usdz") else {
                throw EquipmentError.invalid("Add a new sample room from the library menu to preview furnished models.")
            }
            return sample
        }
        let cache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("Furnished-v1", isDirectory: true)
        let key = SHA256.hash(data: json).map { String(format: "%02x", $0) }.joined()
        let output = cache.appendingPathComponent(key + ".usdz")
        if FileManager.default.fileExists(atPath: output.path) { return output }
        return try await Task.detached(priority: .userInitiated) {
            let room = try JSONDecoder().decode(CapturedRoom.self, from: json)
            let provider = try FurnitureCatalog.provider()
            try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
            let temporary = cache.appendingPathComponent(UUID().uuidString + ".usdz")
            defer { try? FileManager.default.removeItem(at: temporary) }
            try room.export(to: temporary, metadataURL: nil, modelProvider: provider, exportOptions: .model)
            guard (try temporary.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) > 0 else {
                throw EquipmentError.invalid("RoomPlan could not generate a furnished model.")
            }
            if !FileManager.default.fileExists(atPath: output.path) { try FileManager.default.moveItem(at: temporary, to: output) }
            return output
        }.value
    }
}

enum FurnitureCatalog {
    private struct Catalog: Decodable { let categoryAttributes: [Entry] }
    private struct Entry: Decodable {
        let category: CapturedRoom.Object.Category
        let attributes: CapturedRoom.AttributesCodableRepresentation
        let folderRelativePath: String
        let modelFilename: String?
    }
    static func provider() throws -> CapturedRoom.ModelProvider {
        guard let root = Bundle.main.url(forResource: "Furniture", withExtension: "bundle") else {
            throw EquipmentError.invalid("The furniture catalog is missing from the app.")
        }
        var provider = CapturedRoom.ModelProvider()
        for category in CapturedRoom.Object.Category.allCases {
            let url = root.appendingPathComponent("Generated/\(category).usdc")
            try provider.setModelFileURL(url, for: category)
        }
        let apple = root.appendingPathComponent("AppleCatalog")
        let catalog = try PropertyListDecoder().decode(Catalog.self, from: Data(contentsOf: apple.appendingPathComponent("catalog.plist")))
        for entry in catalog.categoryAttributes {
            guard let filename = entry.modelFilename else { continue }
            let file = apple.appendingPathComponent(entry.folderRelativePath).appendingPathComponent(filename)
            guard FileManager.default.fileExists(atPath: file.path) else { continue }
            if entry.attributes.attributes.isEmpty { try provider.setModelFileURL(file, for: entry.category) }
            else { try provider.setModelFileURL(file, for: entry.attributes.attributes) }
        }
        return provider
    }
}
