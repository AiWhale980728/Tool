import Foundation

public protocol SupervisorModelProvider: Sendable {
    var descriptor: SupervisorModelDescriptor { get }
    var promptVersion: String { get }

    func assessCompletion(
        _ input: CompletionReviewInput
    ) async throws -> SupervisorAssessment

    func assessCompletionWithReceipt(
        _ input: CompletionReviewInput
    ) async throws -> SupervisorProviderResult
}

public extension SupervisorModelProvider {
    func assessCompletionWithReceipt(
        _ input: CompletionReviewInput
    ) async throws -> SupervisorProviderResult {
        SupervisorProviderResult(assessment: try await assessCompletion(input))
    }
}

public struct SupervisorProviderReceipt: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var providerID: String
    public var requestedModelID: String
    public var returnedModelID: String?
    public var promptVersion: String
    public var inputTokenCount: Int?
    public var outputTokenCount: Int?
    public var totalTokenCount: Int?
    public var latencyMilliseconds: Int
    public var completedAt: Date

    public init(
        schemaVersion: Int = currentSchemaVersion,
        providerID: String,
        requestedModelID: String,
        returnedModelID: String?,
        promptVersion: String,
        inputTokenCount: Int?,
        outputTokenCount: Int?,
        totalTokenCount: Int?,
        latencyMilliseconds: Int,
        completedAt: Date
    ) {
        self.schemaVersion = schemaVersion
        self.providerID = providerID
        self.requestedModelID = requestedModelID
        self.returnedModelID = returnedModelID
        self.promptVersion = promptVersion
        self.inputTokenCount = inputTokenCount.map { min(max(0, $0), 10_000_000) }
        self.outputTokenCount = outputTokenCount.map { min(max(0, $0), 10_000_000) }
        self.totalTokenCount = totalTokenCount.map { min(max(0, $0), 20_000_000) }
        self.latencyMilliseconds = min(max(0, latencyMilliseconds), 120_000)
        self.completedAt = completedAt
    }

    func isValid(
        for descriptor: SupervisorModelDescriptor,
        assessment: SupervisorAssessment
    ) -> Bool {
        isValid(for: descriptor, completedAt: assessment.generatedAt)
    }

    func isValid(
        for descriptor: SupervisorModelDescriptor,
        completedAt expectedCompletionTime: Date
    ) -> Bool {
        schemaVersion == Self.currentSchemaVersion
            && providerID == descriptor.providerID
            && requestedModelID == descriptor.modelID
            && SupervisorContractText.isCanonical(providerID, maximumLength: 128)
            && SupervisorContractText.isCanonical(requestedModelID, maximumLength: 128)
            && (returnedModelID.map {
                SupervisorContractText.isCanonical($0, maximumLength: 128)
            } ?? true)
            && SupervisorContractText.isCanonical(promptVersion, maximumLength: 80)
            && (inputTokenCount.map { (0...10_000_000).contains($0) } ?? true)
            && (outputTokenCount.map { (0...10_000_000).contains($0) } ?? true)
            && (totalTokenCount.map { (0...20_000_000).contains($0) } ?? true)
            && (totalTokenCount.map { total in
                total >= (inputTokenCount ?? 0) && total >= (outputTokenCount ?? 0)
            } ?? true)
            && (0...120_000).contains(latencyMilliseconds)
            && completedAt == expectedCompletionTime
    }
}

public struct SupervisorProviderResult: Equatable, Sendable {
    public var assessment: SupervisorAssessment
    public var receipt: SupervisorProviderReceipt?

    public init(
        assessment: SupervisorAssessment,
        receipt: SupervisorProviderReceipt? = nil
    ) {
        self.assessment = assessment
        self.receipt = receipt
    }
}

public enum SupervisorProviderFailureKind: String, Codable, Sendable {
    case unavailable
    case timeout
    case invalidStructuredOutput = "invalid_structured_output"
    case cancelled
    case providerFailure = "provider_failure"
}

public struct SupervisorProviderFailureReceipt: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var providerID: String
    public var requestedModelID: String
    public var promptVersion: String
    public var failureKind: SupervisorProviderFailureKind
    public var latencyMilliseconds: Int
    public var attemptedAt: Date

    public init(
        schemaVersion: Int = currentSchemaVersion,
        providerID: String,
        requestedModelID: String,
        promptVersion: String,
        failureKind: SupervisorProviderFailureKind,
        latencyMilliseconds: Int,
        attemptedAt: Date
    ) {
        self.schemaVersion = schemaVersion
        self.providerID = providerID
        self.requestedModelID = requestedModelID
        self.promptVersion = promptVersion
        self.failureKind = failureKind
        self.latencyMilliseconds = min(max(0, latencyMilliseconds), 120_000)
        self.attemptedAt = attemptedAt
    }

    func isValid(
        for descriptor: SupervisorModelDescriptor,
        expectedPromptVersion: String,
        input: CompletionReviewInput,
        now: Date
    ) -> Bool {
        schemaVersion == Self.currentSchemaVersion
            && providerID == descriptor.providerID
            && requestedModelID == descriptor.modelID
            && promptVersion == expectedPromptVersion
            && SupervisorContractText.isCanonical(providerID, maximumLength: 128)
            && SupervisorContractText.isCanonical(requestedModelID, maximumLength: 128)
            && SupervisorContractText.isCanonical(promptVersion, maximumLength: 80)
            && (0...120_000).contains(latencyMilliseconds)
            && attemptedAt >= input.createdAt
            && attemptedAt <= input.expiresAt
            && attemptedAt <= now.addingTimeInterval(5)
    }
}

public struct SupervisorProviderFailure: Error, Equatable, Sendable {
    public var receipt: SupervisorProviderFailureReceipt

    public init(receipt: SupervisorProviderFailureReceipt) {
        self.receipt = receipt
    }
}

public enum SupervisorProviderError: Error, Equatable, Sendable {
    case unavailable
    case timeout
    case invalidStructuredOutput
    case cancelled
}

public enum SupervisorFallbackCode: String, Codable, Sendable {
    case providerUnavailable = "provider_unavailable"
    case providerTimeout = "provider_timeout"
    case invalidStructuredOutput = "invalid_structured_output"
    case providerCancelled = "provider_cancelled"
    case providerFailure = "provider_failure"
    case policyRejected = "policy_rejected"
    case duplicateRequest = "duplicate_request"
    case providerConcurrencyLimit = "provider_concurrency_limit"
    case providerRateLimit = "provider_rate_limit"
    case providerCircuitOpen = "provider_circuit_open"
}

public struct SupervisorFallback: Codable, Equatable, Sendable {
    public var traceID: SupervisorTraceID
    public var code: SupervisorFallbackCode
    public var preflightDecision: SupervisorPreflightDecision?
    public var policyDecision: SupervisorPolicyDecision?
    public var evaluatorResult: CompletionReviewEvaluatorResult?
    public var providerReceipt: SupervisorProviderReceipt?
    public var providerFailureReceipt: SupervisorProviderFailureReceipt?

    public init(
        traceID: SupervisorTraceID,
        code: SupervisorFallbackCode,
        preflightDecision: SupervisorPreflightDecision? = nil,
        policyDecision: SupervisorPolicyDecision? = nil,
        evaluatorResult: CompletionReviewEvaluatorResult? = nil,
        providerReceipt: SupervisorProviderReceipt? = nil,
        providerFailureReceipt: SupervisorProviderFailureReceipt? = nil
    ) {
        self.traceID = traceID
        self.code = code
        self.preflightDecision = preflightDecision
        self.policyDecision = policyDecision
        self.evaluatorResult = evaluatorResult
        self.providerReceipt = providerReceipt
        self.providerFailureReceipt = providerFailureReceipt
    }
}

public enum CompletionReviewExecutionResult: Equatable, Sendable {
    case shadowAssessment(
        SupervisorAssessment,
        CompletionReviewEvaluatorResult?,
        SupervisorPolicyDecision,
        SupervisorProviderReceipt?
    )
    case harnessOnly(SupervisorFallback)
}

public struct CompletionReviewExecutor: Sendable {
    public var policy: CompletionReviewPolicy

    public init(policy: CompletionReviewPolicy = CompletionReviewPolicy()) {
        self.policy = policy
    }

    public func execute<Provider: SupervisorModelProvider>(
        input: CompletionReviewInput,
        using provider: Provider,
        evaluator: (any CompletionReviewEvaluator)? = nil,
        coordinator: CompletionReviewExecutionCoordinator? = nil,
        now: Date = Date()
    ) async -> CompletionReviewExecutionResult {
        let preflight = policy.preflight(
            input: input,
            provider: provider.descriptor,
            now: now
        )
        guard preflight.disposition == .allowShadowAssessment else {
            return .harnessOnly(SupervisorFallback(
                traceID: input.traceID,
                code: .policyRejected,
                preflightDecision: preflight
            ))
        }

        let permit: CompletionReviewExecutionPermit?
        if let coordinator {
            switch await coordinator.begin(input: input, provider: provider.descriptor, now: now) {
            case .success(let granted):
                permit = granted
            case .failure(let failure):
                let code: SupervisorFallbackCode = switch failure {
                case .duplicateRequest: .duplicateRequest
                case .concurrencyLimit: .providerConcurrencyLimit
                case .rateLimit: .providerRateLimit
                case .circuitOpen: .providerCircuitOpen
                }
                return .harnessOnly(SupervisorFallback(
                    traceID: input.traceID,
                    code: code,
                    preflightDecision: preflight
                ))
            }
        } else {
            permit = nil
        }

        do {
            let providerResult = try await provider.assessCompletionWithReceipt(input)
            let assessment = providerResult.assessment
            if let receipt = providerResult.receipt,
               (receipt.promptVersion != provider.promptVersion
                || !receipt.isValid(for: provider.descriptor, assessment: assessment)) {
                if let coordinator, let permit {
                    await coordinator.finish(permit, providerSucceeded: false, now: now)
                }
                return .harnessOnly(SupervisorFallback(
                    traceID: input.traceID,
                    code: .invalidStructuredOutput,
                    preflightDecision: preflight
                ))
            }
            let evaluationTime = max(now, assessment.generatedAt)
            let evaluatorResult = await evaluator?.evaluate(
                input: input,
                assessment: assessment,
                now: evaluationTime
            )
            let decision = policy.evaluate(
                input: input,
                assessment: assessment,
                provider: provider.descriptor,
                evaluatorResult: evaluatorResult,
                now: evaluationTime
            )
            guard decision.disposition == .allowShadowAssessment else {
                if let coordinator, let permit {
                    await coordinator.finish(permit, providerSucceeded: true, now: now)
                }
                return .harnessOnly(SupervisorFallback(
                    traceID: input.traceID,
                    code: .policyRejected,
                    policyDecision: decision,
                    evaluatorResult: evaluatorResult,
                    providerReceipt: providerResult.receipt
                ))
            }
            if let coordinator, let permit {
                await coordinator.finish(permit, providerSucceeded: true, now: now)
            }
            return .shadowAssessment(
                assessment,
                evaluatorResult,
                decision,
                providerResult.receipt
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
                return .harnessOnly(SupervisorFallback(
                    traceID: input.traceID,
                    code: .invalidStructuredOutput
                ))
            }
            let code: SupervisorFallbackCode = switch receipt.failureKind {
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
            return .harnessOnly(SupervisorFallback(
                traceID: input.traceID,
                code: code,
                providerFailureReceipt: receipt
            ))
        } catch let error as SupervisorProviderError {
            let code: SupervisorFallbackCode = switch error {
            case .unavailable: .providerUnavailable
            case .timeout: .providerTimeout
            case .invalidStructuredOutput: .invalidStructuredOutput
            case .cancelled: .providerCancelled
            }
            if let coordinator, let permit {
                await coordinator.finish(
                    permit,
                    providerSucceeded: false,
                    countFailure: error != .cancelled,
                    now: now
                )
            }
            return .harnessOnly(SupervisorFallback(traceID: input.traceID, code: code))
        } catch {
            // Detailed provider errors are intentionally not retained in the canonical
            // fallback contract. The deterministic Harness remains available.
            if let coordinator, let permit {
                await coordinator.finish(permit, providerSucceeded: false, now: now)
            }
            return .harnessOnly(SupervisorFallback(
                traceID: input.traceID,
                code: .providerFailure
            ))
        }
    }
}
