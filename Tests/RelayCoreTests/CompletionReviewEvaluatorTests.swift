import Foundation
import Testing
@testable import RelayCore

@Suite("Completion Review deterministic evaluator")
struct CompletionReviewEvaluatorTests {
    @Test
    func completeIndependentEvidenceSupportsVerifiedReady() async {
        let input = SupervisorTestSupport.input()
        let assessment = SupervisorTestSupport.assessment(for: input)

        let result = await DeterministicCompletionReviewEvaluator().evaluate(
            input: input,
            assessment: assessment,
            now: SupervisorTestSupport.now
        )

        #expect(result.verdict == .supportsAssessment)
        #expect(result.findings.map(\.code) == [.assessmentConsistent])
        #expect(result.assessmentID == assessment.id)
        #expect(result.task == input.task)
        #expect(result.traceID == input.traceID)
    }

    @Test(arguments: [EvidenceSourceKind.provider, .human])
    func providerOrHumanEvidenceCannotIndependentlyVerifyCompletion(
        sourceKind: EvidenceSourceKind
    ) async {
        var evidence = SupervisorTestSupport.evidence()
        evidence.source = EvidenceSource(kind: sourceKind, sourceID: "bounded-source")
        let input = SupervisorTestSupport.input(evidence: [evidence])
        let assessment = SupervisorTestSupport.assessment(for: input)

        let result = await DeterministicCompletionReviewEvaluator().evaluate(
            input: input,
            assessment: assessment,
            now: SupervisorTestSupport.now
        )

        #expect(result.verdict == .rejectsAssessment)
        #expect(result.findings.contains { $0.code == .missingIndependentEvidence })
        #expect(result.findings.contains { $0.code == .incompleteCriterionCoverage })
    }

    @Test
    func everyCriterionNeedsIndependentEvidenceCoverage() async {
        let evidence = SupervisorTestSupport.evidence()
        var input = SupervisorTestSupport.input(evidence: [evidence])
        input.goal.acceptanceCriteria.append(
            AcceptanceCriterion(id: "criterion-2", statement: "A second independent check passes")
        )
        let assessment = SupervisorTestSupport.assessment(for: input)
        var partialCoverage = assessment
        partialCoverage.observedFacts[0].acceptanceCriterionIDs = ["criterion-1"]

        let result = await DeterministicCompletionReviewEvaluator().evaluate(
            input: input,
            assessment: partialCoverage,
            now: SupervisorTestSupport.now
        )

        #expect(result.verdict == .rejectsAssessment)
        #expect(result.findings.contains {
            $0.code == .incompleteCriterionCoverage
                && $0.acceptanceCriterionIDs == ["criterion-2"]
        })
    }

    @Test
    func liveVerifiedReadyRequiresEvaluatorResult() {
        let (input, provider) = liveInput()
        let assessment = SupervisorTestSupport.assessment(for: input, provider: provider)

        let decision = CompletionReviewPolicy
            .liveShadow(approvedProviderIDs: [provider.providerID])
            .evaluate(
                input: input,
                assessment: assessment,
                provider: provider,
                evaluatorResult: nil,
                now: SupervisorTestSupport.now
            )

        #expect(decision.disposition == .harnessOnly)
        #expect(decision.violations.contains { $0.code == .evaluatorRejected })
    }

    @Test
    func evaluatorIdentityAndLifetimeMustMatchExactly() async {
        let (input, provider) = liveInput()
        let assessment = SupervisorTestSupport.assessment(for: input, provider: provider)
        let valid = await DeterministicCompletionReviewEvaluator().evaluate(
            input: input,
            assessment: assessment,
            now: SupervisorTestSupport.now
        )
        let policy = CompletionReviewPolicy.liveShadow(approvedProviderIDs: [provider.providerID])

        var mismatches: [CompletionReviewEvaluatorResult] = []
        var wrongTrace = valid
        wrongTrace.traceID = SupervisorTraceID()
        mismatches.append(wrongTrace)
        var wrongTask = valid
        wrongTask.task.sessionID = "different-session"
        mismatches.append(wrongTask)
        var wrongAssessment = valid
        wrongAssessment.assessmentID = UUID()
        mismatches.append(wrongAssessment)
        var expired = valid
        expired.expiresAt = SupervisorTestSupport.now
        mismatches.append(expired)

        for mismatch in mismatches {
            let decision = policy.evaluate(
                input: input,
                assessment: assessment,
                provider: provider,
                evaluatorResult: mismatch,
                now: SupervisorTestSupport.now
            )
            #expect(decision.disposition == .harnessOnly)
            #expect(decision.violations.contains { $0.code == .evaluatorRejected })
        }
    }

    @Test
    func nonVerifiedRecommendationCanPassConsistentEvaluation() async {
        let input = SupervisorTestSupport.input()
        let assessment = SupervisorTestSupport.assessment(
            for: input,
            recommendation: .missingEvidence,
            uncertainty: .medium,
            missingEvidence: true,
            proposedActions: [.requestEvidence]
        )
        let evaluatorResult = await DeterministicCompletionReviewEvaluator().evaluate(
            input: input,
            assessment: assessment,
            now: SupervisorTestSupport.now
        )
        let decision = CompletionReviewPolicy().evaluate(
            input: input,
            assessment: assessment,
            provider: SupervisorTestSupport.provider,
            evaluatorResult: evaluatorResult,
            now: SupervisorTestSupport.now
        )

        #expect(evaluatorResult.verdict == .supportsAssessment)
        #expect(decision.disposition == .allowShadowAssessment)
    }

    @Test
    func executorReturnsAndPersistsEvaluatorResult() async throws {
        let input = SupervisorTestSupport.input()
        let assessment = SupervisorTestSupport.assessment(for: input)
        let provider = EvaluatorTestProvider(
            descriptor: SupervisorTestSupport.provider,
            assessment: assessment
        )

        let execution = await CompletionReviewExecutor().execute(
            input: input,
            using: provider,
            evaluator: DeterministicCompletionReviewEvaluator(),
            now: SupervisorTestSupport.now
        )
        guard case .shadowAssessment(
            let returnedAssessment,
            let evaluatorResult?,
            let policyDecision,
            _
        ) = execution else {
            Issue.record("Expected an evaluated shadow assessment")
            return
        }

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("notch-relay-evaluator-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = CompletionReviewRuntimeStore(root: root)
        let snapshot = CompletionReviewRuntimeSnapshot(reviews: [
            "codex:synthetic-session": StoredCompletionReview(
                input: input,
                assessment: returnedAssessment,
                evaluatorResult: evaluatorResult,
                policyDecision: policyDecision,
                recordedAt: SupervisorTestSupport.now
            )
        ])

        try store.persist(snapshot)
        let loaded = try store.load()
        #expect(loaded == snapshot)
        #expect(loaded.reviews.values.first?.evaluatorResult == evaluatorResult)
    }

    @Test
    func legacyRuntimeWithoutEvaluatorFieldStillDecodes() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("notch-relay-evaluator-legacy-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = CompletionReviewRuntimeStore(root: root)
        let input = SupervisorTestSupport.input()
        let snapshot = CompletionReviewRuntimeSnapshot(reviews: [
            "codex:synthetic-session": StoredCompletionReview(
                input: input,
                assessment: SupervisorTestSupport.assessment(for: input),
                recordedAt: SupervisorTestSupport.now
            )
        ])

        try store.persist(snapshot)
        let encoded = try Data(contentsOf: store.fileURL)
        #expect(!String(decoding: encoded, as: UTF8.self).contains("evaluatorResult"))
        #expect(try store.load() == snapshot)
    }

    private func liveInput() -> (CompletionReviewInput, SupervisorModelDescriptor) {
        let provider = SupervisorModelDescriptor(
            providerID: "openai",
            modelID: "test-model",
            modelVersion: "api",
            executionLocation: .remote
        )
        var evidence = SupervisorTestSupport.evidence()
        evidence.consentScope = EvidenceConsentScope(
            purposes: [.completionReview],
            maximumDataLevel: .l1StructuredEvidence,
            allowedModelLocations: [.remote],
            approvedRemoteProviderIDs: [provider.providerID]
        )
        let createdAt = SupervisorTestSupport.now.addingTimeInterval(-60)
        let input = CompletionReviewInput(
            traceID: SupervisorTestSupport.traceID,
            task: SupervisorTestSupport.task,
            goal: SupervisorTaskGoal(
                statement: "Complete the authorized task safely.",
                acceptanceCriteria: [
                    AcceptanceCriterion(id: "criterion-1", statement: "Checks pass")
                ]
            ),
            evidence: [evidence],
            allowedActions: SupervisorCandidateAction.allCases,
            contextMode: .authorizedTask,
            contextDataLevel: .l1StructuredEvidence,
            contextVersion: "live-context-v1",
            policyVersion: CompletionReviewPolicy.liveShadowVersion,
            consent: CompletionReviewConsent(
                provider: provider,
                maximumDataLevel: .l1StructuredEvidence,
                preparedAt: createdAt,
                confirmedAt: SupervisorTestSupport.now.addingTimeInterval(-30)
            ),
            createdAt: createdAt,
            expiresAt: SupervisorTestSupport.now.addingTimeInterval(600)
        )
        return (input, provider)
    }
}

private struct EvaluatorTestProvider: SupervisorModelProvider {
    var descriptor: SupervisorModelDescriptor
    var promptVersion = "evaluator-test-prompt-v1"
    var assessment: SupervisorAssessment

    func assessCompletion(_ input: CompletionReviewInput) async throws -> SupervisorAssessment {
        assessment
    }
}
