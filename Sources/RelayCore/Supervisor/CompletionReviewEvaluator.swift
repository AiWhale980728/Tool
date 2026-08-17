import Foundation

public enum CompletionReviewEvaluatorVerdict: String, Codable, Sendable {
    case supportsAssessment = "supports_assessment"
    case rejectsAssessment = "rejects_assessment"
    case humanReviewRequired = "human_review_required"
}

public enum CompletionReviewEvaluatorFindingCode: String, Codable, CaseIterable, Sendable {
    case assessmentConsistent = "assessment_consistent"
    case missingIndependentEvidence = "missing_independent_evidence"
    case incompleteCriterionCoverage = "incomplete_criterion_coverage"
    case evidenceGapRemains = "evidence_gap_remains"
    case elevatedRisk = "elevated_risk"
    case elevatedUncertainty = "elevated_uncertainty"
}

public struct CompletionReviewEvaluatorFinding: Codable, Equatable, Sendable {
    public var code: CompletionReviewEvaluatorFindingCode
    public var detail: String
    public var evidenceIDs: [UUID]
    public var acceptanceCriterionIDs: [String]

    public init(
        code: CompletionReviewEvaluatorFindingCode,
        detail: String,
        evidenceIDs: [UUID] = [],
        acceptanceCriterionIDs: [String] = []
    ) {
        self.code = code
        self.detail = detail
        self.evidenceIDs = evidenceIDs
        self.acceptanceCriterionIDs = acceptanceCriterionIDs
    }
}

public struct CompletionReviewEvaluatorResult: Codable, Equatable, Identifiable, Sendable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var id: UUID
    public var traceID: SupervisorTraceID
    public var task: SupervisorTaskIdentity
    public var assessmentID: UUID
    public var evaluatorID: String
    public var evaluatorVersion: String
    public var verdict: CompletionReviewEvaluatorVerdict
    public var findings: [CompletionReviewEvaluatorFinding]
    public var evaluatedAt: Date
    public var expiresAt: Date

    public init(
        schemaVersion: Int = currentSchemaVersion,
        id: UUID = UUID(),
        traceID: SupervisorTraceID,
        task: SupervisorTaskIdentity,
        assessmentID: UUID,
        evaluatorID: String,
        evaluatorVersion: String,
        verdict: CompletionReviewEvaluatorVerdict,
        findings: [CompletionReviewEvaluatorFinding],
        evaluatedAt: Date,
        expiresAt: Date
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.traceID = traceID
        self.task = task
        self.assessmentID = assessmentID
        self.evaluatorID = evaluatorID
        self.evaluatorVersion = evaluatorVersion
        self.verdict = verdict
        self.findings = findings
        self.evaluatedAt = evaluatedAt
        self.expiresAt = expiresAt
    }
}

public protocol CompletionReviewEvaluator: Sendable {
    func evaluate(
        input: CompletionReviewInput,
        assessment: SupervisorAssessment,
        now: Date
    ) async -> CompletionReviewEvaluatorResult
}

public struct DeterministicCompletionReviewEvaluator: CompletionReviewEvaluator, Sendable {
    public static let evaluatorID = "relay-deterministic-completion-evaluator"
    public static let version = "completion-evaluator-v1"

    public init() {}

    public func evaluate(
        input: CompletionReviewInput,
        assessment: SupervisorAssessment,
        now: Date
    ) async -> CompletionReviewEvaluatorResult {
        let usedIDs = Set(assessment.usedEvidenceIDs)
        let usedEvidence = input.evidence.filter { usedIDs.contains($0.id) }
        let criteria = Set(input.goal.acceptanceCriteria.map(\.id))
        let covered = Set(assessment.observedFacts.flatMap(\.acceptanceCriterionIDs))
        var findings: [CompletionReviewEvaluatorFinding] = []

        if assessment.recommendation == .verifiedReady {
            let independent = usedEvidence.filter {
                $0.integrity == .complete && ($0.source.kind == .tool || $0.source.kind == .system)
            }
            let independentIDs = Set(independent.map(\.id))
            let independentlyCovered = Set(
                assessment.observedFacts
                    .filter { !independentIDs.isDisjoint(with: $0.evidenceIDs) }
                    .flatMap(\.acceptanceCriterionIDs)
            )
            if independent.isEmpty {
                findings.append(CompletionReviewEvaluatorFinding(
                    code: .missingIndependentEvidence,
                    detail: "确认完成需要完整的工具或系统证据。"
                ))
            }
            if independentlyCovered != criteria {
                findings.append(CompletionReviewEvaluatorFinding(
                    code: .incompleteCriterionCoverage,
                    detail: "完整的工具或系统证据未覆盖所有验收条件。",
                    acceptanceCriterionIDs: Array(criteria.subtracting(independentlyCovered)).sorted()
                ))
            }
            if !assessment.missingEvidence.isEmpty {
                findings.append(CompletionReviewEvaluatorFinding(
                    code: .evidenceGapRemains,
                    detail: "评估结果仍报告存在缺失证据。"
                ))
            }
            if assessment.risk.level == .high || assessment.risk.level == .critical {
                findings.append(CompletionReviewEvaluatorFinding(
                    code: .elevatedRisk,
                    detail: "高风险或严重风险不能通过完成确认。"
                ))
            }
            if assessment.uncertainty.level != .low {
                findings.append(CompletionReviewEvaluatorFinding(
                    code: .elevatedUncertainty,
                    detail: "确认完成要求不确定性为低。"
                ))
            }
        }

        if findings.isEmpty {
            findings = [CompletionReviewEvaluatorFinding(
                code: .assessmentConsistent,
                detail: "评估结果符合确定性评估器合同。",
                evidenceIDs: assessment.usedEvidenceIDs,
                acceptanceCriterionIDs: Array(covered).sorted()
            )]
        }
        let verdict: CompletionReviewEvaluatorVerdict = findings.allSatisfy {
            $0.code == .assessmentConsistent
        } ? .supportsAssessment : .rejectsAssessment
        return CompletionReviewEvaluatorResult(
            traceID: input.traceID,
            task: input.task,
            assessmentID: assessment.id,
            evaluatorID: Self.evaluatorID,
            evaluatorVersion: Self.version,
            verdict: verdict,
            findings: findings,
            evaluatedAt: now,
            expiresAt: min(input.expiresAt, assessment.expiresAt)
        )
    }
}
