import Foundation

public enum SupervisorDataLevel: Int, Codable, CaseIterable, Comparable, Sendable {
    case l0RuntimeMetadata = 0
    case l1StructuredEvidence = 1
    case l2SelectedContent = 2
    case l3SensitiveContent = 3

    public static func < (lhs: SupervisorDataLevel, rhs: SupervisorDataLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

public enum EvidenceKind: String, Codable, CaseIterable, Sendable {
    case gitState = "git_state"
    case ciChecksPassed = "ci_checks_passed"
    case ciChecksFailed = "ci_checks_failed"
    case ciChecksIncomplete = "ci_checks_incomplete"
    case testPassed = "test_passed"
    case buildSucceeded = "build_succeeded"
    case artifactProduced = "artifact_produced"
    case deploymentAvailable = "deployment_available"
    case reviewAvailable = "review_available"
    case providerSignal = "provider_signal"
    case userConfirmed = "user_confirmed"
}

public struct CompletionReviewEvidenceObservation: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var kind: EvidenceKind
    public var source: EvidenceSource
    public var summary: String
    public var reference: String?
    public var observedAt: Date
    public var dataLevel: SupervisorDataLevel
    public var integrity: EvidenceIntegrity

    public init(
        id: UUID = UUID(),
        kind: EvidenceKind,
        source: EvidenceSource,
        summary: String,
        reference: String? = nil,
        observedAt: Date,
        dataLevel: SupervisorDataLevel,
        integrity: EvidenceIntegrity
    ) {
        self.id = id
        self.kind = kind
        self.source = EvidenceSource(
            kind: source.kind,
            sourceID: Self.canonical(source.sourceID, limit: 128)
        )
        self.summary = Self.canonical(summary, limit: 500)
        self.reference = reference.map { Self.canonical($0, limit: 512) }
        self.observedAt = observedAt
        self.dataLevel = dataLevel
        self.integrity = integrity
    }

    public var isUsable: Bool {
        !source.sourceID.isEmpty
            && !summary.isEmpty
            && dataLevel <= .l1StructuredEvidence
            && (reference?.isEmpty == false || reference == nil)
    }

    private static func canonical(_ value: String, limit: Int) -> String {
        let printable = value.unicodeScalars.filter { $0.value >= 0x20 && $0.value != 0x7F }
        let collapsed = printable
            .map(String.init)
            .joined()
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return String(collapsed.prefix(limit))
    }
}

public enum EvidenceSourceKind: String, Codable, CaseIterable, Sendable {
    case provider
    case tool
    case human
    case system
}

public struct EvidenceSource: Codable, Equatable, Sendable {
    public var kind: EvidenceSourceKind
    public var sourceID: String

    public init(kind: EvidenceSourceKind, sourceID: String) {
        self.kind = kind
        self.sourceID = sourceID
    }
}

public enum EvidenceIntegrity: String, Codable, CaseIterable, Sendable {
    case complete
    case partial
    case unverifiable
    case conflicting
}

public enum SupervisorModelExecutionLocation: String, Codable, CaseIterable, Sendable {
    case fixture
    case local
    case remote
}

public struct EvidenceConsentScope: Codable, Equatable, Sendable {
    public var purposes: [SupervisorLoopType]
    public var maximumDataLevel: SupervisorDataLevel
    public var allowedModelLocations: [SupervisorModelExecutionLocation]
    public var approvedRemoteProviderIDs: [String]

    public init(
        purposes: [SupervisorLoopType],
        maximumDataLevel: SupervisorDataLevel,
        allowedModelLocations: [SupervisorModelExecutionLocation],
        approvedRemoteProviderIDs: [String] = []
    ) {
        self.purposes = purposes
        self.maximumDataLevel = maximumDataLevel
        self.allowedModelLocations = allowedModelLocations
        self.approvedRemoteProviderIDs = approvedRemoteProviderIDs
    }
}

public struct EvidenceRecord: Codable, Equatable, Identifiable, Sendable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var id: UUID
    public var taskID: String
    public var sessionID: String
    public var agentSource: AgentSource
    public var kind: EvidenceKind
    public var source: EvidenceSource
    public var summary: String
    public var reference: String?
    public var observedAt: Date
    public var expiresAt: Date?
    public var dataLevel: SupervisorDataLevel
    public var consentScope: EvidenceConsentScope
    public var integrity: EvidenceIntegrity

    public init(
        schemaVersion: Int = EvidenceRecord.currentSchemaVersion,
        id: UUID = UUID(),
        taskID: String,
        sessionID: String,
        agentSource: AgentSource,
        kind: EvidenceKind,
        source: EvidenceSource,
        summary: String,
        reference: String? = nil,
        observedAt: Date,
        expiresAt: Date? = nil,
        dataLevel: SupervisorDataLevel,
        consentScope: EvidenceConsentScope,
        integrity: EvidenceIntegrity
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.taskID = taskID
        self.sessionID = sessionID
        self.agentSource = agentSource
        self.kind = kind
        self.source = source
        self.summary = summary
        self.reference = reference
        self.observedAt = observedAt
        self.expiresAt = expiresAt
        self.dataLevel = dataLevel
        self.consentScope = consentScope
        self.integrity = integrity
    }

    public func isUsable(
        for task: SupervisorTaskIdentity,
        loop: SupervisorLoopType,
        model: SupervisorModelDescriptor,
        now: Date
    ) -> Bool {
        guard schemaVersion == Self.currentSchemaVersion,
              taskID == task.taskID,
              sessionID == task.sessionID,
              agentSource == task.source,
              observedAt <= now,
              expiresAt.map({ $0 > now }) ?? true,
              dataLevel <= consentScope.maximumDataLevel,
              consentScope.purposes.contains(loop),
              consentScope.allowedModelLocations.contains(model.executionLocation)
        else { return false }

        if model.executionLocation == .remote {
            return consentScope.approvedRemoteProviderIDs.contains(model.providerID)
        }
        return true
    }
}
