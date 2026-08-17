import Foundation

public enum RelayTelemetryEventName: String, Codable, CaseIterable, Sendable {
    case appLaunched = "app_launched"
    case launcherOpened = "launcher_opened"
    case launcherHintShown = "launcher_hint_shown"
    case launcherHintDismissed = "launcher_hint_dismissed"
    case workbenchOpened = "workbench_opened"
    case workbenchClosed = "workbench_closed"
    case settingsOpened = "settings_opened"
    case settingsClosed = "settings_closed"
    case messageShown = "message_shown"
    case messageDismissed = "message_dismissed"
    case reviewContextPrepared = "review_context_prepared"
    case providerStarted = "provider_started"
    case providerFinished = "provider_finished"
    case policyEvaluated = "policy_evaluated"
    case decisionCardShown = "decision_card_shown"
    case humanDecisionRecorded = "human_decision_recorded"
    case staleReviewDiscarded = "stale_review_discarded"
    case aiDataDeleted = "ai_data_deleted"
    case quotaProbeStarted = "quota_probe_started"
    case quotaProbeFinished = "quota_probe_finished"
    case soundStarted = "sound_started"
    case soundStopped = "sound_stopped"
}

public enum RelayTelemetrySurface: String, Codable, Sendable {
    case app
    case launcher
    case workbench
    case settings
    case banner
    case supervisor
    case quota
    case sound
}

public enum RelayTelemetryOutcome: String, Codable, Sendable {
    case shown
    case succeeded
    case failed
    case allowed
    case rejected
    case confirmed
    case continued
    case manual
    case expired
    case idleTimeout = "idle_timeout"
    case maximumDuration = "maximum_duration"
    case stale
    case deleted
    case started
    case stopped
    case notice
    case success
    case error
    case fallback
}

public enum RelayTelemetryDurationBucket: String, Codable, Sendable {
    case underOneSecond = "under_1s"
    case oneToThreeSeconds = "1_3s"
    case threeToTenSeconds = "3_10s"
    case tenToThirtySeconds = "10_30s"
    case overThirtySeconds = "over_30s"

    public init(seconds: TimeInterval) {
        switch seconds {
        case ..<1: self = .underOneSecond
        case ..<3: self = .oneToThreeSeconds
        case ..<10: self = .threeToTenSeconds
        case ..<30: self = .tenToThirtySeconds
        default: self = .overThirtySeconds
        }
    }
}

/// Privacy-bounded analytics event. There is intentionally no free-form field:
/// task names, IDs, prompts, paths, code, credentials, and raw provider data
/// cannot be represented by this schema.
public struct RelayTelemetryEvent: Codable, Equatable, Identifiable, Sendable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var id: UUID
    public var occurredAt: Date
    public var name: RelayTelemetryEventName
    public var surface: RelayTelemetrySurface
    public var outcome: RelayTelemetryOutcome?
    public var duration: RelayTelemetryDurationBucket?

    public init(
        id: UUID = UUID(),
        occurredAt: Date = Date(),
        name: RelayTelemetryEventName,
        surface: RelayTelemetrySurface,
        outcome: RelayTelemetryOutcome? = nil,
        duration: RelayTelemetryDurationBucket? = nil
    ) {
        schemaVersion = Self.currentSchemaVersion
        self.id = id
        self.occurredAt = occurredAt
        self.name = name
        self.surface = surface
        self.outcome = outcome
        self.duration = duration
    }
}

public struct RelayTelemetrySummary: Equatable, Sendable {
    public var eventCount: Int
    public var workbenchOpenCount: Int
    public var reviewStartedCount: Int
    public var reviewSucceededCount: Int
    public var reviewFallbackCount: Int
    public var humanDecisionCount: Int
    public var expiredSurfaceCount: Int

    public init(events: [RelayTelemetryEvent] = []) {
        eventCount = events.count
        workbenchOpenCount = events.filter { $0.name == .workbenchOpened }.count
        reviewStartedCount = events.filter { $0.name == .providerStarted }.count
        reviewSucceededCount = events.filter {
            $0.name == .providerFinished && $0.outcome == .succeeded
        }.count
        reviewFallbackCount = events.filter {
            $0.name == .providerFinished && $0.outcome == .fallback
        }.count
        humanDecisionCount = events.filter { $0.name == .humanDecisionRecorded }.count
        expiredSurfaceCount = events.filter {
            $0.outcome == .expired || $0.outcome == .idleTimeout || $0.outcome == .maximumDuration
        }.count
    }
}

public struct LocalTelemetryStore: Sendable {
    public let fileURL: URL
    public let retention: TimeInterval
    public let maximumEventCount: Int

    public init(
        root: URL,
        retention: TimeInterval = 30 * 24 * 60 * 60,
        maximumEventCount: Int = 10_000
    ) {
        fileURL = root
            .appendingPathComponent("telemetry", isDirectory: true)
            .appendingPathComponent("events.jsonl", isDirectory: false)
        self.retention = retention
        self.maximumEventCount = maximumEventCount
    }

    public func record(
        _ event: RelayTelemetryEvent,
        now: Date = Date(),
        fileManager: FileManager = .default
    ) throws {
        try fileManager.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try prune(now: now, fileManager: fileManager)

        var data = try RelayJSON.makeEncoder().encode(event)
        data.append(0x0A)
        if !fileManager.fileExists(atPath: fileURL.path) {
            guard fileManager.createFile(atPath: fileURL.path, contents: nil) else {
                throw RelayError.storage("failed to create local telemetry store")
            }
        }
        do {
            let handle = try FileHandle(forWritingTo: fileURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
            try handle.synchronize()
        } catch {
            throw RelayError.storage("failed to append local telemetry event")
        }
    }

    public func load(
        since: Date? = nil,
        fileManager: FileManager = .default
    ) throws -> [RelayTelemetryEvent] {
        guard fileManager.fileExists(atPath: fileURL.path) else { return [] }
        do {
            let data = try Data(contentsOf: fileURL)
            return data.split(separator: 0x0A).compactMap { line in
                guard let event = try? RelayJSON.makeDecoder().decode(
                    RelayTelemetryEvent.self,
                    from: Data(line)
                ), event.schemaVersion == RelayTelemetryEvent.currentSchemaVersion,
                   since.map({ event.occurredAt >= $0 }) ?? true else { return nil }
                return event
            }
        } catch {
            throw RelayError.storage("failed to read local telemetry events")
        }
    }

    public func summary(
        now: Date = Date(),
        window: TimeInterval = 7 * 24 * 60 * 60,
        fileManager: FileManager = .default
    ) throws -> RelayTelemetrySummary {
        RelayTelemetrySummary(events: try load(
            since: now.addingTimeInterval(-window),
            fileManager: fileManager
        ))
    }

    public func prune(
        now: Date = Date(),
        fileManager: FileManager = .default
    ) throws {
        guard fileManager.fileExists(atPath: fileURL.path) else { return }
        let cutoff = now.addingTimeInterval(-retention)
        let retained = Array(try load(since: cutoff, fileManager: fileManager).suffix(maximumEventCount))
        var data = Data()
        for event in retained {
            data.append(try RelayJSON.makeEncoder().encode(event))
            data.append(0x0A)
        }
        try data.write(to: fileURL, options: [.atomic])
    }

    public func delete(fileManager: FileManager = .default) throws {
        guard fileManager.fileExists(atPath: fileURL.path) else { return }
        do {
            try fileManager.removeItem(at: fileURL)
        } catch {
            throw RelayError.storage("failed to delete local telemetry events")
        }
    }
}
