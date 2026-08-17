import Foundation
import Testing
@testable import RelayCore

@Suite("Completion Review execution coordinator")
struct CompletionReviewExecutionCoordinatorTests {
    @Test
    func duplicateTaskOrTraceCannotRunConcurrently() async throws {
        let coordinator = CompletionReviewExecutionCoordinator()
        let input = SupervisorTestSupport.input()
        let result = await coordinator.begin(
            input: input,
            provider: SupervisorTestSupport.provider,
            now: SupervisorTestSupport.now
        )
        let permit = try result.get()

        let duplicate = await coordinator.begin(
            input: input,
            provider: SupervisorTestSupport.provider,
            now: SupervisorTestSupport.now
        )
        #expect(duplicate == .failure(.duplicateRequest))
        await coordinator.finish(permit, providerSucceeded: true, now: SupervisorTestSupport.now)
    }

    @Test
    func concurrencyAndRollingRateLimitsAreBounded() async throws {
        let coordinator = CompletionReviewExecutionCoordinator(
            maximumConcurrentPerProvider: 2,
            maximumStartsPerWindow: 3
        )
        let firstResult = await coordinator.begin(
            input: input(index: 1), provider: SupervisorTestSupport.provider, now: SupervisorTestSupport.now
        )
        let first = try firstResult.get()
        let secondResult = await coordinator.begin(
            input: input(index: 2), provider: SupervisorTestSupport.provider, now: SupervisorTestSupport.now
        )
        let second = try secondResult.get()
        let concurrent = await coordinator.begin(
            input: input(index: 3), provider: SupervisorTestSupport.provider, now: SupervisorTestSupport.now
        )
        #expect(concurrent == .failure(.concurrencyLimit))

        await coordinator.finish(first, providerSucceeded: true, now: SupervisorTestSupport.now)
        let thirdResult = await coordinator.begin(
            input: input(index: 3), provider: SupervisorTestSupport.provider, now: SupervisorTestSupport.now
        )
        let third = try thirdResult.get()
        await coordinator.finish(second, providerSucceeded: true, now: SupervisorTestSupport.now)
        await coordinator.finish(third, providerSucceeded: true, now: SupervisorTestSupport.now)
        let rateLimited = await coordinator.begin(
            input: input(index: 4), provider: SupervisorTestSupport.provider, now: SupervisorTestSupport.now
        )
        #expect(rateLimited == .failure(.rateLimit))
    }

    @Test
    func repeatedProviderFailuresOpenAndThenExpireCircuit() async throws {
        let coordinator = CompletionReviewExecutionCoordinator(
            maximumStartsPerWindow: 20,
            failureThreshold: 3,
            circuitOpenDuration: 60
        )
        for index in 1...3 {
            let result = await coordinator.begin(
                input: input(index: index),
                provider: SupervisorTestSupport.provider,
                now: SupervisorTestSupport.now
            )
            let permit = try result.get()
            await coordinator.finish(
                permit,
                providerSucceeded: false,
                now: SupervisorTestSupport.now
            )
        }

        let open = await coordinator.begin(
            input: input(index: 4),
            provider: SupervisorTestSupport.provider,
            now: SupervisorTestSupport.now.addingTimeInterval(1)
        )
        #expect(open == .failure(.circuitOpen))

        let recovered = await coordinator.begin(
            input: input(index: 5),
            provider: SupervisorTestSupport.provider,
            now: SupervisorTestSupport.now.addingTimeInterval(61)
        )
        guard case .success = recovered else {
            Issue.record("Expected circuit recovery")
            return
        }
    }

    @Test
    func executorFallsBackBeforeDuplicateProviderInvocation() async throws {
        let coordinator = CompletionReviewExecutionCoordinator()
        let input = SupervisorTestSupport.input()
        let permitResult = await coordinator.begin(
            input: input,
            provider: SupervisorTestSupport.provider,
            now: SupervisorTestSupport.now
        )
        let permit = try permitResult.get()
        let provider = GuardedTestProvider(
            descriptor: SupervisorTestSupport.provider,
            assessment: SupervisorTestSupport.assessment(for: input)
        )

        let result = await CompletionReviewExecutor().execute(
            input: input,
            using: provider,
            coordinator: coordinator,
            now: SupervisorTestSupport.now
        )
        guard case .harnessOnly(let fallback) = result else {
            Issue.record("Expected guard fallback")
            return
        }
        #expect(fallback.code == .duplicateRequest)
        await coordinator.finish(permit, providerSucceeded: true, now: SupervisorTestSupport.now)
    }

    private func input(index: Int) -> CompletionReviewInput {
        let task = SupervisorTaskIdentity(
            source: .codex,
            taskID: "coordinator-task-\(index)",
            sessionID: "coordinator-session-\(index)",
            triggerEventID: UUID()
        )
        var input = SupervisorTestSupport.input(task: task, evidence: [
            SupervisorTestSupport.evidence(task: task)
        ])
        input.traceID = SupervisorTraceID()
        return input
    }
}

private struct GuardedTestProvider: SupervisorModelProvider {
    var descriptor: SupervisorModelDescriptor
    var promptVersion = "guarded-test-prompt-v1"
    var assessment: SupervisorAssessment

    func assessCompletion(_ input: CompletionReviewInput) async throws -> SupervisorAssessment {
        assessment
    }
}
