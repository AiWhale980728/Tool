import Foundation
import Testing
@testable import RelayCore

@Suite("Provider failure receipts", .serialized)
struct ProviderFailureReceiptTests {
    @Test
    func missingCredentialFailsBeforeAttemptWithoutAReceipt() async {
        let provider = OpenAICompletionReviewProvider(
            apiKey: "",
            modelID: "test-model",
            systemPrompt: SupervisorTestSupport.syntheticSystemPrompt,
            session: serviceUnavailableSession()
        )

        do {
            _ = try await provider.assessCompletion(SupervisorTestSupport.input())
            Issue.record("Expected a pre-attempt provider failure")
        } catch let error as SupervisorProviderError {
            #expect(error == .unavailable)
        } catch is SupervisorProviderFailure {
            Issue.record("A request that never started must not receive a failure receipt")
        } catch {
            Issue.record("Expected a bounded provider error")
        }
    }

    @Test
    func supervisorHTTPFailureProducesABoundedAttemptReceipt() async {
        let provider = OpenAICompletionReviewProvider(
            apiKey: "synthetic-key",
            modelID: "test-model",
            systemPrompt: SupervisorTestSupport.syntheticSystemPrompt,
            session: serviceUnavailableSession()
        )

        do {
            _ = try await provider.assessCompletion(SupervisorTestSupport.input())
            Issue.record("Expected a receipted provider failure")
        } catch let failure as SupervisorProviderFailure {
            #expect(failure.receipt.providerID == "openai")
            #expect(failure.receipt.requestedModelID == "test-model")
            #expect(failure.receipt.promptVersion == OpenAICompletionReviewProvider.promptVersion)
            #expect(failure.receipt.failureKind == .unavailable)
            #expect((0...120_000).contains(failure.receipt.latencyMilliseconds))
        } catch {
            Issue.record("Expected a bounded failure receipt")
        }
    }

    @Test
    func independentEvaluatorHTTPFailureProducesABoundedAttemptReceipt() async {
        let provider = OpenAIIndependentCompletionReviewEvaluator(
            apiKey: "synthetic-key",
            modelID: "evaluator-model",
            systemPrompt: SupervisorTestSupport.syntheticSystemPrompt,
            session: serviceUnavailableSession()
        )
        let input = SupervisorTestSupport.input()
        let assessment = SupervisorTestSupport.assessment(for: input)

        do {
            _ = try await provider.evaluate(input: input, assessment: assessment)
            Issue.record("Expected a receipted evaluator failure")
        } catch let failure as SupervisorProviderFailure {
            #expect(failure.receipt.providerID == "openai")
            #expect(failure.receipt.requestedModelID == "evaluator-model")
            #expect(failure.receipt.promptVersion
                == OpenAIIndependentCompletionReviewEvaluator.promptVersion)
            #expect(failure.receipt.failureKind == .unavailable)
            #expect((0...120_000).contains(failure.receipt.latencyMilliseconds))
        } catch {
            Issue.record("Expected a bounded evaluator failure receipt")
        }
    }

    private func serviceUnavailableSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ServiceUnavailableURLProtocol.self]
        return URLSession(configuration: configuration)
    }
}

private final class ServiceUnavailableURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url,
              let response = HTTPURLResponse(
                url: url,
                statusCode: 503,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
              ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("{}".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
