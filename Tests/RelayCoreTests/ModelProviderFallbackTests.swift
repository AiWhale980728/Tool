import Foundation
import Testing
@testable import RelayCore

@Suite("Supervisor provider fallback")
struct ModelProviderFallbackTests {
    @Test
    func validProviderOutputIsShadowOnly() async {
        let input = SupervisorTestSupport.input()
        let provider = StubSupervisorProvider(
            descriptor: SupervisorTestSupport.provider,
            response: .success(SupervisorTestSupport.assessment(for: input))
        )

        let result = await CompletionReviewExecutor().execute(
            input: input,
            using: provider,
            now: SupervisorTestSupport.now
        )

        guard case .shadowAssessment(_, _, let decision, _) = result else {
            Issue.record("Expected a shadow assessment")
            return
        }
        #expect(decision.disposition == .allowShadowAssessment)
    }

    @Test(arguments: [
        (SupervisorProviderError.unavailable, SupervisorFallbackCode.providerUnavailable),
        (SupervisorProviderError.timeout, SupervisorFallbackCode.providerTimeout),
        (SupervisorProviderError.invalidStructuredOutput, SupervisorFallbackCode.invalidStructuredOutput),
        (SupervisorProviderError.cancelled, SupervisorFallbackCode.providerCancelled)
    ])
    func knownProviderFailuresReturnHarnessOnly(
        error: SupervisorProviderError,
        expectedCode: SupervisorFallbackCode
    ) async {
        let input = SupervisorTestSupport.input()
        let provider = StubSupervisorProvider(
            descriptor: SupervisorTestSupport.provider,
            response: .failure(error)
        )

        let result = await CompletionReviewExecutor().execute(
            input: input,
            using: provider,
            now: SupervisorTestSupport.now
        )

        guard case .harnessOnly(let fallback) = result else {
            Issue.record("Expected Harness-only fallback")
            return
        }
        #expect(fallback.code == expectedCode)
        #expect(fallback.policyDecision == nil)
        #expect(fallback.providerFailureReceipt == nil)
    }

    @Test
    func policyRejectedOutputReturnsHarnessOnlyWithoutChangingCanonicalState() async {
        let input = SupervisorTestSupport.input()
        var unsafe = SupervisorTestSupport.assessment(for: input)
        unsafe.proposedActions = [.continueInSourceAgent]
        let provider = StubSupervisorProvider(
            descriptor: SupervisorTestSupport.provider,
            response: .success(unsafe)
        )
        var snapshot = RelaySnapshot()
        snapshot.apply(RelayEvent(
            source: .codex,
            sourceEvent: "Stop",
            sessionID: input.task.sessionID,
            status: .readyToReview,
            summary: "Synthetic result is ready to review",
            occurredAt: SupervisorTestSupport.now,
            receivedAt: SupervisorTestSupport.now
        ))
        let before = snapshot

        let result = await CompletionReviewExecutor().execute(
            input: input,
            using: provider,
            now: SupervisorTestSupport.now
        )

        guard case .harnessOnly(let fallback) = result else {
            Issue.record("Expected policy rejection")
            return
        }
        #expect(fallback.code == .policyRejected)
        #expect(fallback.policyDecision?.disposition == .harnessOnly)
        #expect(snapshot == before)
        #expect(snapshot.sessions.values.first?.status == .readyToReview)
    }

    @Test
    func preflightRejectionPreventsProviderInvocation() async {
        let counter = ProviderInvocationCounter()
        let descriptor = SupervisorModelDescriptor(
            providerID: "remote-provider",
            modelID: "remote-model",
            modelVersion: "1",
            executionLocation: .remote
        )
        let input = SupervisorTestSupport.input(contextMode: .authorizedTask)
        let provider = ProbedSupervisorProvider(
            descriptor: descriptor,
            counter: counter,
            assessment: SupervisorTestSupport.assessment(
                for: input,
                provider: descriptor
            )
        )

        let result = await CompletionReviewExecutor().execute(
            input: input,
            using: provider,
            now: SupervisorTestSupport.now
        )

        guard case .harnessOnly(let fallback) = result else {
            Issue.record("Expected preflight rejection")
            return
        }
        #expect(fallback.code == .policyRejected)
        #expect(fallback.preflightDecision?.disposition == .harnessOnly)
        #expect(fallback.providerFailureReceipt == nil)
        #expect(await counter.current() == 0)
    }

    @Test
    func boundedProviderReceiptFlowsWithTheShadowAssessment() async throws {
        let input = SupervisorTestSupport.input()
        let assessment = SupervisorTestSupport.assessment(for: input)
        let receipt = providerReceipt(for: assessment)
        let provider = ReceiptedSupervisorProvider(
            descriptor: SupervisorTestSupport.provider,
            result: SupervisorProviderResult(assessment: assessment, receipt: receipt)
        )

        let result = await CompletionReviewExecutor().execute(
            input: input,
            using: provider,
            now: SupervisorTestSupport.now
        )

        guard case .shadowAssessment(_, _, _, let returnedReceipt?) = result else {
            Issue.record("Expected a receipted shadow assessment")
            return
        }
        #expect(returnedReceipt == receipt)
    }

    @Test
    func mismatchedProviderReceiptIsRejectedAsInvalidOutput() async {
        let input = SupervisorTestSupport.input()
        let assessment = SupervisorTestSupport.assessment(for: input)
        var receipt = providerReceipt(for: assessment)
        receipt.providerID = "different-provider"
        let provider = ReceiptedSupervisorProvider(
            descriptor: SupervisorTestSupport.provider,
            result: SupervisorProviderResult(assessment: assessment, receipt: receipt)
        )

        let result = await CompletionReviewExecutor().execute(
            input: input,
            using: provider,
            now: SupervisorTestSupport.now
        )

        guard case .harnessOnly(let fallback) = result else {
            Issue.record("Expected invalid receipt fallback")
            return
        }
        #expect(fallback.code == .invalidStructuredOutput)
        #expect(fallback.providerReceipt == nil)
    }

    @Test
    func mismatchedSuccessPromptReceiptIsRejectedAsInvalidOutput() async {
        let input = SupervisorTestSupport.input()
        let assessment = SupervisorTestSupport.assessment(for: input)
        var receipt = providerReceipt(for: assessment)
        receipt.promptVersion = "unexpected-prompt-v1"
        let provider = ReceiptedSupervisorProvider(
            descriptor: SupervisorTestSupport.provider,
            result: SupervisorProviderResult(assessment: assessment, receipt: receipt)
        )

        let result = await CompletionReviewExecutor().execute(
            input: input,
            using: provider,
            now: SupervisorTestSupport.now
        )

        guard case .harnessOnly(let fallback) = result else {
            Issue.record("Expected invalid prompt receipt fallback")
            return
        }
        #expect(fallback.code == .invalidStructuredOutput)
        #expect(fallback.providerReceipt == nil)
    }

    @Test
    func boundedFailureReceiptFlowsOnlyAfterAProviderAttempt() async {
        let input = SupervisorTestSupport.input()
        let receipt = providerFailureReceipt(kind: .timeout)
        let provider = FailureReceiptSupervisorProvider(
            descriptor: SupervisorTestSupport.provider,
            failure: SupervisorProviderFailure(receipt: receipt)
        )

        let result = await CompletionReviewExecutor().execute(
            input: input,
            using: provider,
            now: SupervisorTestSupport.now
        )

        guard case .harnessOnly(let fallback) = result else {
            Issue.record("Expected receipted Harness-only fallback")
            return
        }
        #expect(fallback.code == .providerTimeout)
        #expect(fallback.providerFailureReceipt == receipt)
        #expect(fallback.providerReceipt == nil)
    }

    @Test
    func invalidFailureReceiptIsDiscarded() async {
        let input = SupervisorTestSupport.input()
        var receipt = providerFailureReceipt(kind: .unavailable)
        receipt.promptVersion = "unexpected-prompt-v1"
        let provider = FailureReceiptSupervisorProvider(
            descriptor: SupervisorTestSupport.provider,
            failure: SupervisorProviderFailure(receipt: receipt)
        )

        let result = await CompletionReviewExecutor().execute(
            input: input,
            using: provider,
            now: SupervisorTestSupport.now
        )

        guard case .harnessOnly(let fallback) = result else {
            Issue.record("Expected invalid failure receipt fallback")
            return
        }
        #expect(fallback.code == .invalidStructuredOutput)
        #expect(fallback.providerFailureReceipt == nil)
    }

    private func providerReceipt(
        for assessment: SupervisorAssessment
    ) -> SupervisorProviderReceipt {
        SupervisorProviderReceipt(
            providerID: SupervisorTestSupport.provider.providerID,
            requestedModelID: SupervisorTestSupport.provider.modelID,
            returnedModelID: "fixture-model-2026-08-16",
            promptVersion: "fixture-prompt-v1",
            inputTokenCount: 100,
            outputTokenCount: 50,
            totalTokenCount: 150,
            latencyMilliseconds: 250,
            completedAt: assessment.generatedAt
        )
    }

    private func providerFailureReceipt(
        kind: SupervisorProviderFailureKind
    ) -> SupervisorProviderFailureReceipt {
        SupervisorProviderFailureReceipt(
            providerID: SupervisorTestSupport.provider.providerID,
            requestedModelID: SupervisorTestSupport.provider.modelID,
            promptVersion: "fixture-prompt-v1",
            failureKind: kind,
            latencyMilliseconds: 800,
            attemptedAt: SupervisorTestSupport.now
        )
    }
}

private struct StubSupervisorProvider: SupervisorModelProvider {
    var descriptor: SupervisorModelDescriptor
    var promptVersion = "fixture-prompt-v1"
    var response: Result<SupervisorAssessment, SupervisorProviderError>

    func assessCompletion(
        _ input: CompletionReviewInput
    ) async throws -> SupervisorAssessment {
        try response.get()
    }
}

private struct ReceiptedSupervisorProvider: SupervisorModelProvider {
    var descriptor: SupervisorModelDescriptor
    var promptVersion = "fixture-prompt-v1"
    var result: SupervisorProviderResult

    func assessCompletion(
        _ input: CompletionReviewInput
    ) async throws -> SupervisorAssessment {
        result.assessment
    }

    func assessCompletionWithReceipt(
        _ input: CompletionReviewInput
    ) async throws -> SupervisorProviderResult {
        result
    }
}

private struct FailureReceiptSupervisorProvider: SupervisorModelProvider {
    var descriptor: SupervisorModelDescriptor
    var promptVersion = "fixture-prompt-v1"
    var failure: SupervisorProviderFailure

    func assessCompletion(
        _ input: CompletionReviewInput
    ) async throws -> SupervisorAssessment {
        throw failure
    }
}

private actor ProviderInvocationCounter {
    private var count = 0

    func record() {
        count += 1
    }

    func current() -> Int {
        count
    }
}

private struct ProbedSupervisorProvider: SupervisorModelProvider {
    var descriptor: SupervisorModelDescriptor
    var promptVersion = "fixture-prompt-v1"
    var counter: ProviderInvocationCounter
    var assessment: SupervisorAssessment

    func assessCompletion(
        _ input: CompletionReviewInput
    ) async throws -> SupervisorAssessment {
        await counter.record()
        return assessment
    }
}
