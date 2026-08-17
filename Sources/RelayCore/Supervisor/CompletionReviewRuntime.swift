import Foundation

public struct CompletionReviewDraft: Codable, Equatable, Sendable {
    public var goal: String
    public var acceptanceCriteria: [String]
    public var resultSummary: String?
    public var revision: UUID
    public var updatedAt: Date

    public init(
        goal: String,
        acceptanceCriteria: [String],
        resultSummary: String? = nil,
        revision: UUID = UUID(),
        updatedAt: Date = Date()
    ) {
        self.goal = Self.canonical(goal, limit: 1_000)
        self.acceptanceCriteria = acceptanceCriteria
            .map { Self.canonical($0, limit: 500) }
            .filter { !$0.isEmpty }
            .prefix(32)
            .map { $0 }
        let normalizedSummary = resultSummary.map { Self.canonical($0, limit: 420) }
        self.resultSummary = normalizedSummary?.isEmpty == false ? normalizedSummary : nil
        self.revision = revision
        self.updatedAt = updatedAt
    }

    public var isUsable: Bool {
        !goal.isEmpty && !acceptanceCriteria.isEmpty
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

public struct StoredCompletionReview: Codable, Equatable, Sendable {
    public var input: CompletionReviewInput
    public var assessment: SupervisorAssessment?
    public var evaluatorResult: CompletionReviewEvaluatorResult?
    public var independentEvaluator: StoredIndependentCompletionReviewEvaluation?
    public var providerReceipt: SupervisorProviderReceipt?
    public var policyDecision: SupervisorPolicyDecision?
    public var fallback: SupervisorFallback?
    public var recordedAt: Date

    public init(
        input: CompletionReviewInput,
        assessment: SupervisorAssessment? = nil,
        evaluatorResult: CompletionReviewEvaluatorResult? = nil,
        independentEvaluator: StoredIndependentCompletionReviewEvaluation? = nil,
        providerReceipt: SupervisorProviderReceipt? = nil,
        policyDecision: SupervisorPolicyDecision? = nil,
        fallback: SupervisorFallback? = nil,
        recordedAt: Date = Date()
    ) {
        self.input = input
        self.assessment = assessment
        self.evaluatorResult = evaluatorResult
        self.independentEvaluator = independentEvaluator
        self.providerReceipt = providerReceipt
        self.policyDecision = policyDecision
        self.fallback = fallback
        self.recordedAt = recordedAt
    }

    public func isCurrent(for session: RelaySessionState, now: Date = Date()) -> Bool {
        input.task.source == session.source
            && input.task.sessionID == session.sessionID
            && input.task.triggerEventID == session.lastEventID
            && input.expiresAt > now
            && assessment.map { $0.expiresAt > now } ?? true
    }
}

public enum CompletionReviewHumanDecisionKind: String, Codable, Sendable {
    case confirmedComplete = "confirmed_complete"
    case continueWork = "continue_work"
    case requestEvidence = "request_evidence"
    case humanReview = "human_review"
}

public struct CompletionReviewHumanDecision: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var task: SupervisorTaskIdentity
    public var assessmentID: UUID?
    public var kind: CompletionReviewHumanDecisionKind
    public var decidedAt: Date

    public init(
        id: UUID = UUID(),
        task: SupervisorTaskIdentity,
        assessmentID: UUID?,
        kind: CompletionReviewHumanDecisionKind,
        decidedAt: Date = Date()
    ) {
        self.id = id
        self.task = task
        self.assessmentID = assessmentID
        self.kind = kind
        self.decidedAt = decidedAt
    }
}

public struct CompletionReviewRuntimeSnapshot: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 6
    public static let supportedSchemaVersions: Set<Int> = [1, 2, 3, 4, 5, 6]

    public var schemaVersion: Int
    public var drafts: [String: CompletionReviewDraft]
    public var reviews: [String: StoredCompletionReview]
    public var decisions: [CompletionReviewHumanDecision]
    public var outcomes: [CompletionReviewOutcome]

    public init(
        schemaVersion: Int = currentSchemaVersion,
        drafts: [String: CompletionReviewDraft] = [:],
        reviews: [String: StoredCompletionReview] = [:],
        decisions: [CompletionReviewHumanDecision] = [],
        outcomes: [CompletionReviewOutcome] = []
    ) {
        self.schemaVersion = schemaVersion
        self.drafts = drafts
        self.reviews = reviews
        self.decisions = decisions
        self.outcomes = outcomes
    }

    public mutating func migrateToCurrentSchema() {
        guard schemaVersion < Self.currentSchemaVersion else { return }
        reviews = reviews.filter {
            $0.value.input.schemaVersion == CompletionReviewInput.currentSchemaVersion
                && $0.value.input.consent != nil
        }
        schemaVersion = Self.currentSchemaVersion
    }

    @discardableResult
    public mutating func removeProhibitedContent() -> Int {
        let originalCount = drafts.count + reviews.count
        drafts = drafts.filter { _, draft in
            let values = [draft.goal] + draft.acceptanceCriteria + [draft.resultSummary].compactMap { $0 }
            return values.allSatisfy { SupervisorSensitiveTextScanner.scan($0).isEmpty }
        }
        reviews = reviews.filter { _, review in
            !SupervisorSensitiveTextScanner.containsProhibitedContent(in: review.input)
                && (review.assessment.map {
                    !SupervisorSensitiveTextScanner.containsProhibitedContent(in: $0)
                } ?? true)
                && (review.independentEvaluator?.result.map {
                    !SupervisorSensitiveTextScanner.containsProhibitedContent(in: $0)
                } ?? true)
        }
        return originalCount - drafts.count - reviews.count
    }

    @discardableResult
    public mutating func pruneExpired(
        now: Date = Date(),
        retention: TimeInterval = TimeInterval(CompletionReviewRuntimeStore.localRetentionLimitSeconds)
    ) -> Int {
        let cutoff = now.addingTimeInterval(-retention)
        let originalCount = drafts.count + reviews.count + decisions.count + outcomes.count
        drafts = drafts.filter { $0.value.updatedAt > cutoff }
        reviews = reviews.filter { $0.value.recordedAt > cutoff }
        decisions = decisions.filter { $0.decidedAt > cutoff }
        outcomes = outcomes.filter { $0.recordedAt > cutoff }
        return originalCount - drafts.count - reviews.count - decisions.count - outcomes.count
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case drafts
        case reviews
        case decisions
        case outcomes
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        drafts = try container.decodeIfPresent(
            [String: CompletionReviewDraft].self,
            forKey: .drafts
        ) ?? [:]
        reviews = try container.decodeIfPresent(
            [String: StoredCompletionReview].self,
            forKey: .reviews
        ) ?? [:]
        decisions = try container.decodeIfPresent(
            [CompletionReviewHumanDecision].self,
            forKey: .decisions
        ) ?? []
        outcomes = try container.decodeIfPresent(
            [CompletionReviewOutcome].self,
            forKey: .outcomes
        ) ?? []
    }
}

public struct CompletionReviewRuntimeStore: Sendable {
    public static let localRetentionLimitSeconds = 24 * 60 * 60
    public let fileURL: URL

    public init(root: URL) {
        fileURL = root
            .appendingPathComponent("supervisor", isDirectory: true)
            .appendingPathComponent("completion-reviews.json", isDirectory: false)
    }

    public func load(fileManager: FileManager = .default) throws -> CompletionReviewRuntimeSnapshot {
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return CompletionReviewRuntimeSnapshot()
        }
        do {
            let data = try Data(contentsOf: fileURL)
            var snapshot = try RelayJSON.makeDecoder().decode(
                CompletionReviewRuntimeSnapshot.self,
                from: data
            )
            guard CompletionReviewRuntimeSnapshot.supportedSchemaVersions.contains(
                snapshot.schemaVersion
            ) else {
                throw RelayError.storage("unsupported Completion Review runtime schema")
            }
            snapshot.migrateToCurrentSchema()
            snapshot.removeProhibitedContent()
            return snapshot
        } catch let error as RelayError {
            throw error
        } catch {
            throw RelayError.storage("failed to load Completion Review runtime state")
        }
    }

    public func persist(
        _ snapshot: CompletionReviewRuntimeSnapshot,
        fileManager: FileManager = .default
    ) throws {
        do {
            var sanitized = snapshot
            sanitized.removeProhibitedContent()
            try fileManager.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try RelayJSON.makeEncoder(prettyPrinted: true).encode(sanitized)
            try data.write(to: fileURL, options: [.atomic])
        } catch {
            throw RelayError.storage("failed to persist Completion Review runtime state")
        }
    }

    public func deleteTask(
        _ sessionKey: String,
        fileManager: FileManager = .default
    ) throws {
        var snapshot = try load(fileManager: fileManager)
        snapshot.drafts.removeValue(forKey: sessionKey)
        snapshot.reviews.removeValue(forKey: sessionKey)
        snapshot.decisions.removeAll {
            "\($0.task.source.rawValue):\($0.task.sessionID)" == sessionKey
        }
        snapshot.outcomes.removeAll {
            "\($0.task.source.rawValue):\($0.task.sessionID)" == sessionKey
        }
        try persist(snapshot, fileManager: fileManager)
    }
}

public enum CompletionReviewInputBuilder {
    public static func build(
        session: RelaySessionState,
        draft: CompletionReviewDraft,
        provider: SupervisorModelDescriptor,
        independentEvaluatorProvider: SupervisorModelDescriptor? = nil,
        consentConfirmedAt: Date?,
        additionalEvidence: [CompletionReviewEvidenceObservation] = [],
        now: Date = Date(),
        lifetime: TimeInterval = 10 * 60
    ) throws -> CompletionReviewInput {
        guard session.status == .readyToReview, draft.isUsable else {
            throw RelayError.invalidPayload("Completion Review requires a live review task, goal, and acceptance criteria")
        }
        let draftValues = [draft.goal] + draft.acceptanceCriteria + [draft.resultSummary].compactMap { $0 }
        guard draftValues.allSatisfy({ SupervisorSensitiveTextScanner.scan($0).isEmpty }) else {
            throw RelayError.invalidPayload("Completion Review fields contain prohibited secret or source-code content")
        }

        let task = SupervisorTaskIdentity(
            source: session.source,
            taskID: session.key,
            sessionID: session.sessionID,
            triggerEventID: session.lastEventID
        )
        let approvedProviderIDs = Array(Set(
            [provider.providerID, independentEvaluatorProvider?.providerID].compactMap { $0 }
        )).sorted()
        let consent = EvidenceConsentScope(
            purposes: [.completionReview],
            maximumDataLevel: .l1StructuredEvidence,
            allowedModelLocations: [.remote],
            approvedRemoteProviderIDs: approvedProviderIDs
        )
        let records = evidenceRecords(
            session: session,
            task: task,
            consent: consent,
            resultSummary: draft.resultSummary,
            additionalEvidence: additionalEvidence,
            now: now,
            lifetime: lifetime
        )
        let criteria = draft.acceptanceCriteria.enumerated().map { index, statement in
            AcceptanceCriterion(id: "criterion-\(index + 1)", statement: statement)
        }

        let input = CompletionReviewInput(
            task: task,
            goal: SupervisorTaskGoal(statement: draft.goal, acceptanceCriteria: criteria),
            evidence: records,
            allowedActions: SupervisorCandidateAction.allCases,
            contextMode: .authorizedTask,
            contextDataLevel: .l1StructuredEvidence,
            contextVersion: "goal-\(draft.revision.uuidString.lowercased())",
            policyVersion: CompletionReviewPolicy.liveShadowVersion,
            consent: CompletionReviewConsent(
                provider: provider,
                independentEvaluatorProvider: independentEvaluatorProvider,
                maximumDataLevel: .l1StructuredEvidence,
                preparedAt: now,
                confirmedAt: consentConfirmedAt
            ),
            createdAt: now,
            expiresAt: now.addingTimeInterval(lifetime)
        )
        guard !SupervisorSensitiveTextScanner.containsProhibitedContent(in: input) else {
            throw RelayError.invalidPayload("Completion Review evidence contains prohibited secret or source-code content")
        }
        return input
    }

    private static func evidenceRecords(
        session: RelaySessionState,
        task: SupervisorTaskIdentity,
        consent: EvidenceConsentScope,
        resultSummary: String?,
        additionalEvidence: [CompletionReviewEvidenceObservation],
        now: Date,
        lifetime: TimeInterval
    ) -> [EvidenceRecord] {
        let mapped = session.completionEvidence?.items.compactMap { item -> EvidenceRecord? in
            guard let kind = EvidenceKind(rawValue: item.kind.rawValue) else { return nil }
            return EvidenceRecord(
                taskID: task.taskID,
                sessionID: task.sessionID,
                agentSource: task.source,
                kind: kind,
                source: EvidenceSource(
                    kind: item.kind == .userConfirmed ? .human : .provider,
                    sourceID: "\(task.source.rawValue)-completion-signal"
                ),
                summary: item.summary,
                observedAt: session.lastEventAt,
                expiresAt: now.addingTimeInterval(lifetime),
                dataLevel: .l1StructuredEvidence,
                consentScope: consent,
                integrity: .complete
            )
        } ?? []
        var records = mapped
        records.append(contentsOf: additionalEvidence
            .filter(\.isUsable)
            .prefix(max(0, 32 - records.count))
            .map { observation in
                EvidenceRecord(
                    id: observation.id,
                    taskID: task.taskID,
                    sessionID: task.sessionID,
                    agentSource: task.source,
                    kind: observation.kind,
                    source: observation.source,
                    summary: observation.summary,
                    reference: observation.reference,
                    observedAt: observation.observedAt,
                    expiresAt: now.addingTimeInterval(lifetime),
                    dataLevel: observation.dataLevel,
                    consentScope: consent,
                    integrity: observation.integrity
                )
            })
        if let resultSummary {
            records.append(EvidenceRecord(
                taskID: task.taskID,
                sessionID: task.sessionID,
                agentSource: task.source,
                kind: .reviewAvailable,
                source: EvidenceSource(kind: .human, sourceID: "user-authorized-result-summary"),
                summary: "用户授权的结果摘要：\(resultSummary)",
                observedAt: now,
                expiresAt: now.addingTimeInterval(lifetime),
                dataLevel: .l1StructuredEvidence,
                consentScope: consent,
                integrity: .partial
            ))
        }
        if records.isEmpty {
            records.append(EvidenceRecord(
                taskID: task.taskID,
                sessionID: task.sessionID,
                agentSource: task.source,
                kind: .providerSignal,
                source: EvidenceSource(kind: .provider, sourceID: "\(task.source.rawValue)-lifecycle"),
                summary: "Agent 报告其最新结果已准备好接受复核。",
                observedAt: session.lastEventAt,
                expiresAt: now.addingTimeInterval(lifetime),
                dataLevel: .l0RuntimeMetadata,
                consentScope: consent,
                integrity: .partial
            ))
        }
        return records
    }
}
