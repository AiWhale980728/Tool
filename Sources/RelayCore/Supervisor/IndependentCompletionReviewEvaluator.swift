import Foundation

public enum IndependentCompletionReviewFindingCode: String, Codable, CaseIterable, Sendable {
    case assessmentConsistent = "assessment_consistent"
    case unsupportedFact = "unsupported_fact"
    case incompleteCriterionCoverage = "incomplete_criterion_coverage"
    case missedEvidenceGap = "missed_evidence_gap"
    case riskUnderstated = "risk_understated"
    case uncertaintyUnderstated = "uncertainty_understated"
    case recommendationUnsafe = "recommendation_unsafe"
}

public struct IndependentCompletionReviewFinding: Codable, Equatable, Sendable {
    public var code: IndependentCompletionReviewFindingCode
    public var detail: String
    public var evidenceIDs: [UUID]
    public var acceptanceCriterionIDs: [String]

    public init(
        code: IndependentCompletionReviewFindingCode,
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

public struct IndependentCompletionReviewScores: Codable, Equatable, Sendable {
    public var groundedness: Double
    public var criterionCoverage: Double
    public var riskCalibration: Double

    public init(groundedness: Double, criterionCoverage: Double, riskCalibration: Double) {
        self.groundedness = groundedness
        self.criterionCoverage = criterionCoverage
        self.riskCalibration = riskCalibration
    }

    var isValid: Bool {
        [groundedness, criterionCoverage, riskCalibration].allSatisfy {
            $0.isFinite && (0...1).contains($0)
        }
    }
}

public struct IndependentCompletionReviewEvaluatorResult: Codable, Equatable, Identifiable, Sendable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var id: UUID
    public var traceID: SupervisorTraceID
    public var task: SupervisorTaskIdentity
    public var assessmentID: UUID
    public var model: SupervisorModelDescriptor
    public var verdict: CompletionReviewEvaluatorVerdict
    public var scores: IndependentCompletionReviewScores
    public var findings: [IndependentCompletionReviewFinding]
    public var evaluatedAt: Date
    public var expiresAt: Date

    public init(
        schemaVersion: Int = currentSchemaVersion,
        id: UUID = UUID(),
        traceID: SupervisorTraceID,
        task: SupervisorTaskIdentity,
        assessmentID: UUID,
        model: SupervisorModelDescriptor,
        verdict: CompletionReviewEvaluatorVerdict,
        scores: IndependentCompletionReviewScores,
        findings: [IndependentCompletionReviewFinding],
        evaluatedAt: Date,
        expiresAt: Date
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.traceID = traceID
        self.task = task
        self.assessmentID = assessmentID
        self.model = model
        self.verdict = verdict
        self.scores = scores
        self.findings = findings
        self.evaluatedAt = evaluatedAt
        self.expiresAt = expiresAt
    }
}

public struct IndependentCompletionReviewProviderResult: Equatable, Sendable {
    public var evaluation: IndependentCompletionReviewEvaluatorResult
    public var receipt: SupervisorProviderReceipt?

    public init(
        evaluation: IndependentCompletionReviewEvaluatorResult,
        receipt: SupervisorProviderReceipt? = nil
    ) {
        self.evaluation = evaluation
        self.receipt = receipt
    }
}

public protocol IndependentCompletionReviewEvaluatorProvider: Sendable {
    var descriptor: SupervisorModelDescriptor { get }
    var promptVersion: String { get }

    func evaluate(
        input: CompletionReviewInput,
        assessment: SupervisorAssessment
    ) async throws -> IndependentCompletionReviewProviderResult
}

public enum IndependentCompletionReviewFallbackCode: String, Codable, Sendable {
    case notConfigured = "not_configured"
    case consentMismatch = "consent_mismatch"
    case nonIndependentModel = "non_independent_model"
    case providerUnavailable = "provider_unavailable"
    case providerTimeout = "provider_timeout"
    case invalidStructuredOutput = "invalid_structured_output"
    case providerCancelled = "provider_cancelled"
    case providerFailure = "provider_failure"
    case duplicateRequest = "duplicate_request"
    case providerConcurrencyLimit = "provider_concurrency_limit"
    case providerRateLimit = "provider_rate_limit"
    case providerCircuitOpen = "provider_circuit_open"
}

public struct StoredIndependentCompletionReviewEvaluation: Codable, Equatable, Sendable {
    public var result: IndependentCompletionReviewEvaluatorResult?
    public var providerReceipt: SupervisorProviderReceipt?
    public var providerFailureReceipt: SupervisorProviderFailureReceipt?
    public var fallbackCode: IndependentCompletionReviewFallbackCode?
    public var recordedAt: Date

    public init(
        result: IndependentCompletionReviewEvaluatorResult? = nil,
        providerReceipt: SupervisorProviderReceipt? = nil,
        providerFailureReceipt: SupervisorProviderFailureReceipt? = nil,
        fallbackCode: IndependentCompletionReviewFallbackCode? = nil,
        recordedAt: Date
    ) {
        self.result = result
        self.providerReceipt = providerReceipt
        self.providerFailureReceipt = providerFailureReceipt
        self.fallbackCode = fallbackCode
        self.recordedAt = recordedAt
    }
}

public struct IndependentCompletionReviewEvaluatorExecutor: Sendable {
    public init() {}

    public func execute(
        input: CompletionReviewInput,
        assessment: SupervisorAssessment,
        using provider: any IndependentCompletionReviewEvaluatorProvider,
        coordinator: CompletionReviewExecutionCoordinator? = nil,
        now: Date = Date()
    ) async -> StoredIndependentCompletionReviewEvaluation {
        guard let consent = input.consent,
              let confirmedAt = consent.confirmedAt,
              confirmedAt >= consent.preparedAt,
              confirmedAt <= now,
              confirmedAt < input.expiresAt,
              consent.independentEvaluatorProvider == provider.descriptor,
              provider.descriptor.executionLocation == .remote else {
            return fallback(.consentMismatch, now: now)
        }
        guard provider.descriptor.providerID != assessment.model.providerID
                || provider.descriptor.modelID != assessment.model.modelID else {
            return fallback(.nonIndependentModel, now: now)
        }
        guard input.traceID == assessment.traceID,
              input.task == assessment.task,
              input.expiresAt > now,
              assessment.expiresAt > now,
              !SupervisorSensitiveTextScanner.containsProhibitedContent(in: input),
              !SupervisorSensitiveTextScanner.containsProhibitedContent(in: assessment) else {
            return fallback(.consentMismatch, now: now)
        }

        let permit: CompletionReviewExecutionPermit?
        if let coordinator {
            switch await coordinator.begin(input: input, provider: provider.descriptor, now: now) {
            case .success(let granted):
                permit = granted
            case .failure(let failure):
                let code: IndependentCompletionReviewFallbackCode = switch failure {
                case .duplicateRequest: .duplicateRequest
                case .concurrencyLimit: .providerConcurrencyLimit
                case .rateLimit: .providerRateLimit
                case .circuitOpen: .providerCircuitOpen
                }
                return fallback(code, now: now)
            }
        } else {
            permit = nil
        }

        do {
            let providerResult = try await provider.evaluate(input: input, assessment: assessment)
            let result = providerResult.evaluation
            guard isValid(
                result,
                receipt: providerResult.receipt,
                input: input,
                assessment: assessment,
                provider: provider.descriptor,
                expectedPromptVersion: provider.promptVersion,
                now: max(now, result.evaluatedAt)
            ) else {
                if let coordinator, let permit {
                    await coordinator.finish(permit, providerSucceeded: false, now: now)
                }
                return fallback(.invalidStructuredOutput, now: now)
            }
            if let coordinator, let permit {
                await coordinator.finish(permit, providerSucceeded: true, now: now)
            }
            return StoredIndependentCompletionReviewEvaluation(
                result: result,
                providerReceipt: providerResult.receipt,
                recordedAt: result.evaluatedAt
            )
        } catch let failure as SupervisorProviderFailure {
            let receipt = failure.receipt
            guard receipt.isValid(
                for: provider.descriptor,
                expectedPromptVersion: provider.promptVersion,
                input: input,
                now: now
            ) else {
                if let coordinator, let permit {
                    await coordinator.finish(permit, providerSucceeded: false, now: now)
                }
                return fallback(.invalidStructuredOutput, now: now)
            }
            let code: IndependentCompletionReviewFallbackCode = switch receipt.failureKind {
            case .unavailable: .providerUnavailable
            case .timeout: .providerTimeout
            case .invalidStructuredOutput: .invalidStructuredOutput
            case .cancelled: .providerCancelled
            case .providerFailure: .providerFailure
            }
            if let coordinator, let permit {
                await coordinator.finish(
                    permit,
                    providerSucceeded: false,
                    countFailure: receipt.failureKind != .cancelled,
                    now: now
                )
            }
            return fallback(code, failureReceipt: receipt, now: now)
        } catch let error as SupervisorProviderError {
            let code: IndependentCompletionReviewFallbackCode = switch error {
            case .unavailable: .providerUnavailable
            case .timeout: .providerTimeout
            case .invalidStructuredOutput: .invalidStructuredOutput
            case .cancelled: .providerCancelled
            }
            if let coordinator, let permit {
                await coordinator.finish(permit, providerSucceeded: false, now: now)
            }
            return fallback(code, now: now)
        } catch {
            if let coordinator, let permit {
                await coordinator.finish(permit, providerSucceeded: false, now: now)
            }
            return fallback(.providerFailure, now: now)
        }
    }

    private func isValid(
        _ result: IndependentCompletionReviewEvaluatorResult,
        receipt: SupervisorProviderReceipt?,
        input: CompletionReviewInput,
        assessment: SupervisorAssessment,
        provider: SupervisorModelDescriptor,
        expectedPromptVersion: String,
        now: Date
    ) -> Bool {
        let evidenceIDs = Set(input.evidence.map(\.id))
        let criterionIDs = Set(input.goal.acceptanceCriteria.map(\.id))
        return result.schemaVersion == IndependentCompletionReviewEvaluatorResult.currentSchemaVersion
            && result.traceID == input.traceID
            && result.task == input.task
            && result.assessmentID == assessment.id
            && result.model == provider
            && result.scores.isValid
            && !result.findings.isEmpty
            && result.findings.count <= 32
            && result.findings.allSatisfy {
                SupervisorContractText.isCanonical($0.detail, maximumLength: 500)
                    && Set($0.evidenceIDs).isSubset(of: evidenceIDs)
                    && Set($0.acceptanceCriterionIDs).isSubset(of: criterionIDs)
            }
            && result.evaluatedAt >= assessment.generatedAt
            && result.evaluatedAt <= now.addingTimeInterval(5)
            && result.expiresAt > now
            && result.expiresAt <= input.expiresAt
            && result.expiresAt <= assessment.expiresAt
            && !SupervisorSensitiveTextScanner.containsProhibitedContent(in: result)
            && SupervisorContractText.isCanonical(expectedPromptVersion, maximumLength: 80)
            && receipt?.promptVersion == expectedPromptVersion
            && (receipt?.isValid(for: provider, completedAt: result.evaluatedAt) ?? false)
    }

    private func fallback(
        _ code: IndependentCompletionReviewFallbackCode,
        failureReceipt: SupervisorProviderFailureReceipt? = nil,
        now: Date
    ) -> StoredIndependentCompletionReviewEvaluation {
        StoredIndependentCompletionReviewEvaluation(
            providerFailureReceipt: failureReceipt,
            fallbackCode: code,
            recordedAt: now
        )
    }
}
