import Foundation
import Testing
@testable import RelayCore

@Suite("Independent Completion Review evaluator")
struct IndependentCompletionReviewEvaluatorTests {
    @Test
    func requestContainsBoundedAssessmentButExcludesEvidenceReferences() throws {
        let evaluator = evaluatorDescriptor()
        var input = authorizedInput(evaluator: evaluator)
        input.evidence[0].reference = "artifact-sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        let assessment = SupervisorTestSupport.assessment(
            for: input,
            provider: supervisorDescriptor(),
            recommendation: .missingEvidence,
            uncertainty: .medium,
            missingEvidence: true,
            proposedActions: [.requestEvidence]
        )

        let data = try OpenAIIndependentCompletionReviewEvaluator.makeRequestBody(
            input: input,
            assessment: assessment,
            modelID: evaluator.modelID,
            systemPrompt: SupervisorTestSupport.syntheticSystemPrompt
        )
        let text = String(decoding: data, as: UTF8.self)

        #expect(text.contains("notch_relay_independent_completion_evaluation"))
        #expect(text.contains(assessment.id.uuidString))
        #expect(text.contains("A required synthetic check is missing"))
        #expect(!text.contains("artifact-sha256"))
        #expect(!text.contains("reference"))
        #expect(OpenAIIndependentCompletionReviewEvaluator.promptVersion
            == "openai-independent-completion-evaluator-prompt-v2")
    }

    @Test
    func structuredOutputUsesTrustedIdentityAndValidReceipt() async throws {
        let evaluator = evaluatorDescriptor()
        let input = authorizedInput(evaluator: evaluator)
        let assessment = SupervisorTestSupport.assessment(
            for: input,
            provider: supervisorDescriptor(),
            recommendation: .missingEvidence,
            uncertainty: .medium,
            missingEvidence: true,
            proposedActions: [.requestEvidence]
        )
        let content: [String: Any] = [
            "verdict": "supports_assessment",
            "scores": [
                "groundedness": 0.95,
                "criterionCoverage": 0.9,
                "riskCalibration": 0.85
            ],
            "findings": [[
                "code": "assessment_consistent",
                "detail": "The assessment preserves the documented evidence gap.",
                "evidenceIDs": [input.evidence[0].id.uuidString],
                "acceptanceCriterionIDs": [input.goal.acceptanceCriteria[0].id]
            ]]
        ]
        let contentData = try JSONSerialization.data(withJSONObject: content, options: [.sortedKeys])
        let envelope: [String: Any] = [
            "model": "evaluator-model-returned",
            "choices": [["message": ["content": String(decoding: contentData, as: UTF8.self)]]],
            "usage": ["prompt_tokens": 100, "completion_tokens": 40, "total_tokens": 140]
        ]
        let responseData = try JSONSerialization.data(withJSONObject: envelope)
        let providerResult = try OpenAIIndependentCompletionReviewEvaluator.decodeProviderResult(
            from: responseData,
            input: input,
            assessment: assessment,
            descriptor: evaluator,
            latencyMilliseconds: 320,
            now: SupervisorTestSupport.now
        )
        let provider = IndependentFixtureProvider(
            descriptor: evaluator,
            result: .success(providerResult)
        )

        let stored = await IndependentCompletionReviewEvaluatorExecutor().execute(
            input: input,
            assessment: assessment,
            using: provider,
            now: SupervisorTestSupport.now
        )

        #expect(stored.fallbackCode == nil)
        #expect(stored.result?.traceID == input.traceID)
        #expect(stored.result?.assessmentID == assessment.id)
        #expect(stored.result?.model == evaluator)
        #expect(stored.result?.scores.groundedness == 0.95)
        #expect(stored.providerReceipt?.returnedModelID == "evaluator-model-returned")
        #expect(stored.providerReceipt?.promptVersion
            == OpenAIIndependentCompletionReviewEvaluator.promptVersion)
    }

    @Test
    func evaluatorMustUseADifferentModelFromSupervisor() async {
        let supervisor = supervisorDescriptor()
        let input = authorizedInput(evaluator: supervisor)
        let assessment = SupervisorTestSupport.assessment(for: input, provider: supervisor)
        let provider = IndependentFixtureProvider(
            descriptor: supervisor,
            result: .failure(.unavailable)
        )

        let stored = await IndependentCompletionReviewEvaluatorExecutor().execute(
            input: input,
            assessment: assessment,
            using: provider,
            now: SupervisorTestSupport.now
        )

        #expect(stored.result == nil)
        #expect(stored.fallbackCode == .nonIndependentModel)
        #expect(stored.providerFailureReceipt == nil)
    }

    @Test
    func evaluatorFailureIsBoundedAndDoesNotChangeTheAssessment() async {
        let evaluator = evaluatorDescriptor()
        let input = authorizedInput(evaluator: evaluator)
        let assessment = SupervisorTestSupport.assessment(
            for: input,
            provider: supervisorDescriptor(),
            recommendation: .missingEvidence
        )
        let provider = IndependentFixtureProvider(
            descriptor: evaluator,
            result: .failure(.timeout)
        )

        let stored = await IndependentCompletionReviewEvaluatorExecutor().execute(
            input: input,
            assessment: assessment,
            using: provider,
            now: SupervisorTestSupport.now
        )

        #expect(stored.result == nil)
        #expect(stored.fallbackCode == .providerTimeout)
        #expect(stored.providerFailureReceipt == nil)
        #expect(assessment.recommendation == .missingEvidence)
    }

    @Test
    func evaluatorFailureReceiptIsValidatedAndStored() async {
        let evaluator = evaluatorDescriptor()
        let input = authorizedInput(evaluator: evaluator)
        let assessment = SupervisorTestSupport.assessment(
            for: input,
            provider: supervisorDescriptor(),
            recommendation: .missingEvidence
        )
        let receipt = failureReceipt(for: evaluator, kind: .timeout)

        let stored = await IndependentCompletionReviewEvaluatorExecutor().execute(
            input: input,
            assessment: assessment,
            using: IndependentFailureReceiptProvider(
                descriptor: evaluator,
                failure: SupervisorProviderFailure(receipt: receipt)
            ),
            now: SupervisorTestSupport.now
        )

        #expect(stored.result == nil)
        #expect(stored.fallbackCode == .providerTimeout)
        #expect(stored.providerFailureReceipt == receipt)
    }

    @Test
    func invalidEvaluatorFailureReceiptIsDiscarded() async {
        let evaluator = evaluatorDescriptor()
        let input = authorizedInput(evaluator: evaluator)
        let assessment = SupervisorTestSupport.assessment(
            for: input,
            provider: supervisorDescriptor(),
            recommendation: .missingEvidence
        )
        var receipt = failureReceipt(for: evaluator, kind: .unavailable)
        receipt.requestedModelID = "different-model"

        let stored = await IndependentCompletionReviewEvaluatorExecutor().execute(
            input: input,
            assessment: assessment,
            using: IndependentFailureReceiptProvider(
                descriptor: evaluator,
                failure: SupervisorProviderFailure(receipt: receipt)
            ),
            now: SupervisorTestSupport.now
        )

        #expect(stored.result == nil)
        #expect(stored.fallbackCode == .invalidStructuredOutput)
        #expect(stored.providerFailureReceipt == nil)
    }

    @Test
    func rejectingAIAssessmentDoesNotChangeDeterministicPolicyDecision() async {
        let evaluator = evaluatorDescriptor()
        var input = SupervisorTestSupport.input()
        input.consent?.independentEvaluatorProvider = evaluator
        let assessment = SupervisorTestSupport.assessment(for: input)
        let deterministicResult = await DeterministicCompletionReviewEvaluator().evaluate(
            input: input,
            assessment: assessment,
            now: SupervisorTestSupport.now
        )
        let policy = CompletionReviewPolicy()
        let decisionBefore = policy.evaluate(
            input: input,
            assessment: assessment,
            provider: SupervisorTestSupport.provider,
            evaluatorResult: deterministicResult,
            now: SupervisorTestSupport.now
        )
        let rejectingResult = validProviderResult(
            input: input,
            assessment: assessment,
            evaluator: evaluator,
            verdict: .rejectsAssessment
        )
        let stored = await IndependentCompletionReviewEvaluatorExecutor().execute(
            input: input,
            assessment: assessment,
            using: IndependentFixtureProvider(
                descriptor: evaluator,
                result: .success(rejectingResult)
            ),
            now: SupervisorTestSupport.now
        )
        let decisionAfter = policy.evaluate(
            input: input,
            assessment: assessment,
            provider: SupervisorTestSupport.provider,
            evaluatorResult: deterministicResult,
            now: SupervisorTestSupport.now
        )

        #expect(stored.result?.verdict == .rejectsAssessment)
        #expect(decisionBefore.disposition == .allowShadowAssessment)
        #expect(decisionAfter == decisionBefore)
    }

    @Test
    func missingReceiptIsRejected() async {
        let evaluator = evaluatorDescriptor()
        let input = authorizedInput(evaluator: evaluator)
        let assessment = SupervisorTestSupport.assessment(for: input, provider: supervisorDescriptor())
        var providerResult = validProviderResult(
            input: input,
            assessment: assessment,
            evaluator: evaluator
        )
        providerResult.receipt = nil

        let stored = await execute(
            providerResult,
            input: input,
            assessment: assessment,
            evaluator: evaluator
        )

        #expect(stored.result == nil)
        #expect(stored.fallbackCode == .invalidStructuredOutput)
    }

    @Test
    func wrongPromptReceiptIsRejected() async {
        let evaluator = evaluatorDescriptor()
        let input = authorizedInput(evaluator: evaluator)
        let assessment = SupervisorTestSupport.assessment(for: input, provider: supervisorDescriptor())
        var providerResult = validProviderResult(
            input: input,
            assessment: assessment,
            evaluator: evaluator
        )
        providerResult.receipt?.promptVersion = "unexpected-evaluator-prompt"

        let stored = await execute(
            providerResult,
            input: input,
            assessment: assessment,
            evaluator: evaluator
        )

        #expect(stored.result == nil)
        #expect(stored.fallbackCode == .invalidStructuredOutput)
    }

    @Test
    func outOfBoundsScoresAreRejected() async {
        let evaluator = evaluatorDescriptor()
        let input = authorizedInput(evaluator: evaluator)
        let assessment = SupervisorTestSupport.assessment(for: input, provider: supervisorDescriptor())
        var providerResult = validProviderResult(
            input: input,
            assessment: assessment,
            evaluator: evaluator
        )
        providerResult.evaluation.scores.groundedness = 1.01

        let stored = await execute(
            providerResult,
            input: input,
            assessment: assessment,
            evaluator: evaluator
        )

        #expect(stored.result == nil)
        #expect(stored.fallbackCode == .invalidStructuredOutput)
    }

    @Test
    func unknownEvidenceAndCriterionReferencesAreRejected() async {
        let evaluator = evaluatorDescriptor()
        let input = authorizedInput(evaluator: evaluator)
        let assessment = SupervisorTestSupport.assessment(for: input, provider: supervisorDescriptor())
        var providerResult = validProviderResult(
            input: input,
            assessment: assessment,
            evaluator: evaluator
        )
        providerResult.evaluation.findings[0].evidenceIDs = [UUID()]
        providerResult.evaluation.findings[0].acceptanceCriterionIDs = ["unknown-criterion"]

        let stored = await execute(
            providerResult,
            input: input,
            assessment: assessment,
            evaluator: evaluator
        )

        #expect(stored.result == nil)
        #expect(stored.fallbackCode == .invalidStructuredOutput)
    }

    @Test
    func sensitiveEvaluatorFindingIsRejected() async {
        let evaluator = evaluatorDescriptor()
        let input = authorizedInput(evaluator: evaluator)
        let assessment = SupervisorTestSupport.assessment(for: input, provider: supervisorDescriptor())
        var providerResult = validProviderResult(
            input: input,
            assessment: assessment,
            evaluator: evaluator
        )
        providerResult.evaluation.findings[0].detail = "api_key=secretvalue"

        let stored = await execute(
            providerResult,
            input: input,
            assessment: assessment,
            evaluator: evaluator
        )

        #expect(stored.result == nil)
        #expect(stored.fallbackCode == .invalidStructuredOutput)
    }

    @Test
    func runtimeStoreRoundTripsAndDeletesIndependentResult() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("independent-evaluator-store-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let evaluator = evaluatorDescriptor()
        let input = authorizedInput(evaluator: evaluator)
        let assessment = SupervisorTestSupport.assessment(for: input, provider: supervisorDescriptor())
        let result = IndependentCompletionReviewEvaluatorResult(
            traceID: input.traceID,
            task: input.task,
            assessmentID: assessment.id,
            model: evaluator,
            verdict: .humanReviewRequired,
            scores: IndependentCompletionReviewScores(
                groundedness: 0.8,
                criterionCoverage: 0.7,
                riskCalibration: 0.9
            ),
            findings: [IndependentCompletionReviewFinding(
                code: .missedEvidenceGap,
                detail: "Human review remains appropriate."
            )],
            evaluatedAt: SupervisorTestSupport.now,
            expiresAt: assessment.expiresAt
        )
        let sessionKey = "\(input.task.source.rawValue):\(input.task.sessionID)"
        let store = CompletionReviewRuntimeStore(root: root)
        let snapshot = CompletionReviewRuntimeSnapshot(reviews: [
            sessionKey: StoredCompletionReview(
                input: input,
                assessment: assessment,
                independentEvaluator: StoredIndependentCompletionReviewEvaluation(
                    result: result,
                    recordedAt: SupervisorTestSupport.now
                )
            )
        ])

        try store.persist(snapshot)
        let loaded = try store.load()
        #expect(loaded.schemaVersion == CompletionReviewRuntimeSnapshot.currentSchemaVersion)
        #expect(loaded.reviews[sessionKey]?.independentEvaluator?.result == result)

        try store.deleteTask(sessionKey)
        #expect(try store.load().reviews[sessionKey] == nil)
    }

    @Test
    func runtimeStoreRoundTripsAndDeletesIndependentFailureReceipt() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("independent-evaluator-failure-store-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let evaluator = evaluatorDescriptor()
        let input = authorizedInput(evaluator: evaluator)
        let assessment = SupervisorTestSupport.assessment(for: input, provider: supervisorDescriptor())
        let receipt = failureReceipt(for: evaluator, kind: .unavailable)
        let sessionKey = "\(input.task.source.rawValue):\(input.task.sessionID)"
        let store = CompletionReviewRuntimeStore(root: root)
        let snapshot = CompletionReviewRuntimeSnapshot(reviews: [
            sessionKey: StoredCompletionReview(
                input: input,
                assessment: assessment,
                independentEvaluator: StoredIndependentCompletionReviewEvaluation(
                    providerFailureReceipt: receipt,
                    fallbackCode: .providerUnavailable,
                    recordedAt: SupervisorTestSupport.now
                ),
                recordedAt: SupervisorTestSupport.now
            )
        ])

        try store.persist(snapshot)
        #expect(try store.load() == snapshot)
        try store.deleteTask(sessionKey)
        #expect(try store.load().reviews[sessionKey] == nil)
    }

    private func authorizedInput(
        evaluator: SupervisorModelDescriptor
    ) -> CompletionReviewInput {
        var input = SupervisorTestSupport.input()
        input.contextMode = .authorizedTask
        input.policyVersion = CompletionReviewPolicy.liveShadowVersion
        input.consent?.provider = supervisorDescriptor()
        input.consent?.independentEvaluatorProvider = evaluator
        input.consent?.confirmedAt = SupervisorTestSupport.now
        return input
    }

    private func supervisorDescriptor() -> SupervisorModelDescriptor {
        OpenAICompletionReviewProvider.modelDescriptor(modelID: "supervisor-model")
    }

    private func evaluatorDescriptor() -> SupervisorModelDescriptor {
        OpenAIIndependentCompletionReviewEvaluator.modelDescriptor(modelID: "evaluator-model")
    }

    private func execute(
        _ providerResult: IndependentCompletionReviewProviderResult,
        input: CompletionReviewInput,
        assessment: SupervisorAssessment,
        evaluator: SupervisorModelDescriptor
    ) async -> StoredIndependentCompletionReviewEvaluation {
        await IndependentCompletionReviewEvaluatorExecutor().execute(
            input: input,
            assessment: assessment,
            using: IndependentFixtureProvider(
                descriptor: evaluator,
                result: .success(providerResult)
            ),
            now: SupervisorTestSupport.now
        )
    }

    private func validProviderResult(
        input: CompletionReviewInput,
        assessment: SupervisorAssessment,
        evaluator: SupervisorModelDescriptor,
        verdict: CompletionReviewEvaluatorVerdict = .supportsAssessment
    ) -> IndependentCompletionReviewProviderResult {
        IndependentCompletionReviewProviderResult(
            evaluation: IndependentCompletionReviewEvaluatorResult(
                traceID: input.traceID,
                task: input.task,
                assessmentID: assessment.id,
                model: evaluator,
                verdict: verdict,
                scores: IndependentCompletionReviewScores(
                    groundedness: 0.9,
                    criterionCoverage: 0.9,
                    riskCalibration: 0.9
                ),
                findings: [IndependentCompletionReviewFinding(
                    code: verdict == .supportsAssessment ? .assessmentConsistent : .unsupportedFact,
                    detail: verdict == .supportsAssessment
                        ? "The assessment is supported by bounded evidence."
                        : "The assessment is not supported by bounded evidence.",
                    evidenceIDs: [input.evidence[0].id],
                    acceptanceCriterionIDs: [input.goal.acceptanceCriteria[0].id]
                )],
                evaluatedAt: SupervisorTestSupport.now,
                expiresAt: assessment.expiresAt
            ),
            receipt: SupervisorProviderReceipt(
                providerID: evaluator.providerID,
                requestedModelID: evaluator.modelID,
                returnedModelID: evaluator.modelID,
                promptVersion: OpenAIIndependentCompletionReviewEvaluator.promptVersion,
                inputTokenCount: 100,
                outputTokenCount: 40,
                totalTokenCount: 140,
                latencyMilliseconds: 300,
                completedAt: SupervisorTestSupport.now
            )
        )
    }

    private func failureReceipt(
        for evaluator: SupervisorModelDescriptor,
        kind: SupervisorProviderFailureKind
    ) -> SupervisorProviderFailureReceipt {
        SupervisorProviderFailureReceipt(
            providerID: evaluator.providerID,
            requestedModelID: evaluator.modelID,
            promptVersion: OpenAIIndependentCompletionReviewEvaluator.promptVersion,
            failureKind: kind,
            latencyMilliseconds: 900,
            attemptedAt: SupervisorTestSupport.now
        )
    }
}

private struct IndependentFixtureProvider: IndependentCompletionReviewEvaluatorProvider {
    var descriptor: SupervisorModelDescriptor
    var promptVersion = OpenAIIndependentCompletionReviewEvaluator.promptVersion
    var result: Result<IndependentCompletionReviewProviderResult, SupervisorProviderError>

    func evaluate(
        input: CompletionReviewInput,
        assessment: SupervisorAssessment
    ) async throws -> IndependentCompletionReviewProviderResult {
        try result.get()
    }
}

private struct IndependentFailureReceiptProvider: IndependentCompletionReviewEvaluatorProvider {
    var descriptor: SupervisorModelDescriptor
    var promptVersion = OpenAIIndependentCompletionReviewEvaluator.promptVersion
    var failure: SupervisorProviderFailure

    func evaluate(
        input: CompletionReviewInput,
        assessment: SupervisorAssessment
    ) async throws -> IndependentCompletionReviewProviderResult {
        throw failure
    }
}
