//
//  ReadTransactionsStorageLiveKey.swift
//
//
//  Created by Lukáš Korba on 11.11.2023.
//

import ComposableArchitecture
import CoreData

extension ReadTransactionsStorageClient: DependencyKey {
    static let liveValue = Self.live()

    static func live() -> Self {
        Self(
            markIdAsRead: {
                let context = persistentContainer.viewContext

                if let entity = NSEntityDescription.entity(
                    forEntityName: ReadTransactionsStorageClient.Constants.entityName,
                    in: context
                ) {
                    let newRead = NSManagedObject(entity: entity, insertInto: context)

                    newRead.setValue($0.data, forKey: "id")

                    do {
                        try context.save()
                    } catch {
                        throw error
                    }
                } else {
                    throw ReadTransactionsStorageError.createEntity
                }
            },
            readIds: {
                let context = persistentContainer.viewContext

                let request = NSFetchRequest<NSFetchRequestResult>(entityName: ReadTransactionsStorageClient.Constants.entityName)
                request.returnsObjectsAsFaults = false

                do {
                    let result = try context.fetch(request)

                    if let managedObjects = result as? [NSManagedObject] {
                        let ids = managedObjects.compactMap { element in
                            (element.value(forKey: "id") as? String)?.redacted
                        }

                        var idsDict: [RedactableString: Bool] = [:]

                        ids.forEach { id in
                            idsDict[id] = true
                        }

                        return idsDict
                    }

                    return [:]
                } catch {
                    throw error
                }
            },
            availabilityTimestamp: {
                let context = persistentContainer.viewContext

                // check presence of the timestamp
                let request = NSFetchRequest<NSFetchRequestResult>(entityName: ReadTransactionsStorageClient.Constants.availabilityEntityName)
                request.returnsObjectsAsFaults = false

                do {
                    let result = try context.fetch(request)

                    if let managedObjects = result as? [NSManagedObject] {
                        // no timestamp stored, create one
                        if managedObjects.isEmpty {
                            if let entity = NSEntityDescription.entity(
                                forEntityName: ReadTransactionsStorageClient.Constants.availabilityEntityName,
                                in: context
                            ) {
                                let newAvailability = NSManagedObject(entity: entity, insertInto: context)
                                let now = Date.now.timeIntervalSince1970

                                newAvailability.setValue(now, forKey: "timestamp")

                                do {
                                    try context.save()
                                } catch {
                                    throw error
                                }

                                return now
                            } else {
                                throw ReadTransactionsStorageError.createEntity
                            }
                        } else {
                            if let timestamp = managedObjects.first?.value(forKey: "timestamp") as? TimeInterval {
                                return timestamp
                            }

                            throw ReadTransactionsStorageError.availability
                        }
                    } else {
                        throw ReadTransactionsStorageError.availability
                    }
                } catch {
                    throw error
                }
            },
            resetZashi: {
                let context = persistentContainer.viewContext

                let deleteRequestIds = NSBatchDeleteRequest(
                    fetchRequest: NSFetchRequest<NSFetchRequestResult>(
                        entityName: ReadTransactionsStorageClient.Constants.entityName
                    )
                )
                let deleteRequestTimestamp = NSBatchDeleteRequest(
                    fetchRequest: NSFetchRequest<NSFetchRequestResult>(
                        entityName: ReadTransactionsStorageClient.Constants.availabilityEntityName
                    )
                )

                do {
                    try context.execute(deleteRequestIds)
                    try context.execute(deleteRequestTimestamp)
                    try context.save()
                } catch {
                    throw error
                }
            }
        )
    }
}

private extension ReadTransactionsStorageClient {
    static let persistentContainer: NSPersistentContainer = {
        let container = NSPersistentContainer(name: ReadTransactionsStorageClient.Constants.modelName)
        
        container.loadPersistentStores { description, error in
            if let error = error {
                fatalError("Unable to load persistent stores: \(error)")
            }
        }
        
        return container
    }()
}
