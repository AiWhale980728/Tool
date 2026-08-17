import Foundation

public struct OpenAIIndependentCompletionReviewEvaluator: IndependentCompletionReviewEvaluatorProvider, Sendable {
    public static let promptVersion = "openai-independent-completion-evaluator-prompt-v2"

    public let descriptor: SupervisorModelDescriptor
    public var promptVersion: String { Self.promptVersion }

    private let apiKey: String
    private let systemPrompt: String
    private let endpoint: URL
    private let timeout: TimeInterval
    private let session: URLSession

    public static func modelDescriptor(
        modelID: String,
        modelVersion: String = "api"
    ) -> SupervisorModelDescriptor {
        SupervisorModelDescriptor(
            providerID: "openai",
            modelID: modelID,
            modelVersion: modelVersion,
            executionLocation: .remote
        )
    }

    public init(
        apiKey: String,
        modelID: String,
        systemPrompt: String,
        modelVersion: String = "api",
        endpoint: URL = URL(string: "https://api.openai.com/v1/chat/completions")!,
        timeout: TimeInterval = 30,
        session: URLSession = .shared
    ) {
        self.apiKey = apiKey
        self.systemPrompt = systemPrompt
        self.endpoint = endpoint
        self.timeout = timeout
        self.session = session
        descriptor = Self.modelDescriptor(modelID: modelID, modelVersion: modelVersion)
    }

    public func evaluate(
        input: CompletionReviewInput,
        assessment: SupervisorAssessment
    ) async throws -> IndependentCompletionReviewProviderResult {
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              Self.isUsableSystemPrompt(systemPrompt) else {
            throw SupervisorProviderError.unavailable
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        do {
            request.httpBody = try Self.makeRequestBody(
                input: input,
                assessment: assessment,
                modelID: descriptor.modelID,
                systemPrompt: systemPrompt
            )
        } catch {
            throw SupervisorProviderError.invalidStructuredOutput
        }

        let attemptedAt = Date()
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch is CancellationError {
            throw failure(.cancelled, attemptedAt: attemptedAt)
        } catch let error as URLError where error.code == .timedOut {
            throw failure(.timeout, attemptedAt: attemptedAt)
        } catch {
            throw failure(.providerFailure, attemptedAt: attemptedAt)
        }

        guard let http = response as? HTTPURLResponse else {
            throw failure(.unavailable, attemptedAt: attemptedAt)
        }
        guard (200..<300).contains(http.statusCode) else {
            let kind: SupervisorProviderFailureKind =
                http.statusCode == 408 || http.statusCode == 504 ? .timeout : .unavailable
            throw failure(kind, attemptedAt: attemptedAt)
        }

        let completedAt = Date()
        do {
            return try Self.decodeProviderResult(
                from: data,
                input: input,
                assessment: assessment,
                descriptor: descriptor,
                latencyMilliseconds: Self.latencyMilliseconds(
                    attemptedAt: attemptedAt,
                    completedAt: completedAt
                ),
                now: completedAt
            )
        } catch {
            throw failure(.invalidStructuredOutput, attemptedAt: attemptedAt, completedAt: completedAt)
        }
    }

    private func failure(
        _ kind: SupervisorProviderFailureKind,
        attemptedAt: Date,
        completedAt: Date = Date()
    ) -> SupervisorProviderFailure {
        SupervisorProviderFailure(receipt: SupervisorProviderFailureReceipt(
            providerID: descriptor.providerID,
            requestedModelID: descriptor.modelID,
            promptVersion: promptVersion,
            failureKind: kind,
            latencyMilliseconds: Self.latencyMilliseconds(
                attemptedAt: attemptedAt,
                completedAt: completedAt
            ),
            attemptedAt: attemptedAt
        ))
    }

    private static func latencyMilliseconds(attemptedAt: Date, completedAt: Date) -> Int {
        Int(max(0, completedAt.timeIntervalSince(attemptedAt) * 1_000).rounded())
    }

    static func makeRequestBody(
        input: CompletionReviewInput,
        assessment: SupervisorAssessment,
        modelID: String,
        systemPrompt: String
    ) throws -> Data {
        guard isUsableSystemPrompt(systemPrompt),
              !SupervisorSensitiveTextScanner.containsProhibitedContent(in: input),
              !SupervisorSensitiveTextScanner.containsProhibitedContent(in: assessment) else {
            throw SupervisorProviderError.invalidStructuredOutput
        }
        let context = OpenAIIndependentEvaluatorContext(
            task: input.task,
            goal: input.goal,
            evidence: input.evidence.map {
                OpenAIIndependentEvaluatorEvidence(
                    id: $0.id,
                    kind: $0.kind,
                    sourceKind: $0.source.kind,
                    summary: $0.summary,
                    observedAt: $0.observedAt,
                    integrity: $0.integrity
                )
            },
            assessment: assessment
        )
        let contextData = try RelayJSON.makeEncoder(prettyPrinted: true).encode(context)
        guard let contextText = String(data: contextData, encoding: .utf8) else {
            throw SupervisorProviderError.invalidStructuredOutput
        }
        let body: [String: Any] = [
            "model": modelID,
            "messages": [
                [
                    "role": "system",
                    "content": systemPrompt
                ],
                ["role": "user", "content": contextText]
            ],
            "response_format": [
                "type": "json_schema",
                "json_schema": [
                    "name": "notch_relay_independent_completion_evaluation",
                    "strict": true,
                    "schema": outputSchema
                ]
            ]
        ]
        return try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
    }

    private static func isUsableSystemPrompt(_ value: String) -> Bool {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return !normalized.isEmpty && normalized.utf8.count <= 8_192
    }

    static func decodeProviderResult(
        from responseData: Data,
        input: CompletionReviewInput,
        assessment: SupervisorAssessment,
        descriptor: SupervisorModelDescriptor,
        latencyMilliseconds: Int,
        now: Date
    ) throws -> IndependentCompletionReviewProviderResult {
        let response = try JSONDecoder().decode(IndependentEvaluatorChatResponse.self, from: responseData)
        guard let content = response.choices.first?.message.content,
              let outputData = content.data(using: .utf8) else {
            throw SupervisorProviderError.invalidStructuredOutput
        }
        let output: IndependentEvaluatorModelOutput
        do {
            output = try JSONDecoder().decode(IndependentEvaluatorModelOutput.self, from: outputData)
        } catch {
            throw SupervisorProviderError.invalidStructuredOutput
        }
        let findings = try output.findings.map {
            IndependentCompletionReviewFinding(
                code: $0.code,
                detail: canonical($0.detail, limit: 500),
                evidenceIDs: try $0.evidenceIDs.map(uuid),
                acceptanceCriterionIDs: $0.acceptanceCriterionIDs.map {
                    canonical($0, limit: 256)
                }
            )
        }
        let result = IndependentCompletionReviewEvaluatorResult(
            traceID: input.traceID,
            task: input.task,
            assessmentID: assessment.id,
            model: descriptor,
            verdict: output.verdict,
            scores: IndependentCompletionReviewScores(
                groundedness: output.scores.groundedness,
                criterionCoverage: output.scores.criterionCoverage,
                riskCalibration: output.scores.riskCalibration
            ),
            findings: findings,
            evaluatedAt: now,
            expiresAt: min(input.expiresAt, assessment.expiresAt)
        )
        let returnedModelID: String?
        if let model = response.model {
            guard SupervisorContractText.isCanonical(model, maximumLength: 128) else {
                throw SupervisorProviderError.invalidStructuredOutput
            }
            returnedModelID = model
        } else {
            returnedModelID = nil
        }
        return IndependentCompletionReviewProviderResult(
            evaluation: result,
            receipt: SupervisorProviderReceipt(
                providerID: descriptor.providerID,
                requestedModelID: descriptor.modelID,
                returnedModelID: returnedModelID,
                promptVersion: promptVersion,
                inputTokenCount: response.usage?.inputTokenCount,
                outputTokenCount: response.usage?.outputTokenCount,
                totalTokenCount: response.usage?.totalTokenCount,
                latencyMilliseconds: latencyMilliseconds,
                completedAt: now
            )
        )
    }

    private static func uuid(_ value: String) throws -> UUID {
        guard let uuid = UUID(uuidString: value) else {
            throw SupervisorProviderError.invalidStructuredOutput
        }
        return uuid
    }

    private static func canonical(_ value: String, limit: Int) -> String {
        let printable = value.unicodeScalars.filter { $0.value >= 0x20 && $0.value != 0x7F }
        let collapsed = printable
            .map(String.init)
            .joined()
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return String(collapsed.prefix(limit))
    }

    private static var outputSchema: [String: Any] { [
        "type": "object",
        "additionalProperties": false,
        "required": ["verdict", "scores", "findings"],
        "properties": [
            "verdict": enumSchema([
                CompletionReviewEvaluatorVerdict.supportsAssessment.rawValue,
                CompletionReviewEvaluatorVerdict.rejectsAssessment.rawValue,
                CompletionReviewEvaluatorVerdict.humanReviewRequired.rawValue
            ]),
            "scores": objectSchema(
                required: ["groundedness", "criterionCoverage", "riskCalibration"],
                properties: [
                    "groundedness": score,
                    "criterionCoverage": score,
                    "riskCalibration": score
                ]
            ),
            "findings": [
                "type": "array",
                "items": objectSchema(
                    required: ["code", "detail", "evidenceIDs", "acceptanceCriterionIDs"],
                    properties: [
                        "code": enumSchema(IndependentCompletionReviewFindingCode.allCases.map(\.rawValue)),
                        "detail": string,
                        "evidenceIDs": stringArray,
                        "acceptanceCriterionIDs": stringArray
                    ]
                )
            ]
        ]
    ] }

    private static var string: [String: Any] { ["type": "string"] }
    private static var stringArray: [String: Any] { ["type": "array", "items": string] }
    private static var score: [String: Any] { ["type": "number", "minimum": 0, "maximum": 1] }

    private static func enumSchema(_ values: [String]) -> [String: Any] {
        ["type": "string", "enum": values]
    }

    private static func objectSchema(
        required: [String],
        properties: [String: Any]
    ) -> [String: Any] {
        [
            "type": "object",
            "additionalProperties": false,
            "required": required,
            "properties": properties
        ]
    }
}

private struct OpenAIIndependentEvaluatorContext: Encodable {
    var task: SupervisorTaskIdentity
    var goal: SupervisorTaskGoal
    var evidence: [OpenAIIndependentEvaluatorEvidence]
    var assessment: SupervisorAssessment
}

private struct OpenAIIndependentEvaluatorEvidence: Encodable {
    var id: UUID
    var kind: EvidenceKind
    var sourceKind: EvidenceSourceKind
    var summary: String
    var observedAt: Date
    var integrity: EvidenceIntegrity
}

private struct IndependentEvaluatorChatResponse: Decodable {
    struct Choice: Decodable {
        struct Message: Decodable { var content: String? }
        var message: Message
    }

    struct Usage: Decodable {
        var inputTokenCount: Int?
        var outputTokenCount: Int?
        var totalTokenCount: Int?

        private enum CodingKeys: String, CodingKey {
            case inputTokenCount = "prompt_tokens"
            case outputTokenCount = "completion_tokens"
            case totalTokenCount = "total_tokens"
        }
    }

    var model: String?
    var choices: [Choice]
    var usage: Usage?
}

private struct IndependentEvaluatorModelOutput: Decodable {
    struct Scores: Decodable {
        var groundedness: Double
        var criterionCoverage: Double
        var riskCalibration: Double
    }

    struct Finding: Decodable {
        var code: IndependentCompletionReviewFindingCode
        var detail: String
        var evidenceIDs: [String]
        var acceptanceCriterionIDs: [String]
    }

    var verdict: CompletionReviewEvaluatorVerdict
    var scores: Scores
    var findings: [Finding]
}
