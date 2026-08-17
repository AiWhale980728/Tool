import Foundation
import Testing
@testable import RelayCore

@Suite("Completion Review policy")
struct CompletionReviewPolicyTests {
    @Test
    func completeGroundedAssessmentMayEnterShadowMode() {
        let input = SupervisorTestSupport.input()
        let assessment = SupervisorTestSupport.assessment(for: input)
        let decision = CompletionReviewPolicy().evaluate(
            input: input,
            assessment: assessment,
            provider: SupervisorTestSupport.provider,
            now: SupervisorTestSupport.now
        )

        #expect(decision.disposition == .allowShadowAssessment)
        #expect(decision.violations.isEmpty)
    }

    @Test
    func verifiedReadyCannotUseIncompleteEvidenceOrHighUncertainty() {
        let partial = SupervisorTestSupport.evidence(integrity: .partial)
        let input = SupervisorTestSupport.input(evidence: [partial])
        let assessment = SupervisorTestSupport.assessment(
            for: input,
            uncertainty: .high
        )
        let decision = CompletionReviewPolicy().evaluate(
            input: input,
            assessment: assessment,
            provider: SupervisorTestSupport.provider,
            now: SupervisorTestSupport.now
        )

        #expect(decision.disposition == .harnessOnly)
        #expect(decision.violations.contains { $0.code == .unsafeVerifiedReady })
    }

    @Test
    func verifiedReadyMustCoverEveryAcceptanceCriterion() {
        var input = SupervisorTestSupport.input()
        input.goal.acceptanceCriteria.append(
            AcceptanceCriterion(id: "criterion-2", statement: "A second synthetic check passes")
        )
        var assessment = SupervisorTestSupport.assessment(for: input)
        assessment.observedFacts[0].acceptanceCriterionIDs = ["criterion-1"]

        let decision = CompletionReviewPolicy().evaluate(
            input: input,
            assessment: assessment,
            provider: SupervisorTestSupport.provider,
            now: SupervisorTestSupport.now
        )

        #expect(decision.disposition == .harnessOnly)
        #expect(decision.violations.contains { $0.code == .unsafeVerifiedReady })
    }

    @Test
    func highRiskOrNonInvalidatingAssessmentsCannotPassAsVerifiedReady() {
        let input = SupervisorTestSupport.input()
        var assessment = SupervisorTestSupport.assessment(for: input)
        assessment.risk.level = .high
        assessment.invalidatesOnNewerTaskEvent = false

        let decision = CompletionReviewPolicy().evaluate(
            input: input,
            assessment: assessment,
            provider: SupervisorTestSupport.provider,
            now: SupervisorTestSupport.now
        )

        #expect(decision.disposition == .harnessOnly)
        #expect(decision.violations.contains { $0.code == .unsafeVerifiedReady })
        #expect(decision.violations.contains { $0.code == .invalidContract })
    }

    @Test
    func evidenceAndFactReferencesCannotCrossTaskOrEvidenceIdentity() {
        var otherTask = SupervisorTestSupport.task
        otherTask.taskID = "other-task"
        let wrongEvidence = SupervisorTestSupport.evidence(task: otherTask)
        let input = SupervisorTestSupport.input(evidence: [wrongEvidence])
        var assessment = SupervisorTestSupport.assessment(
            for: input,
            recommendation: .humanReviewRequired,
            uncertainty: .high,
            proposedActions: [.requestHumanReview]
        )
        assessment.observedFacts[0].evidenceIDs = [UUID()]

        let decision = CompletionReviewPolicy().evaluate(
            input: input,
            assessment: assessment,
            provider: SupervisorTestSupport.provider,
            now: SupervisorTestSupport.now
        )

        #expect(decision.disposition == .harnessOnly)
        #expect(decision.violations.contains { $0.code == .evidenceNotAuthorized })
        #expect(decision.violations.contains { $0.code == .evidenceNotGrounded })
    }

    @Test
    func modelCannotProposeAnActionOutsidePolicyAndInputAllowlists() {
        let input = SupervisorTestSupport.input(
            allowedActions: [.requestEvidence, .openSourceAgent]
        )
        let assessment = SupervisorTestSupport.assessment(
            for: input,
            recommendation: .missingEvidence,
            uncertainty: .medium,
            missingEvidence: true,
            proposedActions: [.presentCompletionConfirmation]
        )
        let decision = CompletionReviewPolicy().evaluate(
            input: input,
            assessment: assessment,
            provider: SupervisorTestSupport.provider,
            now: SupervisorTestSupport.now
        )

        #expect(decision.disposition == .harnessOnly)
        #expect(decision.violations.contains { $0.code == .unsupportedAction })
    }

    @Test
    func phaseOneRejectsRealTaskContextsAndSelectedContent() {
        let input = SupervisorTestSupport.input(
            contextMode: .authorizedTask,
            contextDataLevel: .l2SelectedContent
        )
        let assessment = SupervisorTestSupport.assessment(for: input)
        let decision = CompletionReviewPolicy().evaluate(
            input: input,
            assessment: assessment,
            provider: SupervisorTestSupport.provider,
            now: SupervisorTestSupport.now
        )

        #expect(decision.disposition == .harnessOnly)
        #expect(decision.violations.contains { $0.code == .phaseBoundary })
    }

    @Test
    func preflightRejectsRemoteProvidersAndUnderstatedEvidenceClassification() {
        let levelTwoEvidence = SupervisorTestSupport.evidence(
            dataLevel: .l2SelectedContent
        )
        let input = SupervisorTestSupport.input(
            evidence: [levelTwoEvidence],
            contextDataLevel: .l0RuntimeMetadata
        )
        let remoteProvider = SupervisorModelDescriptor(
            providerID: "remote-provider",
            modelID: "remote-model",
            modelVersion: "1",
            executionLocation: .remote
        )
        let decision = CompletionReviewPolicy().preflight(
            input: input,
            provider: remoteProvider,
            now: SupervisorTestSupport.now
        )

        #expect(decision.disposition == .harnessOnly)
        #expect(decision.violations.contains { $0.code == .phaseBoundary })
        #expect(decision.violations.contains { $0.code == .invalidContract })
        #expect(decision.violations.contains { $0.code == .evidenceNotAuthorized })
    }

    @Test
    func traceTaskAndProviderMustMatchExactly() {
        let input = SupervisorTestSupport.input()
        var assessment = SupervisorTestSupport.assessment(for: input)
        assessment.traceID = SupervisorTraceID()
        assessment.task.sessionID = "other-session"
        assessment.model.modelID = "other-model"

        let decision = CompletionReviewPolicy().evaluate(
            input: input,
            assessment: assessment,
            provider: SupervisorTestSupport.provider,
            now: SupervisorTestSupport.now
        )

        #expect(decision.disposition == .harnessOnly)
        #expect(decision.violations.contains { $0.code == .traceMismatch })
        #expect(decision.violations.contains { $0.code == .identityMismatch })
        #expect(decision.violations.contains { $0.code == .providerMismatch })
    }
}
