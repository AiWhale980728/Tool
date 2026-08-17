import Foundation
import Testing
@testable import RelayCore

@Suite("Completion Review offline fixtures")
struct CompletionReviewFixtureTests {
    @Test
    func minimumGoldSetCoversRequiredScenariosAndPolicyOutcomes() throws {
        let catalog = try loadCatalog()

        #expect(catalog.schemaVersion == 1)
        #expect(catalog.cases.count >= 16)
        #expect(Set(catalog.cases.map(\.language)).isSuperset(of: ["en", "zh"]))
        #expect(Set(catalog.cases.map(\.taskKind)).isSuperset(of: ["code", "non_code"]))

        let categories = Set(catalog.cases.map(\.category))
        #expect(categories.contains("sufficient_evidence"))
        #expect(categories.contains("missing_evidence"))
        #expect(categories.contains("stale_evidence"))
        #expect(categories.contains("conflicting_evidence"))
        #expect(categories.contains("subjective_quality"))
        #expect(categories.contains("prompt_injection"))
        #expect(categories.contains("multi_agent"))

        for (index, fixture) in catalog.cases.enumerated() {
            let (input, assessment) = makeContracts(for: fixture, index: index)
            let decision = CompletionReviewPolicy().evaluate(
                input: input,
                assessment: assessment,
                provider: SupervisorTestSupport.provider,
                now: SupervisorTestSupport.now
            )
            let actualCodes = Set(decision.violations.map(\.code))

            #expect(
                decision.disposition == fixture.expectedDisposition,
                "Fixture \(fixture.id) produced the wrong disposition"
            )
            #expect(
                actualCodes == Set(fixture.expectedViolationCodes),
                "Fixture \(fixture.id) produced unexpected policy violations"
            )
            #expect(!fixture.explanationPoints.isEmpty)

            if decision.disposition == .allowShadowAssessment {
                #expect(fixture.acceptableRecommendations.contains(fixture.recommendation))
                #expect(Set(fixture.proposedActions).isDisjoint(with: fixture.forbiddenActions))
            }
        }
    }

    @Test
    func goldSetContainsNoRealPathsCredentialsOrTranscriptFields() throws {
        let url = try #require(Bundle.module.url(
            forResource: "completion-review-cases",
            withExtension: "json"
        ))
        let text = try String(contentsOf: url, encoding: .utf8).lowercased()
        let forbiddenFragments = [
            "/users/", "api_key", "apikey", "cookie", "bearer ",
            "rawcommand", "raw_command", "toolargument", "tool_argument",
            "\"transcript\"", "BEGIN PRIVATE KEY".lowercased()
        ]

        for fragment in forbiddenFragments {
            #expect(!text.contains(fragment), "Fixture contains forbidden fragment: \(fragment)")
        }
    }

    private func loadCatalog() throws -> CompletionReviewFixtureCatalog {
        let url = try #require(Bundle.module.url(
            forResource: "completion-review-cases",
            withExtension: "json"
        ))
        return try JSONDecoder().decode(
            CompletionReviewFixtureCatalog.self,
            from: Data(contentsOf: url)
        )
    }

    private func makeContracts(
        for fixture: CompletionReviewFixture,
        index: Int
    ) -> (CompletionReviewInput, SupervisorAssessment) {
        var evidenceTask = SupervisorTestSupport.task
        if !fixture.evidenceTaskMatches {
            evidenceTask.taskID = "other-synthetic-task"
        }
        let evidenceID = UUID(uuidString: String(
            format: "40000000-0000-0000-0000-%012d",
            index + 1
        ))!
        let consent = EvidenceConsentScope(
            purposes: fixture.evidenceAuthorized ? [.completionReview] : [],
            maximumDataLevel: fixture.evidenceDataLevel,
            allowedModelLocations: fixture.evidenceAuthorized ? [.fixture] : []
        )
        let evidence = SupervisorTestSupport.evidence(
            id: evidenceID,
            task: evidenceTask,
            kind: fixture.evidenceKind,
            summary: fixture.evidenceSummary,
            integrity: fixture.integrity,
            dataLevel: fixture.evidenceDataLevel,
            consent: consent,
            expiresAt: fixture.evidenceExpired
                ? SupervisorTestSupport.now.addingTimeInterval(-1)
                : SupervisorTestSupport.now.addingTimeInterval(600)
        )
        let criteria = fixture.criteria.enumerated().map { criterionIndex, statement in
            AcceptanceCriterion(id: "criterion-\(criterionIndex + 1)", statement: statement)
        }
        let input = CompletionReviewInput(
            traceID: SupervisorTestSupport.traceID,
            task: SupervisorTestSupport.task,
            goal: SupervisorTaskGoal(
                statement: fixture.goal,
                acceptanceCriteria: criteria
            ),
            evidence: [evidence],
            allowedActions: fixture.allowedActions,
            contextMode: .syntheticFixture,
            contextDataLevel: fixture.evidenceDataLevel,
            contextVersion: "fixture-context-v1",
            policyVersion: CompletionReviewPolicy.phaseOneVersion,
            consent: CompletionReviewConsent(
                provider: SupervisorTestSupport.provider,
                maximumDataLevel: fixture.evidenceDataLevel,
                preparedAt: SupervisorTestSupport.now.addingTimeInterval(-60),
                confirmedAt: SupervisorTestSupport.now.addingTimeInterval(-30)
            ),
            createdAt: SupervisorTestSupport.now.addingTimeInterval(-60),
            expiresAt: SupervisorTestSupport.now.addingTimeInterval(600)
        )
        let assessment = SupervisorTestSupport.assessment(
            for: input,
            recommendation: fixture.recommendation,
            uncertainty: fixture.uncertainty,
            missingEvidence: fixture.missingEvidence,
            proposedActions: fixture.proposedActions
        )
        return (input, assessment)
    }
}

private struct CompletionReviewFixtureCatalog: Decodable {
    var schemaVersion: Int
    var cases: [CompletionReviewFixture]
}

private struct CompletionReviewFixture: Decodable {
    var id: String
    var category: String
    var language: String
    var taskKind: String
    var goal: String
    var criteria: [String]
    var evidenceKind: EvidenceKind
    var evidenceSummary: String
    var integrity: EvidenceIntegrity
    var evidenceTaskMatches: Bool
    var evidenceAuthorized: Bool
    var evidenceDataLevel: SupervisorDataLevel
    var evidenceExpired: Bool
    var recommendation: CompletionReviewRecommendation
    var uncertainty: SupervisorUncertaintyLevel
    var missingEvidence: Bool
    var allowedActions: [SupervisorCandidateAction]
    var proposedActions: [SupervisorCandidateAction]
    var acceptableRecommendations: [CompletionReviewRecommendation]
    var forbiddenActions: Set<SupervisorCandidateAction>
    var explanationPoints: [String]
    var expectedDisposition: SupervisorPolicyDisposition
    var expectedViolationCodes: [SupervisorPolicyViolationCode]
}
