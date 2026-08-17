import Foundation

public enum SupervisorPolicyDisposition: String, Codable, Sendable {
    case allowShadowAssessment = "allow_shadow_assessment"
    case harnessOnly = "harness_only"
}

public enum SupervisorPolicyViolationCode: String, Codable, CaseIterable, Sendable {
    case unsupportedSchema = "unsupported_schema"
    case invalidContract = "invalid_contract"
    case expired = "expired"
    case identityMismatch = "identity_mismatch"
    case traceMismatch = "trace_mismatch"
    case providerMismatch = "provider_mismatch"
    case evidenceNotAuthorized = "evidence_not_authorized"
    case evidenceNotGrounded = "evidence_not_grounded"
    case unsupportedAction = "unsupported_action"
    case unsafeVerifiedReady = "unsafe_verified_ready"
    case evaluatorRejected = "evaluator_rejected"
    case sensitiveContent = "sensitive_content"
    case phaseBoundary = "phase_boundary"
}

public struct SupervisorPolicyViolation: Codable, Equatable, Sendable {
    public var code: SupervisorPolicyViolationCode
    public var detail: String

    public init(code: SupervisorPolicyViolationCode, detail: String) {
        self.code = code
        self.detail = detail
    }
}

public struct SupervisorPolicyDecision: Codable, Equatable, Sendable {
    public var traceID: SupervisorTraceID
    public var assessmentID: UUID
    public var disposition: SupervisorPolicyDisposition
    public var violations: [SupervisorPolicyViolation]
    public var policyVersion: String
    public var evaluatedAt: Date

    public init(
        traceID: SupervisorTraceID,
        assessmentID: UUID,
        disposition: SupervisorPolicyDisposition,
        violations: [SupervisorPolicyViolation],
        policyVersion: String,
        evaluatedAt: Date
    ) {
        self.traceID = traceID
        self.assessmentID = assessmentID
        self.disposition = disposition
        self.violations = violations
        self.policyVersion = policyVersion
        self.evaluatedAt = evaluatedAt
    }
}

public struct SupervisorPreflightDecision: Codable, Equatable, Sendable {
    public var traceID: SupervisorTraceID
    public var disposition: SupervisorPolicyDisposition
    public var violations: [SupervisorPolicyViolation]
    public var policyVersion: String
    public var evaluatedAt: Date

    public init(
        traceID: SupervisorTraceID,
        disposition: SupervisorPolicyDisposition,
        violations: [SupervisorPolicyViolation],
        policyVersion: String,
        evaluatedAt: Date
    ) {
        self.traceID = traceID
        self.disposition = disposition
        self.violations = violations
        self.policyVersion = policyVersion
        self.evaluatedAt = evaluatedAt
    }
}

public struct CompletionReviewPolicy: Sendable {
    public static let phaseOneVersion = "completion-review-policy-v1"
    public static let liveShadowVersion = "completion-review-policy-v2-live-shadow"

    public enum RuntimeMode: Equatable, Sendable {
        case fixtureOnly
        case authorizedRemoteShadow(approvedProviderIDs: Set<String>)
    }

    public var version: String
    public var runtimeMode: RuntimeMode

    public init(
        version: String = CompletionReviewPolicy.phaseOneVersion,
        runtimeMode: RuntimeMode = .fixtureOnly
    ) {
        self.version = version
        self.runtimeMode = runtimeMode
    }

    public static func liveShadow(approvedProviderIDs: Set<String>) -> Self {
        Self(
            version: liveShadowVersion,
            runtimeMode: .authorizedRemoteShadow(approvedProviderIDs: approvedProviderIDs)
        )
    }

    public func preflight(
        input: CompletionReviewInput,
        provider: SupervisorModelDescriptor,
        now: Date = Date()
    ) -> SupervisorPreflightDecision {
        var violations: [SupervisorPolicyViolation] = []
        validateInput(input, provider: provider, now: now, violations: &violations)
        return SupervisorPreflightDecision(
            traceID: input.traceID,
            disposition: violations.isEmpty ? .allowShadowAssessment : .harnessOnly,
            violations: violations,
            policyVersion: version,
            evaluatedAt: now
        )
    }

    public func evaluate(
        input: CompletionReviewInput,
        assessment: SupervisorAssessment,
        provider: SupervisorModelDescriptor,
        evaluatorResult: CompletionReviewEvaluatorResult? = nil,
        now: Date = Date()
    ) -> SupervisorPolicyDecision {
        var violations = preflight(input: input, provider: provider, now: now).violations
        validateAssessment(
            assessment,
            for: input,
            provider: provider,
            now: now,
            violations: &violations
        )
        validateEvaluatorResult(
            evaluatorResult,
            input: input,
            assessment: assessment,
            now: now,
            violations: &violations
        )

        return SupervisorPolicyDecision(
            traceID: input.traceID,
            assessmentID: assessment.id,
            disposition: violations.isEmpty ? .allowShadowAssessment : .harnessOnly,
            violations: violations,
            policyVersion: version,
            evaluatedAt: now
        )
    }

    private func validateEvaluatorResult(
        _ result: CompletionReviewEvaluatorResult?,
        input: CompletionReviewInput,
        assessment: SupervisorAssessment,
        now: Date,
        violations: inout [SupervisorPolicyViolation]
    ) {
        if result == nil {
            if case .authorizedRemoteShadow = runtimeMode,
               assessment.recommendation == .verifiedReady {
                append(.evaluatorRejected, "Live verified ready requires a deterministic evaluator result", to: &violations)
            }
            return
        }
        guard let result else { return }
        let criterionIDs = Set(input.goal.acceptanceCriteria.map(\.id))
        let evidenceIDs = Set(input.evidence.map(\.id))
        if result.schemaVersion != CompletionReviewEvaluatorResult.currentSchemaVersion
            || result.traceID != input.traceID
            || result.task != input.task
            || result.assessmentID != assessment.id
            || !SupervisorContractText.isCanonical(result.evaluatorID, maximumLength: 128)
            || !SupervisorContractText.isCanonical(result.evaluatorVersion, maximumLength: 80)
            || result.findings.isEmpty
            || result.findings.count > 32
            || result.evaluatedAt < assessment.generatedAt
            || result.evaluatedAt > now.addingTimeInterval(5)
            || result.expiresAt <= now
            || result.expiresAt > input.expiresAt
            || result.expiresAt > assessment.expiresAt {
            append(.evaluatorRejected, "Evaluator result identity, version, or lifetime is invalid", to: &violations)
            return
        }
        if result.findings.contains(where: {
            !SupervisorContractText.isCanonical($0.detail, maximumLength: 500)
                || !Set($0.evidenceIDs).isSubset(of: evidenceIDs)
                || !Set($0.acceptanceCriterionIDs).isSubset(of: criterionIDs)
        }) {
            append(.evaluatorRejected, "Evaluator findings are unbounded or reference unknown identities", to: &violations)
        }
        if result.verdict != .supportsAssessment {
            append(.evaluatorRejected, "Evaluator did not support this assessment", to: &violations)
        }
    }

    private func validateInput(
        _ input: CompletionReviewInput,
        provider: SupervisorModelDescriptor,
        now: Date,
        violations: inout [SupervisorPolicyViolation]
    ) {
        if input.schemaVersion != CompletionReviewInput.currentSchemaVersion {
            append(.unsupportedSchema, "Completion Review input schema is unsupported", to: &violations)
        }
        if input.loopType != .completionReview {
            append(.invalidContract, "Completion Review input has the wrong loop type", to: &violations)
        }
        if input.policyVersion != version {
            append(.invalidContract, "Policy version does not match the deterministic gate", to: &violations)
        }
        if let consent = input.consent {
            let hasValidConfirmation = consent.confirmedAt.map {
                $0 >= consent.preparedAt && $0 <= now && $0 < input.expiresAt
            } ?? false
            if consent.purpose != input.loopType
                || consent.provider != provider
                || consent.maximumDataLevel != input.contextDataLevel
                || consent.localRetentionSeconds != CompletionReviewRuntimeStore.localRetentionLimitSeconds
                || consent.remoteRetentionPolicy != .providerControlled
                || consent.preparedAt != input.createdAt
                || !hasValidConfirmation {
                append(.evidenceNotAuthorized, "Completion Review consent is missing, stale, or mismatched", to: &violations)
            }
            if let evaluator = consent.independentEvaluatorProvider,
               evaluator.executionLocation != .remote
                || !SupervisorContractText.isCanonical(evaluator.providerID, maximumLength: 128)
                || !SupervisorContractText.isCanonical(evaluator.modelID, maximumLength: 128)
                || !SupervisorContractText.isCanonical(evaluator.modelVersion, maximumLength: 80)
                || (evaluator.providerID == provider.providerID
                    && evaluator.modelID == provider.modelID) {
                append(
                    .evidenceNotAuthorized,
                    "Independent evaluator consent is invalid or reuses the supervisor model",
                    to: &violations
                )
            }
        } else {
            append(.evidenceNotAuthorized, "Completion Review requires explicit per-call consent", to: &violations)
        }
        switch runtimeMode {
        case .fixtureOnly:
            if input.contextMode != .syntheticFixture {
                append(.phaseBoundary, "Phase 1 accepts synthetic fixtures only", to: &violations)
            }
            if provider.executionLocation != .fixture {
                append(.phaseBoundary, "Phase 1 accepts fixture providers only", to: &violations)
            }
        case .authorizedRemoteShadow(let approvedProviderIDs):
            if input.contextMode != .authorizedTask {
                append(.phaseBoundary, "Live shadow review requires authorized task context", to: &violations)
            }
            if provider.executionLocation != .remote
                || !approvedProviderIDs.contains(provider.providerID) {
                append(.phaseBoundary, "Remote provider is not approved by the live shadow policy", to: &violations)
            }
        }
        if input.contextDataLevel > .l1StructuredEvidence
            || input.evidence.contains(where: { $0.dataLevel > .l1StructuredEvidence }) {
            append(.phaseBoundary, "Phase 1 does not accept L2 or L3 context", to: &violations)
        }
        if input.evidence.contains(where: { $0.dataLevel > input.contextDataLevel }) {
            append(.invalidContract, "Context data level understates included evidence", to: &violations)
        }
        if SupervisorSensitiveTextScanner.containsProhibitedContent(in: input) {
            append(.sensitiveContent, "Completion Review input contains prohibited secret or source-code content", to: &violations)
        }
        if input.createdAt > now || input.expiresAt <= now || input.expiresAt <= input.createdAt {
            append(.expired, "Completion Review input is not live", to: &violations)
        }
        if !isIdentifier(input.task.taskID)
            || !isIdentifier(input.task.sessionID)
            || !SupervisorContractText.isCanonical(input.contextVersion, maximumLength: 80)
            || !SupervisorContractText.isCanonical(input.policyVersion, maximumLength: 80) {
            append(.invalidContract, "Completion Review identity or version fields are invalid", to: &violations)
        }
        if !SupervisorContractText.isCanonical(provider.providerID, maximumLength: 128)
            || !SupervisorContractText.isCanonical(provider.modelID, maximumLength: 128)
            || !SupervisorContractText.isCanonical(provider.modelVersion, maximumLength: 80) {
            append(.invalidContract, "Provider identity fields are invalid", to: &violations)
        }
        if !SupervisorContractText.isCanonical(input.goal.statement, maximumLength: 1_000)
            || input.goal.acceptanceCriteria.isEmpty
            || input.goal.acceptanceCriteria.count > 32 {
            append(.invalidContract, "Task goal or acceptance criteria are invalid", to: &violations)
        }

        let criterionIDs = input.goal.acceptanceCriteria.map(\.id)
        if Set(criterionIDs).count != criterionIDs.count
            || input.goal.acceptanceCriteria.contains(where: {
                !isIdentifier($0.id)
                    || !SupervisorContractText.isCanonical($0.statement, maximumLength: 500)
            }) {
            append(.invalidContract, "Acceptance criteria must be unique and bounded", to: &violations)
        }

        if input.evidence.isEmpty || input.evidence.count > 32 {
            append(.invalidContract, "Completion Review requires between one and 32 evidence records", to: &violations)
        }
        if Set(input.evidence.map(\.id)).count != input.evidence.count {
            append(.invalidContract, "Evidence identities must be unique", to: &violations)
        }
        if input.evidence.contains(where: { !isCanonicalEvidence($0) }) {
            append(.invalidContract, "Evidence records contain invalid or oversized fields", to: &violations)
        }
        if input.evidence.contains(where: {
            !$0.isUsable(for: input.task, loop: input.loopType, model: provider, now: now)
        }) {
            append(.evidenceNotAuthorized, "Evidence is stale, mismatched, or outside its consent scope", to: &violations)
        }

        if input.allowedActions.isEmpty
            || Set(input.allowedActions).count != input.allowedActions.count {
            append(.invalidContract, "Allowed actions must be a non-empty unique list", to: &violations)
        }
    }

    private func validateAssessment(
        _ assessment: SupervisorAssessment,
        for input: CompletionReviewInput,
        provider: SupervisorModelDescriptor,
        now: Date,
        violations: inout [SupervisorPolicyViolation]
    ) {
        if assessment.schemaVersion != SupervisorAssessment.currentSchemaVersion {
            append(.unsupportedSchema, "Supervisor assessment schema is unsupported", to: &violations)
        }
        if SupervisorSensitiveTextScanner.containsProhibitedContent(in: assessment) {
            append(.sensitiveContent, "Supervisor assessment contains prohibited secret or source-code content", to: &violations)
        }
        if assessment.loopType != .completionReview {
            append(.invalidContract, "Supervisor assessment has the wrong loop type", to: &violations)
        }
        if assessment.traceID != input.traceID {
            append(.traceMismatch, "Assessment trace does not match its input", to: &violations)
        }
        if assessment.task != input.task {
            append(.identityMismatch, "Assessment task does not match its input", to: &violations)
        }
        if assessment.model != provider {
            append(.providerMismatch, "Assessment model identity does not match the provider", to: &violations)
        }
        if assessment.generatedAt < input.createdAt
            || assessment.generatedAt > now.addingTimeInterval(5)
            || assessment.expiresAt <= now
            || assessment.expiresAt > input.expiresAt {
            append(.expired, "Assessment timestamps are outside the live input window", to: &violations)
        }

        let availableEvidenceIDs = Set(input.evidence.map(\.id))
        let usedEvidenceIDs = Set(assessment.usedEvidenceIDs)
        let criterionIDs = Set(input.goal.acceptanceCriteria.map(\.id))
        if assessment.usedEvidenceIDs.isEmpty
            || usedEvidenceIDs.count != assessment.usedEvidenceIDs.count
            || !usedEvidenceIDs.isSubset(of: availableEvidenceIDs) {
            append(.evidenceNotGrounded, "Assessment uses missing or duplicate evidence identities", to: &violations)
        }

        if assessment.observedFacts.isEmpty
            || assessment.observedFacts.count > 32
            || Set(assessment.observedFacts.map(\.id)).count != assessment.observedFacts.count
            || assessment.observedFacts.contains(where: {
                !isIdentifier($0.id)
                    || !SupervisorContractText.isCanonical($0.statement, maximumLength: 500)
                    || $0.acceptanceCriterionIDs.isEmpty
                    || !Set($0.acceptanceCriterionIDs).isSubset(of: criterionIDs)
                    || $0.evidenceIDs.isEmpty
                    || !Set($0.evidenceIDs).isSubset(of: usedEvidenceIDs)
            }) {
            append(.evidenceNotGrounded, "Observed facts must be bounded and grounded in used evidence", to: &violations)
        }

        if assessment.inferences.count > 32
            || Set(assessment.inferences.map(\.id)).count != assessment.inferences.count
            || assessment.inferences.contains(where: {
                !isIdentifier($0.id)
                    || !SupervisorContractText.isCanonical($0.statement, maximumLength: 500)
                    || $0.evidenceIDs.isEmpty
                    || !Set($0.evidenceIDs).isSubset(of: usedEvidenceIDs)
            }) {
            append(.evidenceNotGrounded, "Inferences must remain separate and evidence-linked", to: &violations)
        }

        if assessment.missingEvidence.count > 32
            || Set(assessment.missingEvidence.map(\.id)).count != assessment.missingEvidence.count
            || assessment.missingEvidence.contains(where: {
                !isIdentifier($0.id)
                    || !SupervisorContractText.isCanonical($0.statement, maximumLength: 500)
                    || $0.acceptanceCriterionIDs.isEmpty
                    || !Set($0.acceptanceCriterionIDs).isSubset(of: criterionIDs)
            }) {
            append(.invalidContract, "Evidence gaps must reference known acceptance criteria", to: &violations)
        }

        if assessment.risk.factors.count > 16
            || assessment.risk.impactScopes.count > 16
            || assessment.risk.factors.contains(where: {
                !SupervisorContractText.isCanonical($0, maximumLength: 300)
            })
            || assessment.risk.impactScopes.contains(where: {
                !SupervisorContractText.isCanonical($0, maximumLength: 160)
            }) {
            append(.invalidContract, "Risk factors or impact scopes are invalid or oversized", to: &violations)
        }
        if !assessment.invalidatesOnNewerTaskEvent {
            append(.invalidContract, "Assessment must expire when the task has newer activity", to: &violations)
        }

        if assessment.uncertainty.reasons.count > 16
            || assessment.uncertainty.reasons.contains(where: {
                !SupervisorContractText.isCanonical($0, maximumLength: 300)
            }) {
            append(.invalidContract, "Uncertainty reasons are invalid or oversized", to: &violations)
        }

        let allowedActions = Set(input.allowedActions)
        let recommendationActions = Self.actionsAllowed(for: assessment.recommendation)
        if assessment.proposedActions.isEmpty
            || Set(assessment.proposedActions).count != assessment.proposedActions.count
            || !Set(assessment.proposedActions).isSubset(of: allowedActions)
            || !Set(assessment.proposedActions).isSubset(of: recommendationActions) {
            append(.unsupportedAction, "Assessment proposes an action outside deterministic policy", to: &violations)
        }

        if assessment.recommendation == .verifiedReady {
            let usedEvidence = input.evidence.filter { usedEvidenceIDs.contains($0.id) }
            let coveredCriteria = Set(assessment.observedFacts.flatMap(\.acceptanceCriterionIDs))
            if !assessment.missingEvidence.isEmpty
                || assessment.uncertainty.level != .low
                || assessment.risk.level == .high
                || assessment.risk.level == .critical
                || assessment.risk.reversibility == .irreversible
                || assessment.risk.reversibility == .unknown
                || coveredCriteria != criterionIDs
                || usedEvidence.isEmpty
                || usedEvidence.contains(where: { $0.integrity != .complete }) {
                append(.unsafeVerifiedReady, "Verified ready requires complete coverage, bounded risk, no gaps, and low uncertainty", to: &violations)
            }
        }
        if assessment.recommendation == .missingEvidence && assessment.missingEvidence.isEmpty {
            append(.invalidContract, "Missing-evidence recommendation must name an evidence gap", to: &violations)
        }
    }

    private static func actionsAllowed(
        for recommendation: CompletionReviewRecommendation
    ) -> Set<SupervisorCandidateAction> {
        switch recommendation {
        case .verifiedReady:
            [.presentCompletionConfirmation, .openSourceAgent, .requestHumanReview]
        case .missingEvidence:
            [.requestEvidence, .openSourceAgent, .requestHumanReview]
        case .continueWork:
            [.continueInSourceAgent, .openSourceAgent, .requestHumanReview]
        case .humanReviewRequired:
            [.requestHumanReview, .openSourceAgent]
        }
    }

    private func isCanonicalEvidence(_ evidence: EvidenceRecord) -> Bool {
        evidence.schemaVersion == EvidenceRecord.currentSchemaVersion
            && isIdentifier(evidence.taskID)
            && isIdentifier(evidence.sessionID)
            && SupervisorContractText.isCanonical(evidence.source.sourceID, maximumLength: 128)
            && SupervisorContractText.isCanonical(evidence.summary, maximumLength: 500)
            && (evidence.reference.map {
                SupervisorContractText.isCanonical($0, maximumLength: 512)
            } ?? true)
            && evidence.consentScope.approvedRemoteProviderIDs.allSatisfy {
                SupervisorContractText.isCanonical($0, maximumLength: 128)
            }
    }

    private func isIdentifier(_ value: String) -> Bool {
        SupervisorContractText.isCanonical(value, maximumLength: 256)
    }

    private func append(
        _ code: SupervisorPolicyViolationCode,
        _ detail: String,
        to violations: inout [SupervisorPolicyViolation]
    ) {
        let violation = SupervisorPolicyViolation(code: code, detail: detail)
        if !violations.contains(violation) {
            violations.append(violation)
        }
    }
}
