import Foundation

public enum SupervisorSensitiveTextFinding: String, Codable, CaseIterable, Sendable {
    case credential = "credential"
    case privateKey = "private_key"
    case connectionString = "connection_string"
    case sourceCode = "source_code"
}

public enum SupervisorSensitiveTextScanner {
    public static func scan(_ text: String) -> Set<SupervisorSensitiveTextFinding> {
        guard !text.isEmpty else { return [] }
        var findings: Set<SupervisorSensitiveTextFinding> = []
        if matches(#"(?i)-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----"#, in: text) {
            findings.insert(.privateKey)
        }
        if matches(
            #"(?i)(\bsk-(?:live-|test-)?|\bghp_|\bgithub_pat_|\bxox[baprs]-|\bAKIA[0-9A-Z]{8,}|\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,})"#,
            in: text
        ) || matches(
            #"(?i)\b(api[ _-]?key|access[ _-]?token|refresh[ _-]?token|token|password|secret|authorization)\s*[:=]\s*[\"']?[^\s\"']{6,}"#,
            in: text
        ) {
            findings.insert(.credential)
        }
        if matches(#"(?i)\b(postgres(?:ql)?|mongodb(?:\+srv)?|mysql|redis)://[^\s/@:]+:[^\s/@]+@"#, in: text) {
            findings.insert(.connectionString)
        }
        if text.contains("```") || matches(
            #"(?i)(#include\s*[<\"]|\b(import\s+(Foundation|SwiftUI|AppKit|UIKit|React|torch|tensorflow)\b|func\s+[A-Za-z_][A-Za-z0-9_]*\s*\([^)]*\)\s*(async\s*)?(throws\s*)?(->[^\{]+)?\{|(?:public\s+)?(?:class|struct|enum)\s+[A-Za-z_][A-Za-z0-9_]*[^\{]*\{|def\s+[A-Za-z_][A-Za-z0-9_]*\s*\([^)]*\)\s*:|package\s+main\b))"#,
            in: text
        ) {
            findings.insert(.sourceCode)
        }
        return findings
    }

    public static func containsProhibitedContent(in input: CompletionReviewInput) -> Bool {
        let values = [input.goal.statement]
            + input.goal.acceptanceCriteria.map(\.statement)
            + input.evidence.map(\.summary)
        return values.contains { !scan($0).isEmpty }
    }

    public static func containsProhibitedContent(in assessment: SupervisorAssessment) -> Bool {
        let values = assessment.observedFacts.map(\.statement)
            + assessment.inferences.map(\.statement)
            + assessment.missingEvidence.map(\.statement)
            + assessment.risk.factors
            + assessment.risk.impactScopes
            + assessment.uncertainty.reasons
        return values.contains { !scan($0).isEmpty }
    }

    public static func containsProhibitedContent(
        in result: IndependentCompletionReviewEvaluatorResult
    ) -> Bool {
        result.findings.contains { !scan($0.detail).isEmpty }
    }

    private static func matches(_ pattern: String, in text: String) -> Bool {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return false }
        return expression.firstMatch(
            in: text,
            range: NSRange(text.startIndex..., in: text)
        ) != nil
    }
}
