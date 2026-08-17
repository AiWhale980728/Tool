import Foundation
@testable import RelayCore

enum SupervisorTestSupport {
    static let syntheticSystemPrompt = "Synthetic instruction for request-shape testing only."

    static let now = Date(timeIntervalSince1970: 2_000_000_000)
    static let traceID = SupervisorTraceID(
        rawValue: UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
    )
    static let task = SupervisorTaskIdentity(
        source: .codex,
        taskID: "synthetic-task",
        sessionID: "synthetic-session",
        triggerEventID: UUID(uuidString: "20000000-0000-0000-0000-000000000001")!
    )
    static let provider = SupervisorModelDescriptor(
        providerID: "fixture-provider",
        modelID: "fixture-model",
        modelVersion: "1",
        executionLocation: .fixture
    )

    static func evidence(
        id: UUID = UUID(uuidString: "30000000-0000-0000-0000-000000000001")!,
        task: SupervisorTaskIdentity = task,
        kind: EvidenceKind = .testPassed,
        summary: String = "Synthetic tests passed.",
        integrity: EvidenceIntegrity = .complete,
        dataLevel: SupervisorDataLevel = .l1StructuredEvidence,
        consent: EvidenceConsentScope? = nil,
        expiresAt: Date? = now.addingTimeInterval(600)
    ) -> EvidenceRecord {
        EvidenceRecord(
            id: id,
            taskID: task.taskID,
            sessionID: task.sessionID,
            agentSource: task.source,
            kind: kind,
            source: EvidenceSource(kind: .tool, sourceID: "synthetic-fixture"),
            summary: summary,
            reference: "fixture://evidence/\(id.uuidString.lowercased())",
            observedAt: now.addingTimeInterval(-10),
            expiresAt: expiresAt,
            dataLevel: dataLevel,
            consentScope: consent ?? EvidenceConsentScope(
                purposes: [.completionReview],
                maximumDataLevel: dataLevel,
                allowedModelLocations: [.fixture]
            ),
            integrity: integrity
        )
    }

    static func input(
        task: SupervisorTaskIdentity = task,
        evidence: [EvidenceRecord]? = nil,
        allowedActions: [SupervisorCandidateAction] = [
            .presentCompletionConfirmation,
            .requestEvidence,
            .continueInSourceAgent,
            .openSourceAgent,
            .requestHumanReview
        ],
        contextMode: SupervisorContextMode = .syntheticFixture,
        contextDataLevel: SupervisorDataLevel = .l1StructuredEvidence
    ) -> CompletionReviewInput {
        CompletionReviewInput(
            traceID: traceID,
            task: task,
            goal: SupervisorTaskGoal(
                statement: "Complete the synthetic task safely.",
                acceptanceCriteria: [
                    AcceptanceCriterion(id: "criterion-1", statement: "Synthetic checks pass")
                ]
            ),
            evidence: evidence ?? [Self.evidence(task: task)],
            allowedActions: allowedActions,
            contextMode: contextMode,
            contextDataLevel: contextDataLevel,
            contextVersion: "fixture-context-v1",
            policyVersion: CompletionReviewPolicy.phaseOneVersion,
            consent: CompletionReviewConsent(
                provider: provider,
                maximumDataLevel: contextDataLevel,
                preparedAt: now.addingTimeInterval(-60),
                confirmedAt: now.addingTimeInterval(-30)
            ),
            createdAt: now.addingTimeInterval(-60),
            expiresAt: now.addingTimeInterval(600)
        )
    }

    static func assessment(
        for input: CompletionReviewInput,
        provider: SupervisorModelDescriptor = provider,
        recommendation: CompletionReviewRecommendation = .verifiedReady,
        uncertainty: SupervisorUncertaintyLevel = .low,
        missingEvidence: Bool = false,
        proposedActions: [SupervisorCandidateAction] = [.presentCompletionConfirmation]
    ) -> SupervisorAssessment {
        let evidenceIDs = input.evidence.map(\.id)
        return SupervisorAssessment(
            traceID: input.traceID,
            task: input.task,
            model: provider,
            usedEvidenceIDs: evidenceIDs,
            observedFacts: [
                SupervisorObservedFact(
                    id: "fact-1",
                    statement: "Synthetic structured evidence was observed.",
                    evidenceIDs: evidenceIDs,
                    acceptanceCriterionIDs: input.goal.acceptanceCriteria.map(\.id)
                )
            ],
            inferences: [
                SupervisorInference(
                    id: "inference-1",
                    statement: "The evidence may support the recommended review outcome.",
                    evidenceIDs: evidenceIDs,
                    uncertainty: uncertainty
                )
            ],
            missingEvidence: missingEvidence
                ? [SupervisorEvidenceGap(
                    id: "gap-1",
                    statement: "A required synthetic check is missing.",
                    acceptanceCriterionIDs: [input.goal.acceptanceCriteria[0].id]
                )]
                : [],
            recommendation: recommendation,
            risk: risk(for: recommendation),
            uncertainty: SupervisorUncertainty(
                level: uncertainty,
                reasons: uncertainty == .low ? [] : ["Synthetic fixture is not conclusive."]
            ),
            proposedActions: proposedActions,
            generatedAt: now,
            expiresAt: now.addingTimeInterval(300)
        )
    }

    private static func risk(
        for recommendation: CompletionReviewRecommendation
    ) -> SupervisorRisk {
        switch recommendation {
        case .verifiedReady:
            SupervisorRisk(
                level: .low,
                factors: [],
                impactScopes: ["synthetic fixture"],
                reversibility: .reversible
            )
        case .missingEvidence, .continueWork:
            SupervisorRisk(
                level: .medium,
                factors: ["Synthetic evidence does not support completion."],
                impactScopes: ["synthetic fixture"],
                reversibility: .reversible
            )
        case .humanReviewRequired:
            SupervisorRisk(
                level: .high,
                factors: ["The fixture requires human judgment."],
                impactScopes: ["synthetic fixture"],
                reversibility: .unknown
            )
        }
    }
}
