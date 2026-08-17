import Foundation

public struct OpenAICompletionReviewProvider: SupervisorModelProvider, Sendable {
    public static let promptVersion = "openai-completion-review-prompt-v3"

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

    public func assessCompletion(
        _ input: CompletionReviewInput
    ) async throws -> SupervisorAssessment {
        try await performAssessment(input).assessment
    }

    public func assessCompletionWithReceipt(
        _ input: CompletionReviewInput
    ) async throws -> SupervisorProviderResult {
        try await performAssessment(input)
    }

    private func performAssessment(
        _ input: CompletionReviewInput
    ) async throws -> SupervisorProviderResult {
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
        modelID: String,
        systemPrompt: String
    ) throws -> Data {
        guard isUsableSystemPrompt(systemPrompt),
              !SupervisorSensitiveTextScanner.containsProhibitedContent(in: input) else {
            throw SupervisorProviderError.invalidStructuredOutput
        }
        let context = OpenAIReviewContext(
            task: input.task,
            goal: input.goal,
            evidence: input.evidence.map {
                OpenAIReviewEvidence(
                    id: $0.id,
                    kind: $0.kind,
                    sourceKind: $0.source.kind,
                    summary: $0.summary,
                    observedAt: $0.observedAt,
                    integrity: $0.integrity
                )
            },
            allowedActions: input.allowedActions
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
                [
                    "role": "user",
                    "content": contextText
                ]
            ],
            "response_format": [
                "type": "json_schema",
                "json_schema": [
                    "name": "notch_relay_completion_review",
                    "strict": true,
                    "schema": Self.outputSchema
                ]
            ]
        ]
        return try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
    }

    private static func isUsableSystemPrompt(_ value: String) -> Bool {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return !normalized.isEmpty && normalized.utf8.count <= 8_192
    }

    static func decodeAssessment(
        from responseData: Data,
        input: CompletionReviewInput,
        descriptor: SupervisorModelDescriptor,
        now: Date
    ) throws -> SupervisorAssessment {
        let response = try JSONDecoder().decode(ChatCompletionResponse.self, from: responseData)
        return try decodeAssessment(
            from: response,
            input: input,
            descriptor: descriptor,
            now: now
        )
    }

    static func decodeProviderResult(
        from responseData: Data,
        input: CompletionReviewInput,
        descriptor: SupervisorModelDescriptor,
        latencyMilliseconds: Int,
        now: Date
    ) throws -> SupervisorProviderResult {
        let response = try JSONDecoder().decode(ChatCompletionResponse.self, from: responseData)
        let returnedModelID: String?
        if let model = response.model {
            guard SupervisorContractText.isCanonical(model, maximumLength: 128) else {
                throw SupervisorProviderError.invalidStructuredOutput
            }
            returnedModelID = model
        } else {
            returnedModelID = nil
        }
        let assessment = try decodeAssessment(
            from: response,
            input: input,
            descriptor: descriptor,
            now: now
        )
        return SupervisorProviderResult(
            assessment: assessment,
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

    private static func decodeAssessment(
        from response: ChatCompletionResponse,
        input: CompletionReviewInput,
        descriptor: SupervisorModelDescriptor,
        now: Date
    ) throws -> SupervisorAssessment {
        guard let content = response.choices.first?.message.content,
              let outputData = content.data(using: .utf8) else {
            throw SupervisorProviderError.invalidStructuredOutput
        }
        let output: ModelOutput
        do {
            output = try JSONDecoder().decode(ModelOutput.self, from: outputData)
        } catch {
            throw SupervisorProviderError.invalidStructuredOutput
        }

        let usedEvidenceIDs = try output.usedEvidenceIDs.map(Self.uuid)
        let facts = try output.observedFacts.map {
            SupervisorObservedFact(
                id: Self.canonical($0.id, limit: 256),
                statement: Self.canonical($0.statement, limit: 500),
                evidenceIDs: try $0.evidenceIDs.map(Self.uuid),
                acceptanceCriterionIDs: $0.acceptanceCriterionIDs.map {
                    Self.canonical($0, limit: 256)
                }
            )
        }
        let inferences = try output.inferences.map {
            SupervisorInference(
                id: Self.canonical($0.id, limit: 256),
                statement: Self.canonical($0.statement, limit: 500),
                evidenceIDs: try $0.evidenceIDs.map(Self.uuid),
                uncertainty: $0.uncertainty
            )
        }
        let gaps = output.missingEvidence.map {
            SupervisorEvidenceGap(
                id: Self.canonical($0.id, limit: 256),
                statement: Self.canonical($0.statement, limit: 500),
                acceptanceCriterionIDs: $0.acceptanceCriterionIDs.map {
                    Self.canonical($0, limit: 256)
                }
            )
        }
        let expiresAt = min(input.expiresAt, now.addingTimeInterval(10 * 60))
        return SupervisorAssessment(
            traceID: input.traceID,
            task: input.task,
            model: descriptor,
            usedEvidenceIDs: usedEvidenceIDs,
            observedFacts: facts,
            inferences: inferences,
            missingEvidence: gaps,
            recommendation: output.recommendation,
            risk: SupervisorRisk(
                level: output.risk.level,
                factors: output.risk.factors.map { Self.canonical($0, limit: 300) },
                impactScopes: output.risk.impactScopes.map { Self.canonical($0, limit: 160) },
                reversibility: output.risk.reversibility
            ),
            uncertainty: SupervisorUncertainty(
                level: output.uncertainty.level,
                reasons: output.uncertainty.reasons.map { Self.canonical($0, limit: 300) }
            ),
            proposedActions: output.proposedActions,
            generatedAt: now,
            expiresAt: expiresAt
        )
    }

    private static func uuid(_ value: String) throws -> UUID {
        guard let result = UUID(uuidString: value) else {
            throw SupervisorProviderError.invalidStructuredOutput
        }
        return result
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
        "required": [
            "usedEvidenceIDs", "observedFacts", "inferences", "missingEvidence",
            "recommendation", "risk", "uncertainty", "proposedActions"
        ],
        "properties": [
            "usedEvidenceIDs": stringArray,
            "observedFacts": [
                "type": "array",
                "items": objectSchema(
                    required: ["id", "statement", "evidenceIDs", "acceptanceCriterionIDs"],
                    properties: [
                        "id": string,
                        "statement": string,
                        "evidenceIDs": stringArray,
                        "acceptanceCriterionIDs": stringArray
                    ]
                )
            ],
            "inferences": [
                "type": "array",
                "items": objectSchema(
                    required: ["id", "statement", "evidenceIDs", "uncertainty"],
                    properties: [
                        "id": string,
                        "statement": string,
                        "evidenceIDs": stringArray,
                        "uncertainty": enumSchema(SupervisorUncertaintyLevel.allCases.map(\.rawValue))
                    ]
                )
            ],
            "missingEvidence": [
                "type": "array",
                "items": objectSchema(
                    required: ["id", "statement", "acceptanceCriterionIDs"],
                    properties: [
                        "id": string,
                        "statement": string,
                        "acceptanceCriterionIDs": stringArray
                    ]
                )
            ],
            "recommendation": enumSchema(CompletionReviewRecommendation.allCases.map(\.rawValue)),
            "risk": objectSchema(
                required: ["level", "factors", "impactScopes", "reversibility"],
                properties: [
                    "level": enumSchema(SupervisorRiskLevel.allCases.map(\.rawValue)),
                    "factors": stringArray,
                    "impactScopes": stringArray,
                    "reversibility": enumSchema(SupervisorReversibility.allCases.map(\.rawValue))
                ]
            ),
            "uncertainty": objectSchema(
                required: ["level", "reasons"],
                properties: [
                    "level": enumSchema(SupervisorUncertaintyLevel.allCases.map(\.rawValue)),
                    "reasons": stringArray
                ]
            ),
            "proposedActions": [
                "type": "array",
                "items": enumSchema(SupervisorCandidateAction.allCases.map(\.rawValue))
            ]
        ]
    ] }

    private static var string: [String: Any] { ["type": "string"] }
    private static var stringArray: [String: Any] { [
        "type": "array",
        "items": string
    ] }

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

private struct OpenAIReviewContext: Encodable {
    var task: SupervisorTaskIdentity
    var goal: SupervisorTaskGoal
    var evidence: [OpenAIReviewEvidence]
    var allowedActions: [SupervisorCandidateAction]
}

private struct OpenAIReviewEvidence: Encodable {
    var id: UUID
    var kind: EvidenceKind
    var sourceKind: EvidenceSourceKind
    var summary: String
    var observedAt: Date
    var integrity: EvidenceIntegrity
}

private struct ChatCompletionResponse: Decodable {
    struct Choice: Decodable {
        struct Message: Decodable {
            var content: String?
        }
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

private struct ModelOutput: Decodable {
    struct Fact: Decodable {
        var id: String
        var statement: String
        var evidenceIDs: [String]
        var acceptanceCriterionIDs: [String]
    }

    struct Inference: Decodable {
        var id: String
        var statement: String
        var evidenceIDs: [String]
        var uncertainty: SupervisorUncertaintyLevel
    }

    struct Gap: Decodable {
        var id: String
        var statement: String
        var acceptanceCriterionIDs: [String]
    }

    struct Risk: Decodable {
        var level: SupervisorRiskLevel
        var factors: [String]
        var impactScopes: [String]
        var reversibility: SupervisorReversibility
    }

    struct Uncertainty: Decodable {
        var level: SupervisorUncertaintyLevel
        var reasons: [String]
    }

    var usedEvidenceIDs: [String]
    var observedFacts: [Fact]
    var inferences: [Inference]
    var missingEvidence: [Gap]
    var recommendation: CompletionReviewRecommendation
    var risk: Risk
    var uncertainty: Uncertainty
    var proposedActions: [SupervisorCandidateAction]
}
