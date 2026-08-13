import Foundation

public struct RelaySessionState: Codable, Equatable, Sendable {
    public var key: String
    public var source: AgentSource
    public var sessionID: String
    public var status: RelayStatus
    public var attention: AttentionLevel
    public var project: ProjectContext
    public var model: String?
    public var summary: String
    public var progress: RelayProgress?
    public var completionEvidence: CompletionEvidenceBundle?
    public var waitingSince: Date?
    public var terminalAt: Date?
    public var lastEventAt: Date
    public var lastEventID: UUID
    public var eventCount: Int

    public init(event: RelayEvent) {
        key = event.sessionKey
        source = event.source
        sessionID = event.sessionID
        status = event.effectiveStatus
        attention = AttentionPolicy.level(for: event.effectiveStatus)
        project = event.project
        model = event.model
        summary = event.summary
        progress = event.progress
        completionEvidence = event.completionEvidence
        waitingSince = event.effectiveStatus.requiresAttention ? event.occurredAt : nil
        terminalAt = event.effectiveStatus.isRetainedTerminal ? event.occurredAt : nil
        lastEventAt = event.occurredAt
        lastEventID = event.id
        eventCount = 1
    }
}

public enum ReductionResult: String, Equatable, Sendable {
    case applied
    case duplicateID = "duplicate_id"
    case duplicateFingerprint = "duplicate_fingerprint"
    case stale
}

public struct RelaySnapshot: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 2
    public static let supportedSchemaVersions = 1...currentSchemaVersion
    public static let processedEventLimit = 2_048
    public static let fingerprintLimit = 2_048
    public static let duplicateWindow: TimeInterval = 2

    public var schemaVersion: Int
    public var sessions: [String: RelaySessionState]
    public var processedEventIDs: [UUID]
    public var fingerprintTimestamps: [String: Date]
    public var updatedAt: Date

    public init(
        schemaVersion: Int = RelaySnapshot.currentSchemaVersion,
        sessions: [String: RelaySessionState] = [:],
        processedEventIDs: [UUID] = [],
        fingerprintTimestamps: [String: Date] = [:],
        updatedAt: Date = .distantPast
    ) {
        self.schemaVersion = schemaVersion
        self.sessions = sessions
        self.processedEventIDs = processedEventIDs
        self.fingerprintTimestamps = fingerprintTimestamps
        self.updatedAt = updatedAt
    }

    @discardableResult
    public mutating func apply(_ event: RelayEvent) -> ReductionResult {
        if processedEventIDs.contains(event.id) {
            return .duplicateID
        }

        remember(eventID: event.id)

        if let previous = fingerprintTimestamps[event.fingerprint],
           abs(event.occurredAt.timeIntervalSince(previous)) <= Self.duplicateWindow {
            remember(fingerprint: event.fingerprint, at: max(previous, event.occurredAt))
            updatedAt = max(updatedAt, event.receivedAt)
            return .duplicateFingerprint
        }
        remember(fingerprint: event.fingerprint, at: event.occurredAt)

        if let existing = sessions[event.sessionKey], event.occurredAt < existing.lastEventAt {
            updatedAt = max(updatedAt, event.receivedAt)
            return .stale
        }

        if var existing = sessions[event.sessionKey] {
            let wasWaiting = existing.status.requiresAttention
            let previousStatus = existing.status
            let effectiveStatus = reducedStatus(
                current: previousStatus,
                incoming: event.effectiveStatus
            )
            let lifecycleEndPreservesOutcome = event.effectiveStatus == .ended
                && effectiveStatus != .ended
            existing.status = effectiveStatus
            existing.attention = AttentionPolicy.level(for: effectiveStatus)
            existing.project = mergedProject(current: existing.project, incoming: event.project)
            existing.model = event.model ?? existing.model
            if !lifecycleEndPreservesOutcome {
                existing.summary = event.summary
            }
            if lifecycleEndPreservesOutcome {
                // SessionEnd closes the source lifecycle; it must not erase the result
                // that the user still needs to review or the evidence behind completion.
            } else if let progress = event.progress {
                existing.progress = progress
            } else if effectiveStatus != .running {
                existing.progress = nil
            }
            if !lifecycleEndPreservesOutcome {
                existing.completionEvidence = event.completionEvidence
            }
            existing.waitingSince = effectiveStatus.requiresAttention
                ? (wasWaiting ? existing.waitingSince ?? event.occurredAt : event.occurredAt)
                : nil
            existing.terminalAt = effectiveStatus.isRetainedTerminal
                ? (previousStatus == effectiveStatus ? existing.terminalAt ?? event.occurredAt : event.occurredAt)
                : nil
            existing.lastEventAt = event.occurredAt
            existing.lastEventID = event.id
            existing.eventCount += 1
            sessions[event.sessionKey] = existing
        } else {
            sessions[event.sessionKey] = RelaySessionState(event: event)
        }

        updatedAt = max(updatedAt, event.receivedAt)
        return .applied
    }

    public var attentionRequiredCount: Int {
        sessions.values.filter { $0.status.requiresAttention }.count
    }

    public var runningCount: Int {
        sessions.values.filter { $0.status == .running }.count
    }

    public var completedCount: Int {
        sessions.values.filter { $0.status == .completed }.count
    }

    public var readyToReviewCount: Int {
        sessions.values.filter { $0.status == .readyToReview }.count
    }

    public func cleanupState(
        for sessionKey: String,
        now: Date = Date(),
        policy: RelayRetentionPolicy = RelayRetentionPolicy()
    ) -> RelayCleanupState {
        guard let session = sessions[sessionKey],
              let terminalAt = session.terminalAt,
              session.status.isRetainedTerminal else { return .notScheduled }

        let removalAt = terminalAt.addingTimeInterval(policy.terminalRetention)
        let remaining = removalAt.timeIntervalSince(now)
        if remaining <= 0 {
            return .expired(removalAt: removalAt)
        }
        if remaining <= policy.cleanupReminderLeadTime {
            return .approaching(removalAt: removalAt)
        }
        return .scheduled(removalAt: removalAt)
    }

    @discardableResult
    public mutating func pruneExpired(
        now: Date = Date(),
        policy: RelayRetentionPolicy = RelayRetentionPolicy()
    ) -> [RelaySessionState] {
        let expiredKeys = sessions.keys.filter {
            if case .expired = cleanupState(for: $0, now: now, policy: policy) {
                return true
            }
            return false
        }
        let removed = expiredKeys.compactMap { sessions.removeValue(forKey: $0) }
        if !removed.isEmpty {
            updatedAt = max(updatedAt, now)
        }
        return removed.sorted {
            if $0.lastEventAt == $1.lastEventAt { return $0.key < $1.key }
            return $0.lastEventAt < $1.lastEventAt
        }
    }

    public mutating func migrateToCurrentSchema() {
        guard schemaVersion < Self.currentSchemaVersion else { return }
        for key in sessions.keys {
            guard var session = sessions[key] else { continue }
            if session.status == .completed, session.completionEvidence?.verifiesCompletion != true {
                session.status = .readyToReview
                session.attention = AttentionPolicy.level(for: .readyToReview)
                session.terminalAt = nil
            }
            sessions[key] = session
        }
        schemaVersion = Self.currentSchemaVersion
    }

    private mutating func remember(eventID: UUID) {
        processedEventIDs.append(eventID)
        if processedEventIDs.count > Self.processedEventLimit {
            processedEventIDs.removeFirst(processedEventIDs.count - Self.processedEventLimit)
        }
    }

    private mutating func remember(fingerprint: String, at date: Date) {
        fingerprintTimestamps[fingerprint] = date
        guard fingerprintTimestamps.count > Self.fingerprintLimit else { return }

        let overflow = fingerprintTimestamps.count - Self.fingerprintLimit
        let oldest = fingerprintTimestamps
            .sorted { $0.value < $1.value }
            .prefix(overflow)
            .map(\.key)
        for key in oldest {
            fingerprintTimestamps.removeValue(forKey: key)
        }
    }

    private func mergedProject(current: ProjectContext, incoming: ProjectContext) -> ProjectContext {
        ProjectContext(
            cwd: incoming.cwd ?? current.cwd,
            name: incoming.name ?? current.name,
            repository: incoming.repository ?? current.repository,
            branch: incoming.branch ?? current.branch
        )
    }

    private func reducedStatus(current: RelayStatus, incoming: RelayStatus) -> RelayStatus {
        guard incoming == .ended else { return incoming }
        return switch current {
        case .readyToReview, .failed, .completed, .cancelled:
            current
        case .running, .needsInput, .needsPermission, .ended:
            .ended
        }
    }
}

public struct RelayRetentionPolicy: Equatable, Sendable {
    public var terminalRetention: TimeInterval
    public var cleanupReminderLeadTime: TimeInterval

    public init(
        terminalRetention: TimeInterval = 24 * 60 * 60,
        cleanupReminderLeadTime: TimeInterval = 60 * 60
    ) {
        self.terminalRetention = terminalRetention
        self.cleanupReminderLeadTime = cleanupReminderLeadTime
    }
}

public enum RelayCleanupState: Equatable, Sendable {
    case notScheduled
    case scheduled(removalAt: Date)
    case approaching(removalAt: Date)
    case expired(removalAt: Date)
}
