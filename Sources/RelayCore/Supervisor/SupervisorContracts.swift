import Foundation

public enum SupervisorLoopType: String, Codable, CaseIterable, Sendable {
    case completionReview = "completion_review"
}

public struct SupervisorTraceID: RawRepresentable, Codable, Equatable, Hashable, Sendable {
    public var rawValue: UUID

    public init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}

public struct SupervisorTaskIdentity: Codable, Equatable, Sendable {
    public var source: AgentSource
    public var taskID: String
    public var sessionID: String
    public var triggerEventID: UUID

    public init(
        source: AgentSource,
        taskID: String,
        sessionID: String,
        triggerEventID: UUID
    ) {
        self.source = source
        self.taskID = taskID
        self.sessionID = sessionID
        self.triggerEventID = triggerEventID
    }
}

public struct AcceptanceCriterion: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var statement: String

    public init(id: String, statement: String) {
        self.id = id
        self.statement = statement
    }
}

public struct SupervisorTaskGoal: Codable, Equatable, Sendable {
    public var statement: String
    public var acceptanceCriteria: [AcceptanceCriterion]

    public init(statement: String, acceptanceCriteria: [AcceptanceCriterion]) {
        self.statement = statement
        self.acceptanceCriteria = acceptanceCriteria
    }
}

public enum SupervisorContextMode: String, Codable, CaseIterable, Sendable {
    case syntheticFixture = "synthetic_fixture"
    case authorizedTask = "authorized_task"
}

public enum CompletionReviewRecommendation: String, Codable, CaseIterable, Sendable {
    case verifiedReady = "verified_ready"
    case missingEvidence = "missing_evidence"
    case continueWork = "continue_work"
    case humanReviewRequired = "human_review_required"
}

public enum SupervisorCandidateAction: String, Codable, CaseIterable, Sendable {
    case presentCompletionConfirmation = "present_completion_confirmation"
    case requestEvidence = "request_evidence"
    case continueInSourceAgent = "continue_in_source_agent"
    case openSourceAgent = "open_source_agent"
    case requestHumanReview = "request_human_review"
}

public enum SupervisorUncertaintyLevel: String, Codable, CaseIterable, Sendable {
    case low
    case medium
    case high
    case unknown
}

public struct SupervisorUncertainty: Codable, Equatable, Sendable {
    public var level: SupervisorUncertaintyLevel
    public var reasons: [String]

    public init(level: SupervisorUncertaintyLevel, reasons: [String] = []) {
        self.level = level
        self.reasons = reasons
    }
}

public struct SupervisorObservedFact: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var statement: String
    public var evidenceIDs: [UUID]
    public var acceptanceCriterionIDs: [String]

    public init(
        id: String,
        statement: String,
        evidenceIDs: [UUID],
        acceptanceCriterionIDs: [String]
    ) {
        self.id = id
        self.statement = statement
        self.evidenceIDs = evidenceIDs
        self.acceptanceCriterionIDs = acceptanceCriterionIDs
    }
}

public struct SupervisorInference: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var statement: String
    public var evidenceIDs: [UUID]
    public var uncertainty: SupervisorUncertaintyLevel

    public init(
        id: String,
        statement: String,
        evidenceIDs: [UUID],
        uncertainty: SupervisorUncertaintyLevel
    ) {
        self.id = id
        self.statement = statement
        self.evidenceIDs = evidenceIDs
        self.uncertainty = uncertainty
    }
}

public struct SupervisorEvidenceGap: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var statement: String
    public var acceptanceCriterionIDs: [String]

    public init(id: String, statement: String, acceptanceCriterionIDs: [String]) {
        self.id = id
        self.statement = statement
        self.acceptanceCriterionIDs = acceptanceCriterionIDs
    }
}

public enum SupervisorRiskLevel: String, Codable, CaseIterable, Sendable {
    case low
    case medium
    case high
    case critical
}

public enum SupervisorReversibility: String, Codable, CaseIterable, Sendable {
    case reversible
    case partiallyReversible = "partially_reversible"
    case irreversible
    case unknown
}

public struct SupervisorRisk: Codable, Equatable, Sendable {
    public var level: SupervisorRiskLevel
    public var factors: [String]
    public var impactScopes: [String]
    public var reversibility: SupervisorReversibility

    public init(
        level: SupervisorRiskLevel,
        factors: [String],
        impactScopes: [String],
        reversibility: SupervisorReversibility
    ) {
        self.level = level
        self.factors = factors
        self.impactScopes = impactScopes
        self.reversibility = reversibility
    }
}

public struct SupervisorModelDescriptor: Codable, Equatable, Sendable {
    public var providerID: String
    public var modelID: String
    public var modelVersion: String
    public var executionLocation: SupervisorModelExecutionLocation

    public init(
        providerID: String,
        modelID: String,
        modelVersion: String,
        executionLocation: SupervisorModelExecutionLocation
    ) {
        self.providerID = providerID
        self.modelID = modelID
        self.modelVersion = modelVersion
        self.executionLocation = executionLocation
    }
}

public enum SupervisorRemoteRetentionPolicy: String, Codable, Sendable {
    case providerControlled = "provider_controlled"
}

public struct CompletionReviewConsent: Codable, Equatable, Sendable {
    public var purpose: SupervisorLoopType
    public var provider: SupervisorModelDescriptor
    public var independentEvaluatorProvider: SupervisorModelDescriptor?
    public var maximumDataLevel: SupervisorDataLevel
    public var localRetentionSeconds: Int
    public var remoteRetentionPolicy: SupervisorRemoteRetentionPolicy
    public var preparedAt: Date
    public var confirmedAt: Date?

    public init(
        purpose: SupervisorLoopType = .completionReview,
        provider: SupervisorModelDescriptor,
        independentEvaluatorProvider: SupervisorModelDescriptor? = nil,
        maximumDataLevel: SupervisorDataLevel,
        localRetentionSeconds: Int = CompletionReviewRuntimeStore.localRetentionLimitSeconds,
        remoteRetentionPolicy: SupervisorRemoteRetentionPolicy = .providerControlled,
        preparedAt: Date,
        confirmedAt: Date? = nil
    ) {
        self.purpose = purpose
        self.provider = provider
        self.independentEvaluatorProvider = independentEvaluatorProvider
        self.maximumDataLevel = maximumDataLevel
        self.localRetentionSeconds = localRetentionSeconds
        self.remoteRetentionPolicy = remoteRetentionPolicy
        self.preparedAt = preparedAt
        self.confirmedAt = confirmedAt
    }
}

public struct CompletionReviewInput: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 3

    public var schemaVersion: Int
    public var traceID: SupervisorTraceID
    public var loopType: SupervisorLoopType
    public var task: SupervisorTaskIdentity
    public var goal: SupervisorTaskGoal
    public var evidence: [EvidenceRecord]
    public var allowedActions: [SupervisorCandidateAction]
    public var contextMode: SupervisorContextMode
    public var contextDataLevel: SupervisorDataLevel
    public var contextVersion: String
    public var policyVersion: String
    public var consent: CompletionReviewConsent?
    public var createdAt: Date
    public var expiresAt: Date

    public init(
        schemaVersion: Int = CompletionReviewInput.currentSchemaVersion,
        traceID: SupervisorTraceID = SupervisorTraceID(),
        loopType: SupervisorLoopType = .completionReview,
        task: SupervisorTaskIdentity,
        goal: SupervisorTaskGoal,
        evidence: [EvidenceRecord],
        allowedActions: [SupervisorCandidateAction],
        contextMode: SupervisorContextMode,
        contextDataLevel: SupervisorDataLevel,
        contextVersion: String,
        policyVersion: String,
        consent: CompletionReviewConsent?,
        createdAt: Date,
        expiresAt: Date
    ) {
        self.schemaVersion = schemaVersion
        self.traceID = traceID
        self.loopType = loopType
        self.task = task
        self.goal = goal
        self.evidence = evidence
        self.allowedActions = allowedActions
        self.contextMode = contextMode
        self.contextDataLevel = contextDataLevel
        self.contextVersion = contextVersion
        self.policyVersion = policyVersion
        self.consent = consent
        self.createdAt = createdAt
        self.expiresAt = expiresAt
    }
}

public struct SupervisorAssessment: Codable, Equatable, Identifiable, Sendable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var id: UUID
    public var traceID: SupervisorTraceID
    public var loopType: SupervisorLoopType
    public var task: SupervisorTaskIdentity
    public var model: SupervisorModelDescriptor
    public var usedEvidenceIDs: [UUID]
    public var observedFacts: [SupervisorObservedFact]
    public var inferences: [SupervisorInference]
    public var missingEvidence: [SupervisorEvidenceGap]
    public var recommendation: CompletionReviewRecommendation
    public var risk: SupervisorRisk
    public var uncertainty: SupervisorUncertainty
    public var proposedActions: [SupervisorCandidateAction]
    public var invalidatesOnNewerTaskEvent: Bool
    public var generatedAt: Date
    public var expiresAt: Date

    public init(
        schemaVersion: Int = SupervisorAssessment.currentSchemaVersion,
        id: UUID = UUID(),
        traceID: SupervisorTraceID,
        loopType: SupervisorLoopType = .completionReview,
        task: SupervisorTaskIdentity,
        model: SupervisorModelDescriptor,
        usedEvidenceIDs: [UUID],
        observedFacts: [SupervisorObservedFact],
        inferences: [SupervisorInference],
        missingEvidence: [SupervisorEvidenceGap],
        recommendation: CompletionReviewRecommendation,
        risk: SupervisorRisk,
        uncertainty: SupervisorUncertainty,
        proposedActions: [SupervisorCandidateAction],
        invalidatesOnNewerTaskEvent: Bool = true,
        generatedAt: Date,
        expiresAt: Date
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.traceID = traceID
        self.loopType = loopType
        self.task = task
        self.model = model
        self.usedEvidenceIDs = usedEvidenceIDs
        self.observedFacts = observedFacts
        self.inferences = inferences
        self.missingEvidence = missingEvidence
        self.recommendation = recommendation
        self.risk = risk
        self.uncertainty = uncertainty
        self.proposedActions = proposedActions
        self.invalidatesOnNewerTaskEvent = invalidatesOnNewerTaskEvent
        self.generatedAt = generatedAt
        self.expiresAt = expiresAt
    }
}

enum SupervisorContractText {
    static func isCanonical(_ value: String, maximumLength: Int) -> Bool {
        guard !value.isEmpty, value.count <= maximumLength else { return false }
        let printable = value.unicodeScalars.filter { $0.value >= 0x20 && $0.value != 0x7F }
        let normalized = printable
            .map(String.init)
            .joined()
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return normalized == value
    }
}
