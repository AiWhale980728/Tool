import Foundation
import Testing
@testable import RelayCore

@Suite("Supervisor sensitive text boundary")
struct SupervisorSensitiveTextScannerTests {
    @Test(arguments: [
        ("sk-live-examplevalue", SupervisorSensitiveTextFinding.credential),
        ("Authorization: BearerExampleSecret", .credential),
        ("password=correct-horse-battery", .credential),
        ("-----BEGIN PRIVATE KEY-----", .privateKey),
        ("postgres://user:pass@example.invalid/database", .connectionString),
        ("```swift import Foundation ```", .sourceCode),
        ("func unsafe() { print(\"secret\") }", .sourceCode),
        ("def unsafe(value): return value", .sourceCode)
    ])
    func highConfidenceSensitiveTextIsBlocked(
        text: String,
        expected: SupervisorSensitiveTextFinding
    ) {
        #expect(SupervisorSensitiveTextScanner.scan(text).contains(expected))
    }

    @Test(arguments: [
        "Add an API key settings screen without including a real key.",
        "The token budget should remain bounded.",
        "Verify that the Swift package builds and all tests pass.",
        "Document the public struct design without pasting implementation."
    ])
    func ordinaryProductRequirementsRemainUsable(text: String) {
        #expect(SupervisorSensitiveTextScanner.scan(text).isEmpty)
    }

    @Test
    func builderRejectsSensitiveUserTextBeforeInputCreation() {
        let session = RelaySessionState(event: RelayEvent(
            source: .codex,
            sourceEvent: "Stop",
            sessionID: "sensitive-builder",
            status: .readyToReview,
            summary: "Ready for review",
            occurredAt: SupervisorTestSupport.now,
            receivedAt: SupervisorTestSupport.now
        ))
        let draft = CompletionReviewDraft(
            goal: "Use api_key=example-secret-value",
            acceptanceCriteria: ["The task is complete"],
            updatedAt: SupervisorTestSupport.now
        )
        let provider = SupervisorModelDescriptor(
            providerID: "openai",
            modelID: "test-model",
            modelVersion: "api",
            executionLocation: .remote
        )

        #expect(throws: RelayError.self) {
            _ = try CompletionReviewInputBuilder.build(
                session: session,
                draft: draft,
                provider: provider,
                consentConfirmedAt: SupervisorTestSupport.now,
                now: SupervisorTestSupport.now
            )
        }
    }

    @Test
    func policyRejectsSensitiveInputAndAssessment() {
        var input = SupervisorTestSupport.input()
        input.goal.statement = "Use token=example-secret-value"
        let inputDecision = CompletionReviewPolicy().preflight(
            input: input,
            provider: SupervisorTestSupport.provider,
            now: SupervisorTestSupport.now
        )

        let cleanInput = SupervisorTestSupport.input()
        var unsafeAssessment = SupervisorTestSupport.assessment(for: cleanInput)
        unsafeAssessment.inferences[0].statement = "```swift import Foundation ```"
        let outputDecision = CompletionReviewPolicy().evaluate(
            input: cleanInput,
            assessment: unsafeAssessment,
            provider: SupervisorTestSupport.provider,
            now: SupervisorTestSupport.now
        )

        #expect(inputDecision.violations.contains { $0.code == .sensitiveContent })
        #expect(outputDecision.violations.contains { $0.code == .sensitiveContent })
    }

    @Test
    func runtimeStoreDropsProhibitedLegacyContent() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("notch-relay-sensitive-store-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = CompletionReviewRuntimeStore(root: root)
        let unsafeDraft = CompletionReviewDraft(
            goal: "Use password=example-secret-value",
            acceptanceCriteria: ["Finish safely"],
            updatedAt: SupervisorTestSupport.now
        )
        let snapshot = CompletionReviewRuntimeSnapshot(drafts: ["codex:sensitive": unsafeDraft])

        try store.persist(snapshot)
        let data = try Data(contentsOf: store.fileURL)
        #expect(!String(decoding: data, as: UTF8.self).contains("example-secret-value"))
        #expect(try store.load().drafts.isEmpty)
    }
}
