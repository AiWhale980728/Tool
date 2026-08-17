import Foundation
import Testing
@testable import RelayCore

@Suite("Supervisor contracts")
struct SupervisorContractTests {
    @Test
    func completionReviewContractsRoundTripWithStableVersions() throws {
        let input = SupervisorTestSupport.input()
        let assessment = SupervisorTestSupport.assessment(for: input)
        let encoder = RelayJSON.makeEncoder()
        let decoder = RelayJSON.makeDecoder()

        let decodedInput = try decoder.decode(
            CompletionReviewInput.self,
            from: encoder.encode(input)
        )
        let decodedAssessment = try decoder.decode(
            SupervisorAssessment.self,
            from: encoder.encode(assessment)
        )

        #expect(decodedInput == input)
        #expect(decodedAssessment == assessment)
        #expect(decodedInput.schemaVersion == CompletionReviewInput.currentSchemaVersion)
        #expect(decodedAssessment.schemaVersion == SupervisorAssessment.currentSchemaVersion)
    }

    @Test
    func unknownCandidateActionsCannotEnterTheContract() throws {
        let data = Data("\"approve_permission_automatically\"".utf8)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(SupervisorCandidateAction.self, from: data)
        }
    }

    @Test
    func evidenceConsentIsBoundToTaskPurposeLocationAndExpiry() {
        let evidence = SupervisorTestSupport.evidence()

        #expect(evidence.isUsable(
            for: SupervisorTestSupport.task,
            loop: .completionReview,
            model: SupervisorTestSupport.provider,
            now: SupervisorTestSupport.now
        ))

        var otherTask = SupervisorTestSupport.task
        otherTask.taskID = "other-task"
        #expect(!evidence.isUsable(
            for: otherTask,
            loop: .completionReview,
            model: SupervisorTestSupport.provider,
            now: SupervisorTestSupport.now
        ))
        #expect(!evidence.isUsable(
            for: SupervisorTestSupport.task,
            loop: .completionReview,
            model: SupervisorTestSupport.provider,
            now: SupervisorTestSupport.now.addingTimeInterval(601)
        ))
    }

    @Test
    func remoteEvidenceRequiresTheExactApprovedProvider() {
        let consent = EvidenceConsentScope(
            purposes: [.completionReview],
            maximumDataLevel: .l1StructuredEvidence,
            allowedModelLocations: [.remote],
            approvedRemoteProviderIDs: ["approved-provider"]
        )
        let evidence = SupervisorTestSupport.evidence(consent: consent)
        let approved = SupervisorModelDescriptor(
            providerID: "approved-provider",
            modelID: "model",
            modelVersion: "1",
            executionLocation: .remote
        )
        var unapproved = approved
        unapproved.providerID = "other-provider"

        #expect(evidence.isUsable(
            for: SupervisorTestSupport.task,
            loop: .completionReview,
            model: approved,
            now: SupervisorTestSupport.now
        ))
        #expect(!evidence.isUsable(
            for: SupervisorTestSupport.task,
            loop: .completionReview,
            model: unapproved,
            now: SupervisorTestSupport.now
        ))
    }

    @Test
    func factsInferencesAndGapsRemainSeparateFields() {
        let input = SupervisorTestSupport.input()
        let assessment = SupervisorTestSupport.assessment(
            for: input,
            recommendation: .missingEvidence,
            uncertainty: .medium,
            missingEvidence: true,
            proposedActions: [.requestEvidence]
        )

        #expect(assessment.observedFacts.count == 1)
        #expect(assessment.inferences.count == 1)
        #expect(assessment.missingEvidence.count == 1)
        #expect(assessment.observedFacts[0].evidenceIDs == assessment.usedEvidenceIDs)
    }
}
