import Foundation
import Testing
@testable import RelayCore

@Suite("Completion Review live runtime")
struct CompletionReviewRuntimeTests {
    @Test
    func livePolicyAcceptsOnlyTheExplicitlyApprovedRemoteProvider() throws {
        let session = reviewSession()
        let provider = remoteProvider()
        let input = try CompletionReviewInputBuilder.build(
            session: session,
            draft: draft(),
            provider: provider,
            consentConfirmedAt: SupervisorTestSupport.now,
            now: SupervisorTestSupport.now
        )
        let policy = CompletionReviewPolicy.liveShadow(approvedProviderIDs: ["openai"])

        let accepted = policy.preflight(
            input: input,
            provider: provider,
            now: SupervisorTestSupport.now
        )
        var other = provider
        other.providerID = "unapproved-provider"
        let rejected = policy.preflight(
            input: input,
            provider: other,
            now: SupervisorTestSupport.now
        )

        #expect(accepted.disposition == .allowShadowAssessment)
        #expect(rejected.disposition == .harnessOnly)
        #expect(rejected.violations.contains { $0.code == .phaseBoundary })
        #expect(rejected.violations.contains { $0.code == .evidenceNotAuthorized })
    }

    @Test
    func builderUsesBoundedStructuredEvidenceAndExactConsent() throws {
        let session = reviewSession()
        let provider = remoteProvider()
        let evaluator = OpenAIIndependentCompletionReviewEvaluator.modelDescriptor(
            modelID: "independent-model"
        )
        let input = try CompletionReviewInputBuilder.build(
            session: session,
            draft: draft(),
            provider: provider,
            independentEvaluatorProvider: evaluator,
            consentConfirmedAt: SupervisorTestSupport.now,
            now: SupervisorTestSupport.now
        )

        #expect(input.contextMode == .authorizedTask)
        #expect(input.contextDataLevel == .l1StructuredEvidence)
        #expect(input.task.triggerEventID == session.lastEventID)
        #expect(input.evidence.count == 1)
        #expect(input.evidence[0].integrity == .partial)
        #expect(input.evidence[0].dataLevel == .l0RuntimeMetadata)
        #expect(input.evidence[0].consentScope.approvedRemoteProviderIDs == ["openai"])
        #expect(input.evidence[0].reference == nil)
        #expect(input.consent?.purpose == .completionReview)
        #expect(input.consent?.provider == provider)
        #expect(input.consent?.independentEvaluatorProvider == evaluator)
        #expect(input.consent?.maximumDataLevel == .l1StructuredEvidence)
        #expect(input.consent?.localRetentionSeconds == 24 * 60 * 60)
        #expect(input.consent?.remoteRetentionPolicy == .providerControlled)
    }

    @Test
    func livePolicyRejectsAnEvaluatorThatReusesTheSupervisorModel() throws {
        let provider = remoteProvider()
        let input = try CompletionReviewInputBuilder.build(
            session: reviewSession(),
            draft: draft(),
            provider: provider,
            independentEvaluatorProvider: provider,
            consentConfirmedAt: SupervisorTestSupport.now,
            now: SupervisorTestSupport.now
        )

        let decision = CompletionReviewPolicy
            .liveShadow(approvedProviderIDs: [provider.providerID])
            .preflight(input: input, provider: provider, now: SupervisorTestSupport.now)

        #expect(decision.disposition == .harnessOnly)
        #expect(decision.violations.contains { $0.code == .evidenceNotAuthorized })
    }

    @Test
    func perCallConsentMustBeConfirmedBeforeProviderExecution() throws {
        let provider = remoteProvider()
        var input = try CompletionReviewInputBuilder.build(
            session: reviewSession(),
            draft: draft(),
            provider: provider,
            consentConfirmedAt: nil,
            now: SupervisorTestSupport.now
        )
        let policy = CompletionReviewPolicy.liveShadow(approvedProviderIDs: ["openai"])

        let previewDecision = policy.preflight(
            input: input,
            provider: provider,
            now: SupervisorTestSupport.now
        )
        input.consent?.confirmedAt = SupervisorTestSupport.now
        let confirmedDecision = policy.preflight(
            input: input,
            provider: provider,
            now: SupervisorTestSupport.now
        )

        #expect(previewDecision.disposition == .harnessOnly)
        #expect(previewDecision.violations.contains { $0.code == .evidenceNotAuthorized })
        #expect(confirmedDecision.disposition == .allowShadowAssessment)
    }

    @Test
    func userAuthorizedResultSummaryRemainsPartialHumanEvidence() throws {
        let provider = remoteProvider()
        let input = try CompletionReviewInputBuilder.build(
            session: reviewSession(),
            draft: CompletionReviewDraft(
                goal: "Complete the live task safely.",
                acceptanceCriteria: ["The requested result is delivered"],
                resultSummary: "Implemented the requested flow and reported the checks as passing.",
                updatedAt: SupervisorTestSupport.now
            ),
            provider: provider,
            consentConfirmedAt: SupervisorTestSupport.now,
            now: SupervisorTestSupport.now
        )

        #expect(input.evidence.count == 1)
        #expect(input.evidence[0].source.kind == .human)
        #expect(input.evidence[0].kind == .reviewAvailable)
        #expect(input.evidence[0].integrity == .partial)
        #expect(input.evidence[0].summary.contains("Implemented the requested flow"))
    }

    @Test
    func partialLifecycleEvidenceCanNeverPassAsVerifiedReady() throws {
        let provider = remoteProvider()
        let input = try CompletionReviewInputBuilder.build(
            session: reviewSession(),
            draft: draft(),
            provider: provider,
            consentConfirmedAt: SupervisorTestSupport.now,
            now: SupervisorTestSupport.now
        )
        let assessment = SupervisorAssessment(
            traceID: input.traceID,
            task: input.task,
            model: provider,
            usedEvidenceIDs: input.evidence.map(\.id),
            observedFacts: [SupervisorObservedFact(
                id: "fact-1",
                statement: "The Agent reported that the result is ready for review.",
                evidenceIDs: input.evidence.map(\.id),
                acceptanceCriterionIDs: input.goal.acceptanceCriteria.map(\.id)
            )],
            inferences: [],
            missingEvidence: [],
            recommendation: .verifiedReady,
            risk: SupervisorRisk(
                level: .low,
                factors: [],
                impactScopes: ["task result"],
                reversibility: .reversible
            ),
            uncertainty: SupervisorUncertainty(level: .low),
            proposedActions: [.presentCompletionConfirmation],
            generatedAt: SupervisorTestSupport.now,
            expiresAt: SupervisorTestSupport.now.addingTimeInterval(300)
        )
        let decision = CompletionReviewPolicy
            .liveShadow(approvedProviderIDs: ["openai"])
            .evaluate(
                input: input,
                assessment: assessment,
                provider: provider,
                now: SupervisorTestSupport.now
            )

        #expect(decision.disposition == .harnessOnly)
        #expect(decision.violations.contains { $0.code == .unsafeVerifiedReady })
    }

    @Test
    func openAIRequestExcludesReferencesAndUnboundedContent() throws {
        let provider = remoteProvider()
        var input = try CompletionReviewInputBuilder.build(
            session: reviewSession(),
            draft: draft(),
            provider: provider,
            consentConfirmedAt: SupervisorTestSupport.now,
            now: SupervisorTestSupport.now
        )
        input.evidence[0].kind = .artifactProduced
        input.evidence[0].summary = "交付物证据：PDF，不超过 64 KiB。"
        input.evidence[0].reference = "artifact-sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        let data = try OpenAICompletionReviewProvider.makeRequestBody(
            input: input,
            modelID: provider.modelID,
            systemPrompt: SupervisorTestSupport.syntheticSystemPrompt
        )
        let text = String(decoding: data, as: UTF8.self)

        #expect(!text.contains("artifact-sha256"))
        #expect(!text.contains("reference"))
        #expect(!text.contains("apiKey"))
        #expect(text.contains("交付物证据：PDF，不超过 64 KiB。"))
        #expect(text.contains(SupervisorTestSupport.syntheticSystemPrompt))
        #expect(text.contains(input.evidence[0].id.uuidString))
        #expect(text.contains("json_schema"))
        #expect(OpenAICompletionReviewProvider.promptVersion == "openai-completion-review-prompt-v3")
    }

    @Test
    func structuredProviderOutputIsWrappedWithTrustedIdentityAndPassesPolicy() throws {
        let provider = remoteProvider()
        let input = try CompletionReviewInputBuilder.build(
            session: reviewSession(),
            draft: draft(),
            provider: provider,
            consentConfirmedAt: SupervisorTestSupport.now,
            now: SupervisorTestSupport.now
        )
        let evidenceID = input.evidence[0].id.uuidString
        let content: [String: Any] = [
            "usedEvidenceIDs": [evidenceID],
            "observedFacts": [[
                "id": "fact-1",
                "statement": "The Agent reported that the result is ready for review.",
                "evidenceIDs": [evidenceID],
                "acceptanceCriterionIDs": ["criterion-1"]
            ]],
            "inferences": [],
            "missingEvidence": [[
                "id": "gap-1",
                "statement": "No independent verification result was supplied.",
                "acceptanceCriterionIDs": ["criterion-1"]
            ]],
            "recommendation": "missing_evidence",
            "risk": [
                "level": "medium",
                "factors": ["Completion is supported only by an Agent lifecycle signal."],
                "impactScopes": ["task result"],
                "reversibility": "reversible"
            ],
            "uncertainty": [
                "level": "medium",
                "reasons": ["Independent evidence is missing."]
            ],
            "proposedActions": ["request_evidence"]
        ]
        let contentData = try JSONSerialization.data(withJSONObject: content, options: [.sortedKeys])
        let contentText = String(decoding: contentData, as: UTF8.self)
        let envelope: [String: Any] = [
            "model": "test-model-2026-08-16",
            "choices": [["message": ["content": contentText]]],
            "usage": [
                "prompt_tokens": 120,
                "completion_tokens": 80,
                "total_tokens": 200
            ]
        ]
        let responseData = try JSONSerialization.data(withJSONObject: envelope)
        let providerResult = try OpenAICompletionReviewProvider.decodeProviderResult(
            from: responseData,
            input: input,
            descriptor: provider,
            latencyMilliseconds: 450,
            now: SupervisorTestSupport.now
        )
        let assessment = providerResult.assessment
        let receipt = try #require(providerResult.receipt)
        let decision = CompletionReviewPolicy
            .liveShadow(approvedProviderIDs: ["openai"])
            .evaluate(
                input: input,
                assessment: assessment,
                provider: provider,
                now: SupervisorTestSupport.now
            )

        #expect(assessment.task == input.task)
        #expect(assessment.traceID == input.traceID)
        #expect(assessment.model == provider)
        #expect(assessment.recommendation == .missingEvidence)
        #expect(receipt.providerID == "openai")
        #expect(receipt.requestedModelID == "test-model")
        #expect(receipt.returnedModelID == "test-model-2026-08-16")
        #expect(receipt.promptVersion == OpenAICompletionReviewProvider.promptVersion)
        #expect(receipt.inputTokenCount == 120)
        #expect(receipt.outputTokenCount == 80)
        #expect(receipt.totalTokenCount == 200)
        #expect(receipt.latencyMilliseconds == 450)
        #expect(decision.disposition == .allowShadowAssessment)
    }

    @Test
    func runtimeStoreRoundTripsAndDeletesOneTask() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("notch-relay-supervisor-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = CompletionReviewRuntimeStore(root: root)
        let session = reviewSession()
        let provider = remoteProvider()
        let input = try CompletionReviewInputBuilder.build(
            session: session,
            draft: draft(),
            provider: provider,
            consentConfirmedAt: SupervisorTestSupport.now,
            now: SupervisorTestSupport.now
        )
        let snapshot = CompletionReviewRuntimeSnapshot(
            drafts: [session.key: draft()],
            reviews: [session.key: StoredCompletionReview(
                input: input,
                providerReceipt: SupervisorProviderReceipt(
                    providerID: provider.providerID,
                    requestedModelID: provider.modelID,
                    returnedModelID: "test-model-2026-08-16",
                    promptVersion: OpenAICompletionReviewProvider.promptVersion,
                    inputTokenCount: 120,
                    outputTokenCount: 80,
                    totalTokenCount: 200,
                    latencyMilliseconds: 450,
                    completedAt: SupervisorTestSupport.now
                ),
                recordedAt: SupervisorTestSupport.now
            )],
            decisions: [CompletionReviewHumanDecision(
                task: input.task,
                assessmentID: nil,
                kind: .humanReview,
                decidedAt: SupervisorTestSupport.now
            )]
        )

        try store.persist(snapshot)
        #expect(try store.load() == snapshot)
        try store.deleteTask(session.key)
        let deleted = try store.load()
        #expect(deleted.drafts.isEmpty)
        #expect(deleted.reviews.isEmpty)
        #expect(deleted.decisions.isEmpty)
    }

    @Test
    func runtimeStoreRoundTripsAndDeletesProviderFailureReceipt() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("notch-relay-provider-failure-store-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = CompletionReviewRuntimeStore(root: root)
        let session = reviewSession()
        let provider = remoteProvider()
        let input = try CompletionReviewInputBuilder.build(
            session: session,
            draft: draft(),
            provider: provider,
            consentConfirmedAt: SupervisorTestSupport.now,
            now: SupervisorTestSupport.now
        )
        let receipt = SupervisorProviderFailureReceipt(
            providerID: provider.providerID,
            requestedModelID: provider.modelID,
            promptVersion: OpenAICompletionReviewProvider.promptVersion,
            failureKind: .timeout,
            latencyMilliseconds: 30_000,
            attemptedAt: SupervisorTestSupport.now
        )
        let snapshot = CompletionReviewRuntimeSnapshot(reviews: [
            session.key: StoredCompletionReview(
                input: input,
                fallback: SupervisorFallback(
                    traceID: input.traceID,
                    code: .providerTimeout,
                    providerFailureReceipt: receipt
                ),
                recordedAt: SupervisorTestSupport.now
            )
        ])

        try store.persist(snapshot)
        #expect(try store.load() == snapshot)
        try store.deleteTask(session.key)
        #expect(try store.load().reviews[session.key] == nil)
    }

    @Test
    func runtimeMigratesUnconsentedReviewsAndPrunesExpiredData() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("notch-relay-supervisor-migration-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = CompletionReviewRuntimeStore(root: root)
        let session = reviewSession()
        var legacyInput = try CompletionReviewInputBuilder.build(
            session: session,
            draft: draft(),
            provider: remoteProvider(),
            consentConfirmedAt: SupervisorTestSupport.now,
            now: SupervisorTestSupport.now
        )
        legacyInput.schemaVersion = 1
        legacyInput.consent = nil
        let legacy = CompletionReviewRuntimeSnapshot(
            schemaVersion: 1,
            drafts: [session.key: draft()],
            reviews: [session.key: StoredCompletionReview(
                input: legacyInput,
                recordedAt: SupervisorTestSupport.now
            )]
        )

        try store.persist(legacy)
        var migrated = try store.load()
        #expect(migrated.schemaVersion == CompletionReviewRuntimeSnapshot.currentSchemaVersion)
        #expect(migrated.reviews.isEmpty)
        #expect(migrated.drafts.count == 1)

        let removed = migrated.pruneExpired(
            now: SupervisorTestSupport.now.addingTimeInterval(24 * 60 * 60 + 1)
        )
        #expect(removed == 1)
        #expect(migrated.drafts.isEmpty)
    }

    @Test
    func schemaThreeReviewWithoutProviderReceiptMigratesToCurrentSchema() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("notch-relay-supervisor-schema-three-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = CompletionReviewRuntimeStore(root: root)
        let session = reviewSession()
        let input = try CompletionReviewInputBuilder.build(
            session: session,
            draft: draft(),
            provider: remoteProvider(),
            consentConfirmedAt: SupervisorTestSupport.now,
            now: SupervisorTestSupport.now
        )
        let schemaThree = CompletionReviewRuntimeSnapshot(
            schemaVersion: 3,
            reviews: [session.key: StoredCompletionReview(
                input: input,
                recordedAt: SupervisorTestSupport.now
            )]
        )

        try store.persist(schemaThree)
        let migrated = try store.load()

        #expect(migrated.schemaVersion == CompletionReviewRuntimeSnapshot.currentSchemaVersion)
        #expect(migrated.reviews[session.key]?.providerReceipt == nil)
    }

    @Test
    func schemaFiveReviewWithoutFailureReceiptMigratesToSchemaSix() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("notch-relay-supervisor-schema-five-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = CompletionReviewRuntimeStore(root: root)
        let session = reviewSession()
        let input = try CompletionReviewInputBuilder.build(
            session: session,
            draft: draft(),
            provider: remoteProvider(),
            consentConfirmedAt: SupervisorTestSupport.now,
            now: SupervisorTestSupport.now
        )
        let schemaFive = CompletionReviewRuntimeSnapshot(
            schemaVersion: 5,
            reviews: [session.key: StoredCompletionReview(
                input: input,
                recordedAt: SupervisorTestSupport.now
            )]
        )

        try store.persist(schemaFive)
        let migrated = try store.load()

        #expect(migrated.schemaVersion == 6)
        #expect(migrated.reviews[session.key] != nil)
        #expect(migrated.reviews[session.key]?.fallback?.providerFailureReceipt == nil)
    }

    private func reviewSession() -> RelaySessionState {
        RelaySessionState(event: RelayEvent(
            id: UUID(uuidString: "40000000-0000-0000-0000-000000000001")!,
            source: .codex,
            sourceEvent: "TurnComplete",
            sessionID: "live-session",
            status: .readyToReview,
            summary: "Result ready for review.",
            occurredAt: SupervisorTestSupport.now.addingTimeInterval(-10),
            receivedAt: SupervisorTestSupport.now.addingTimeInterval(-10)
        ))
    }

    private func draft() -> CompletionReviewDraft {
        CompletionReviewDraft(
            goal: "Complete the live task safely.",
            acceptanceCriteria: ["The requested result is delivered"],
            revision: UUID(uuidString: "50000000-0000-0000-0000-000000000001")!,
            updatedAt: SupervisorTestSupport.now.addingTimeInterval(-20)
        )
    }

    private func remoteProvider() -> SupervisorModelDescriptor {
        SupervisorModelDescriptor(
            providerID: "openai",
            modelID: "test-model",
            modelVersion: "api",
            executionLocation: .remote
        )
    }
}
