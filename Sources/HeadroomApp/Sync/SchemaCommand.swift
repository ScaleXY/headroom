import CoreData
import Foundation
import HeadroomSync
import SwiftData

/// `HeadroomApp --init-cloudkit-schema`: creates every record type the sync store uses in the
/// iCloud container's **Development** environment, so the schema can be deployed to Production
/// from the CloudKit Console. Needs a build signed with `CLOUDKIT_ENV=Development`. Run it again,
/// and deploy again, whenever `HeadroomSchemaV*` gains a model or a field.
enum SchemaCommand {
    static func run() -> Int32 {
        guard SyncCapability.isEntitled else {
            print("This build has no iCloud entitlement. Build with PROFILE=… CLOUDKIT_ENV=Development (see plans/ios-app/NEXT-STEPS.md).")
            return 1
        }
        guard let model = NSManagedObjectModel.makeManagedObjectModel(for: HeadroomSchemaV1.models) else {
            print("Couldn't build the managed object model from HeadroomSchemaV1.")
            return 1
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("headroom-schema-\(UUID().uuidString).store")
        let container = NSPersistentCloudKitContainer(name: "Headroom", managedObjectModel: model)
        let description = NSPersistentStoreDescription(url: url)
        description.cloudKitContainerOptions = NSPersistentCloudKitContainerOptions(containerIdentifier: SyncContainer.cloudKitIdentifier)
        description.shouldAddStoreAsynchronously = false
        container.persistentStoreDescriptions = [description]
        let failure = LoadFailure()
        container.loadPersistentStores { _, error in failure.error = error }
        if let error = failure.error {
            print("Couldn't open the store: \(error)")
            return 1
        }
        do {
            try container.initializeCloudKitSchema(options: [])
        } catch {
            print("CloudKit refused the schema: \(error)")
            return 1
        }
        for store in container.persistentStoreCoordinator.persistentStores { try? container.persistentStoreCoordinator.remove(store) }
        try? FileManager.default.removeItem(at: url)
        print("Created \(HeadroomSchemaV1.models.count) record types in \(SyncContainer.cloudKitIdentifier) (Development).")
        print("Next: CloudKit Console → \(SyncContainer.cloudKitIdentifier) → Deploy Schema Changes.")
        return 0
    }

    private final class LoadFailure: @unchecked Sendable { var error: Error? }
}
