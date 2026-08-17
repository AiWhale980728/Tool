import Foundation

public struct RelayStorePaths: Equatable, Sendable {
    public var root: URL

    public init(root: URL) {
        self.root = root.standardizedFileURL
    }

    public static func defaultRoot(fileManager: FileManager = .default) throws -> URL {
        guard let applicationSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            throw RelayError.storage("Application Support directory is unavailable")
        }
        return applicationSupport.appendingPathComponent("NotchRelay", isDirectory: true)
    }

    public var inbox: URL { root.appendingPathComponent("inbox", isDirectory: true) }
    public var archive: URL { root.appendingPathComponent("archive", isDirectory: true) }
    public var quarantine: URL { root.appendingPathComponent("quarantine", isDirectory: true) }
    public var snapshot: URL { root.appendingPathComponent("state.json", isDirectory: false) }
    public var processingLock: URL { root.appendingPathComponent("processor.lock", isDirectory: false) }
    public var applicationInstanceLock: URL {
        root.appendingPathComponent("application-instance.lock", isDirectory: false)
    }
    public var daemonHealth: URL { root.appendingPathComponent("daemon.json", isDirectory: false) }
}

public struct EventSpool: Sendable {
    public let paths: RelayStorePaths

    public init(root: URL) {
        paths = RelayStorePaths(root: root)
    }

    public init(paths: RelayStorePaths) {
        self.paths = paths
    }

    public func prepare(fileManager: FileManager = .default) throws {
        do {
            try fileManager.createDirectory(at: paths.inbox, withIntermediateDirectories: true)
            try fileManager.createDirectory(at: paths.archive, withIntermediateDirectories: true)
            try fileManager.createDirectory(at: paths.quarantine, withIntermediateDirectories: true)
        } catch {
            throw RelayError.storage(error.localizedDescription)
        }
    }

    @discardableResult
    public func enqueue(
        _ event: RelayEvent,
        fileManager: FileManager = .default
    ) throws -> URL {
        try prepare(fileManager: fileManager)

        let encoder = RelayJSON.makeEncoder()
        let data: Data
        do {
            data = try encoder.encode(event)
        } catch {
            throw RelayError.storage("failed to encode event: \(error.localizedDescription)")
        }

        let timestamp = Int64(event.receivedAt.timeIntervalSince1970 * 1_000)
        let fileName = String(format: "%013lld-%@.json", timestamp, event.id.uuidString.lowercased())
        let temporaryURL = paths.inbox.appendingPathComponent(".\(fileName).tmp")
        let finalURL = paths.inbox.appendingPathComponent(fileName)

        do {
            try data.write(to: temporaryURL, options: [.atomic])
            try fileManager.moveItem(at: temporaryURL, to: finalURL)
            return finalURL
        } catch {
            try? fileManager.removeItem(at: temporaryURL)
            throw RelayError.storage("failed to enqueue event: \(error.localizedDescription)")
        }
    }

    public func pendingFiles(fileManager: FileManager = .default) throws -> [URL] {
        try prepare(fileManager: fileManager)
        do {
            return try fileManager.contentsOfDirectory(
                at: paths.inbox,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        } catch {
            throw RelayError.storage("failed to list inbox: \(error.localizedDescription)")
        }
    }

    public func readEvent(at url: URL) throws -> RelayEvent {
        do {
            let data = try Data(contentsOf: url)
            let event = try RelayJSON.makeDecoder().decode(RelayEvent.self, from: data)
            guard RelayEvent.supportedSchemaVersions.contains(event.schemaVersion) else {
                throw RelayError.storage(
                    "unsupported event schema version \(event.schemaVersion) in \(url.lastPathComponent)"
                )
            }
            return event
        } catch {
            if let relayError = error as? RelayError {
                throw relayError
            }
            throw RelayError.storage("failed to decode \(url.lastPathComponent): \(error.localizedDescription)")
        }
    }

    public func archive(_ file: URL, fileManager: FileManager = .default) throws {
        try move(file, to: paths.archive, fileManager: fileManager)
    }

    public func quarantine(_ file: URL, fileManager: FileManager = .default) throws {
        try move(file, to: paths.quarantine, fileManager: fileManager)
    }

    private func move(_ file: URL, to directory: URL, fileManager: FileManager) throws {
        try prepare(fileManager: fileManager)
        var destination = directory.appendingPathComponent(file.lastPathComponent)
        if fileManager.fileExists(atPath: destination.path) {
            destination = directory.appendingPathComponent(
                "\(file.deletingPathExtension().lastPathComponent)-\(UUID().uuidString.lowercased()).json"
            )
        }

        do {
            try fileManager.moveItem(at: file, to: destination)
        } catch {
            throw RelayError.storage("failed to move \(file.lastPathComponent): \(error.localizedDescription)")
        }
    }
}

public struct RelayStateStore: Sendable {
    public let paths: RelayStorePaths

    public init(paths: RelayStorePaths) {
        self.paths = paths
    }

    public func load(fileManager: FileManager = .default) throws -> RelaySnapshot {
        guard fileManager.fileExists(atPath: paths.snapshot.path) else {
            return RelaySnapshot()
        }
        do {
            let data = try Data(contentsOf: paths.snapshot)
            var snapshot = try RelayJSON.makeDecoder().decode(RelaySnapshot.self, from: data)
            guard RelaySnapshot.supportedSchemaVersions.contains(snapshot.schemaVersion) else {
                throw RelayError.storage(
                    "unsupported state schema version \(snapshot.schemaVersion)"
                )
            }
            snapshot.migrateToCurrentSchema()
            return snapshot
        } catch {
            if let relayError = error as? RelayError {
                throw relayError
            }
            throw RelayError.storage("failed to load state snapshot: \(error.localizedDescription)")
        }
    }

    public func persist(
        _ snapshot: RelaySnapshot,
        fileManager: FileManager = .default
    ) throws {
        do {
            try fileManager.createDirectory(at: paths.root, withIntermediateDirectories: true)
            let data = try RelayJSON.makeEncoder(prettyPrinted: true).encode(snapshot)
            try data.write(to: paths.snapshot, options: [.atomic])
        } catch {
            throw RelayError.storage("failed to persist state snapshot: \(error.localizedDescription)")
        }
    }
}

public struct ProcessingReport: Equatable, Sendable {
    public var applied = 0
    public var duplicates = 0
    public var stale = 0
    public var quarantined = 0
    public var cleanedUp = 0

    public init() {}

    public var total: Int { applied + duplicates + stale + quarantined + cleanedUp }
}

public struct RelayProcessor: Sendable {
    public let spool: EventSpool
    public let stateStore: RelayStateStore

    public init(root: URL) {
        let paths = RelayStorePaths(root: root)
        spool = EventSpool(paths: paths)
        stateStore = RelayStateStore(paths: paths)
    }

    public init(spool: EventSpool, stateStore: RelayStateStore) {
        self.spool = spool
        self.stateStore = stateStore
    }

    public func processPending(fileManager: FileManager = .default) throws -> ProcessingReport {
        let lease = try RelayProcessingLease(paths: spool.paths, fileManager: fileManager)
        return try processPending(holding: lease, fileManager: fileManager)
    }

    public func processPending(
        holding lease: RelayProcessingLease,
        fileManager: FileManager = .default
    ) throws -> ProcessingReport {
        guard lease.paths.root == spool.paths.root else {
            throw RelayError.storage("processor lease belongs to a different store")
        }
        let files = try spool.pendingFiles(fileManager: fileManager)
        var valid: [(file: URL, event: RelayEvent)] = []
        var report = ProcessingReport()

        for file in files {
            do {
                valid.append((file, try spool.readEvent(at: file)))
            } catch {
                try spool.quarantine(file, fileManager: fileManager)
                report.quarantined += 1
            }
        }

        valid.sort {
            if $0.event.occurredAt == $1.event.occurredAt {
                return $0.event.receivedAt < $1.event.receivedAt
            }
            return $0.event.occurredAt < $1.event.occurredAt
        }

        var snapshot = try stateStore.load(fileManager: fileManager)
        let attentionStore = LocalTaskAttentionStore(root: spool.paths.root)
        let protectedSessionKeys = Set(
            attentionStore.load().compactMap { key, level in
                level == .pinned ? key : nil
            }
        )
        let removed = snapshot.pruneExpired(protectedSessionKeys: protectedSessionKeys)
        report.cleanedUp = removed.count
        if !removed.isEmpty {
            try stateStore.persist(snapshot, fileManager: fileManager)
        }
        for item in valid {
            let result = snapshot.apply(item.event)
            try stateStore.persist(snapshot, fileManager: fileManager)
            try spool.archive(item.file, fileManager: fileManager)

            switch result {
            case .applied:
                report.applied += 1
            case .duplicateID, .duplicateFingerprint:
                report.duplicates += 1
            case .stale:
                report.stale += 1
            }
        }

        let newlyExpired = snapshot.pruneExpired(protectedSessionKeys: protectedSessionKeys)
        if !newlyExpired.isEmpty {
            report.cleanedUp += newlyExpired.count
            try stateStore.persist(snapshot, fileManager: fileManager)
        }
        try? attentionStore.prune(keeping: Set(snapshot.sessions.keys))

        return report
    }
}
