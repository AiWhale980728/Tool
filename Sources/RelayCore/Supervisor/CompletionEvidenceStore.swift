import Foundation

public struct StoredCompletionEvidenceObservation: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID { observation.id }
    public var task: SupervisorTaskIdentity
    public var observation: CompletionReviewEvidenceObservation
    public var recordedAt: Date
    public var expiresAt: Date

    public init(
        task: SupervisorTaskIdentity,
        observation: CompletionReviewEvidenceObservation,
        recordedAt: Date,
        expiresAt: Date
    ) {
        self.task = task
        self.observation = observation
        self.recordedAt = recordedAt
        self.expiresAt = expiresAt
    }
}

public struct CompletionEvidenceStoreSnapshot: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var records: [StoredCompletionEvidenceObservation]

    public init(
        schemaVersion: Int = currentSchemaVersion,
        records: [StoredCompletionEvidenceObservation] = []
    ) {
        self.schemaVersion = schemaVersion
        self.records = records
    }

    @discardableResult
    public mutating func pruneExpired(now: Date = Date()) -> Int {
        let originalCount = records.count
        records = records.filter { $0.expiresAt > now }
        return originalCount - records.count
    }
}

public struct CompletionEvidenceStore: Sendable {
    public static let maximumRecordCount = 256
    public static let maximumRetention: TimeInterval = 24 * 60 * 60
    public let fileURL: URL

    public init(root: URL) {
        fileURL = root
            .appendingPathComponent("supervisor", isDirectory: true)
            .appendingPathComponent("completion-evidence.json", isDirectory: false)
    }

    public func load(fileManager: FileManager = .default) throws -> CompletionEvidenceStoreSnapshot {
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return CompletionEvidenceStoreSnapshot()
        }
        do {
            let data = try Data(contentsOf: fileURL)
            let snapshot = try RelayJSON.makeDecoder().decode(
                CompletionEvidenceStoreSnapshot.self,
                from: data
            )
            guard snapshot.schemaVersion == CompletionEvidenceStoreSnapshot.currentSchemaVersion else {
                throw RelayError.storage("unsupported Completion Evidence store schema")
            }
            return snapshot
        } catch let error as RelayError {
            throw error
        } catch {
            throw RelayError.storage("failed to load Completion Evidence store")
        }
    }

    public func persist(
        _ snapshot: CompletionEvidenceStoreSnapshot,
        fileManager: FileManager = .default
    ) throws {
        do {
            try fileManager.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try RelayJSON.makeEncoder(prettyPrinted: true).encode(snapshot)
            try data.write(to: fileURL, options: [.atomic])
        } catch {
            throw RelayError.storage("failed to persist Completion Evidence store")
        }
    }

    public func record(
        _ observations: [CompletionReviewEvidenceObservation],
        for session: RelaySessionState,
        now: Date = Date(),
        lifetime: TimeInterval = 10 * 60,
        fileManager: FileManager = .default
    ) throws -> [CompletionReviewEvidenceObservation] {
        let task = SupervisorTaskIdentity(
            source: session.source,
            taskID: session.key,
            sessionID: session.sessionID,
            triggerEventID: session.lastEventID
        )
        let boundedLifetime = min(max(1, lifetime), Self.maximumRetention)
        var snapshot = try load(fileManager: fileManager)
        snapshot.pruneExpired(now: now)

        for candidate in observations.filter(\.isUsable) {
            if let index = snapshot.records.firstIndex(where: {
                $0.task == task && Self.sameSourceIdentity($0.observation, candidate)
            }) {
                var stable = candidate
                stable.id = snapshot.records[index].observation.id
                snapshot.records[index] = StoredCompletionEvidenceObservation(
                    task: task,
                    observation: stable,
                    recordedAt: now,
                    expiresAt: now.addingTimeInterval(boundedLifetime)
                )
            } else {
                snapshot.records.append(StoredCompletionEvidenceObservation(
                    task: task,
                    observation: candidate,
                    recordedAt: now,
                    expiresAt: now.addingTimeInterval(boundedLifetime)
                ))
            }
        }

        snapshot.records = Array(snapshot.records
            .sorted { $0.recordedAt < $1.recordedAt }
            .suffix(Self.maximumRecordCount))
        try persist(snapshot, fileManager: fileManager)
        return snapshot.records
            .filter { $0.task == task && $0.expiresAt > now }
            .sorted { $0.recordedAt < $1.recordedAt }
            .map(\.observation)
    }

    public func deleteTask(
        _ sessionKey: String,
        fileManager: FileManager = .default
    ) throws {
        var snapshot = try load(fileManager: fileManager)
        snapshot.records.removeAll { $0.task.taskID == sessionKey }
        try persist(snapshot, fileManager: fileManager)
    }

    @discardableResult
    public func pruneExpired(
        now: Date = Date(),
        fileManager: FileManager = .default
    ) throws -> Int {
        var snapshot = try load(fileManager: fileManager)
        let removed = snapshot.pruneExpired(now: now)
        if removed > 0 { try persist(snapshot, fileManager: fileManager) }
        return removed
    }

    private static func sameSourceIdentity(
        _ lhs: CompletionReviewEvidenceObservation,
        _ rhs: CompletionReviewEvidenceObservation
    ) -> Bool {
        lhs.kind == rhs.kind
            && lhs.source == rhs.source
            && lhs.reference == rhs.reference
    }
}
