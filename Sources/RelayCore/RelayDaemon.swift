import Darwin
import Foundation

public final class RelayProcessingLease: @unchecked Sendable {
    public let paths: RelayStorePaths
    private let descriptor: Int32

    public init(
        paths: RelayStorePaths,
        fileManager: FileManager = .default
    ) throws {
        self.paths = paths
        try fileManager.createDirectory(at: paths.root, withIntermediateDirectories: true)

        let descriptor = open(paths.processingLock.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else {
            throw RelayError.storage("failed to open processor lock")
        }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            throw RelayError.storage("another processor is already active for this store")
        }
        self.descriptor = descriptor
    }

    deinit {
        flock(descriptor, LOCK_UN)
        close(descriptor)
    }
}

public struct RelayDaemonHealth: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var processID: Int32
    public var startedAt: Date
    public var lastPassAt: Date
    public var passCount: Int
    public var applied: Int
    public var duplicates: Int
    public var stale: Int
    public var quarantined: Int
    public var lastError: String?

    public init(
        processID: Int32 = getpid(),
        startedAt: Date = Date(),
        lastPassAt: Date = Date(),
        passCount: Int = 0,
        applied: Int = 0,
        duplicates: Int = 0,
        stale: Int = 0,
        quarantined: Int = 0,
        lastError: String? = nil
    ) {
        schemaVersion = 1
        self.processID = processID
        self.startedAt = startedAt
        self.lastPassAt = lastPassAt
        self.passCount = passCount
        self.applied = applied
        self.duplicates = duplicates
        self.stale = stale
        self.quarantined = quarantined
        self.lastError = lastError
    }

    public mutating func record(_ report: ProcessingReport, at date: Date = Date()) {
        lastPassAt = date
        passCount += 1
        applied += report.applied
        duplicates += report.duplicates
        stale += report.stale
        quarantined += report.quarantined
        lastError = nil
    }

    public mutating func record(error: Error, at date: Date = Date()) {
        lastPassAt = date
        passCount += 1
        lastError = error.localizedDescription
    }
}

public struct RelayDaemonHealthStore: Sendable {
    public let paths: RelayStorePaths

    public init(paths: RelayStorePaths) {
        self.paths = paths
    }

    public func load(fileManager: FileManager = .default) throws -> RelayDaemonHealth? {
        guard fileManager.fileExists(atPath: paths.daemonHealth.path) else { return nil }
        do {
            let data = try Data(contentsOf: paths.daemonHealth)
            return try RelayJSON.makeDecoder().decode(RelayDaemonHealth.self, from: data)
        } catch {
            throw RelayError.storage("failed to load daemon health: \(error.localizedDescription)")
        }
    }

    public func persist(
        _ health: RelayDaemonHealth,
        fileManager: FileManager = .default
    ) throws {
        do {
            try fileManager.createDirectory(at: paths.root, withIntermediateDirectories: true)
            let data = try RelayJSON.makeEncoder(prettyPrinted: true).encode(health)
            try data.write(to: paths.daemonHealth, options: [.atomic])
        } catch {
            throw RelayError.storage("failed to persist daemon health: \(error.localizedDescription)")
        }
    }
}
