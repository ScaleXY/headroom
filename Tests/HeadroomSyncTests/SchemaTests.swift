import CoreData
import SwiftData
import Testing
@testable import HeadroomSync

/// What `--init-cloudkit-schema` sends to CloudKit: four entities, payloads and account keys encrypted.
@Suite struct SchemaTests {
    @Test func theSchemaBecomesTheModelCloudKitMirrors() throws {
        let model = try #require(NSManagedObjectModel.makeManagedObjectModel(for: HeadroomSchemaV1.models))
        #expect(Set(model.entities.compactMap(\.name)) == ["DeviceRecord", "AccountLiveRecord", "AccountArchiveRecord", "ActivityDayRecord"])
        for entity in model.entities {
            #expect(entity.relationshipsByName.isEmpty)
            #expect(entity.attributesByName["payload"]?.allowsCloudEncryption == true)
            if entity.name != "DeviceRecord" { #expect(entity.attributesByName["accountKey"]?.allowsCloudEncryption == true) }
            // CloudKit mirroring needs every attribute optional or defaulted.
            for a in entity.attributesByName.values { #expect(a.isOptional || a.defaultValue != nil, "\(entity.name ?? "").\(a.name)") }
        }
    }
}
