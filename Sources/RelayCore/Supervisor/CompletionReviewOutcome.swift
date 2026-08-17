import Foundation

public enum CompletionReviewOutcomeKind: String, Codable, CaseIterable, Sendable {
    case workResumed = "work_resumed"
    case attentionObserved = "attention_observed"
    case reviewReturned = "review_returned"
    case failureObserved = "failure_observed"
    case completionObserved = "completion_observed"
    case cancellationObserved = "cancellation_observed"
    case sessionEnded = "session_ended"
}

public struct CompletionReviewOutcome: Codable, Equatable, Identifiable, Sendable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var id: UUID
    public var task: SupervisorTaskIdentity
    public var decisionID: UUID
    public var assessmentID: UUID?
    public var observedEventID: UUID
    public var observedStatus: RelayStatus
    public var kind: CompletionReviewOutcomeKind
    public var observedAt: Date
    public var recordedAt: Date

    public init(
        schemaVersion: Int = currentSchemaVersion,
        id: UUID = UUID(),
        task: SupervisorTaskIdentity,
        decisionID: UUID,
        assessmentID: UUID?,
        observedEventID: UUID,
        observedStatus: RelayStatus,
        kind: CompletionReviewOutcomeKind,
        observedAt: Date,
        recordedAt: Date = Date()
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.task = task
        self.decisionID = decisionID
        self.assessmentID = assessmentID
        self.observedEventID = observedEventID
        self.observedStatus = observedStatus
        self.kind = kind
        self.observedAt = observedAt
        self.recordedAt = recordedAt
    }
}

public enum CompletionReviewOutcomeRecorder {
    public static let maximumOutcomes = 512

    public static func reconcile(
        decisions: [CompletionReviewHumanDecision],
        sessions: [String: RelaySessionState],
        existing: [CompletionReviewOutcome],
        now: Date = Date()
    ) -> [CompletionReviewOutcome] {
        var outcomes = existing.filter {
            $0.schemaVersion == CompletionReviewOutcome.currentSchemaVersion
                && $0.recordedAt > now.addingTimeInterval(
                    -TimeInterval(CompletionReviewRuntimeStore.localRetentionLimitSeconds)
                )
        }
        var identities = Set(outcomes.map { Identity(decisionID: $0.decisionID, eventID: $0.observedEventID) })

        for decision in decisions {
            let key = "\(decision.task.source.rawValue):\(decision.task.sessionID)"
            guard let session = sessions[key],
                  session.source == decision.task.source,
                  session.sessionID == decision.task.sessionID,
                  session.lastEventID != decision.task.triggerEventID,
                  session.lastEventAt >= decision.decidedAt else { continue }
            let identity = Identity(decisionID: decision.id, eventID: session.lastEventID)
            guard identities.insert(identity).inserted else { continue }
            outcomes.append(CompletionReviewOutcome(
                task: decision.task,
                decisionID: decision.id,
                assessmentID: decision.assessmentID,
                observedEventID: session.lastEventID,
                observedStatus: session.status,
                kind: kind(for: session.status),
                observedAt: session.lastEventAt,
                recordedAt: now
            ))
        }
        return Array(outcomes.suffix(maximumOutcomes))
    }

    private static func kind(for status: RelayStatus) -> CompletionReviewOutcomeKind {
        switch status {
        case .running: .workResumed
        case .needsInput, .needsPermission: .attentionObserved
        case .readyToReview: .reviewReturned
        case .failed: .failureObserved
        case .completed: .completionObserved
        case .cancelled: .cancellationObserved
        case .ended: .sessionEnded
        }
    }

    private struct Identity: Hashable {
        var decisionID: UUID
        var eventID: UUID
    }
}
