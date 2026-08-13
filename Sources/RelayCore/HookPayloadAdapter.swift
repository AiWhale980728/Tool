import Foundation

public enum HookPayloadAdapter {
    public static func decode(
        data: Data,
        source: AgentSource,
        receivedAt: Date = Date()
    ) throws -> RelayEvent {
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw RelayError.invalidPayload("expected a JSON object")
        }

        guard let payload = object as? [String: Any] else {
            throw RelayError.invalidPayload("top-level JSON must be an object")
        }

        switch source {
        case .codex:
            return try decodeCodex(payload, receivedAt: receivedAt)
        case .claude:
            return try decodeClaude(payload, receivedAt: receivedAt)
        case .cursor:
            return try decodeGeneric(payload, source: .cursor, receivedAt: receivedAt)
        case .generic:
            return try decodeGeneric(payload, source: .generic, receivedAt: receivedAt)
        }
    }

    private static func decodeCodex(
        _ payload: [String: Any],
        receivedAt: Date
    ) throws -> RelayEvent {
        let sourceEvent = firstString(payload, keys: ["hook_event_name", "type", "event_type", "event"])
            ?? "unknown"
        let normalized = normalize(sourceEvent)
        let status: RelayStatus
        let summary: String

        switch normalized {
        case "sessionstart":
            status = .running
            summary = "Codex session started"
        case "sessionend":
            status = .ended
            summary = "Codex session ended"
        case "permissionrequest":
            status = .needsPermission
            if let tool = safeLabel(firstString(payload, keys: ["tool_name", "tool"])) {
                summary = "Codex requires permission for \(tool)"
            } else {
                summary = "Codex requires permission"
            }
        case "stop", "agentturncomplete":
            status = .readyToReview
            summary = "Codex result is ready to review"
        case "subagentstart":
            status = .running
            summary = "Codex subagent started"
        case "subagentstop":
            // Subagents share the parent session id in Codex hook payloads. Keep the
            // parent session running rather than incorrectly marking it complete.
            status = .running
            summary = "Codex subagent completed"
        case "posttoolusefailure", "toolfailure":
            status = .running
            summary = "Codex is handling a tool failure"
        case "pretooluse", "posttooluse", "userpromptsubmit":
            status = .running
            summary = "Codex is running"
        default:
            if let explicit = firstString(payload, keys: ["status"]),
               let parsed = RelayStatus(rawValue: explicit) {
                status = parsed
                summary = safeSummary(firstString(payload, keys: ["summary"]))
                    ?? defaultSummary(source: .codex, status: parsed)
            } else {
                throw RelayError.invalidPayload("unsupported Codex event \(sourceEvent)")
            }
        }

        let sessionID = try requiredSessionID(payload, source: .codex)
        return makeEvent(
            payload: payload,
            source: .codex,
            sourceEvent: sourceEvent,
            sessionID: sessionID,
            status: status,
            summary: summary,
            receivedAt: receivedAt
        )
    }

    private static func decodeClaude(
        _ payload: [String: Any],
        receivedAt: Date
    ) throws -> RelayEvent {
        let sourceEvent = firstString(payload, keys: ["hook_event_name", "event_type", "event", "type"])
            ?? "unknown"
        let normalized = normalize(sourceEvent)
        let status: RelayStatus
        let summary: String

        switch normalized {
        case "sessionstart":
            status = .running
            summary = "Claude session started"
        case "sessionend":
            status = .ended
            summary = "Claude session ended"
        case "permissionrequest":
            status = .needsPermission
            if let tool = safeLabel(firstString(payload, keys: ["tool_name", "tool"])) {
                summary = "Claude requires permission for \(tool)"
            } else {
                summary = "Claude requires permission"
            }
        case "notification":
            let notificationType = normalize(
                firstString(payload, keys: ["notification_type", "notificationType"]) ?? ""
            )
            switch notificationType {
            case "permissionprompt":
                status = .needsPermission
                summary = "Claude requires permission"
            case "idleprompt", "elicitationdialog", "elicitationurldialog", "agentneedsinput":
                status = .needsInput
                summary = "Claude is waiting for input"
            case "agentcompleted":
                status = .readyToReview
                summary = "Claude background result is ready to review"
            default:
                status = .running
                summary = "Claude sent an informational notification"
            }
        case "stop":
            status = .readyToReview
            summary = "Claude result is ready to review"
        case "stopfailure":
            status = .failed
            summary = "Claude turn failed"
        case "subagentstop":
            status = .running
            summary = "Claude subagent completed"
        case "posttoolusefailure", "toolfailure":
            status = .running
            summary = "Claude is handling a tool failure"
        case "pretooluse", "posttooluse", "userpromptsubmit":
            status = .running
            summary = "Claude is running"
        default:
            if let explicit = firstString(payload, keys: ["status"]),
               let parsed = RelayStatus(rawValue: explicit) {
                status = parsed
                summary = safeSummary(firstString(payload, keys: ["summary"]))
                    ?? defaultSummary(source: .claude, status: parsed)
            } else {
                throw RelayError.invalidPayload("unsupported Claude event \(sourceEvent)")
            }
        }

        let sessionID = try requiredSessionID(payload, source: .claude)
        return makeEvent(
            payload: payload,
            source: .claude,
            sourceEvent: sourceEvent,
            sessionID: sessionID,
            status: status,
            summary: summary,
            receivedAt: receivedAt
        )
    }

    private static func decodeGeneric(
        _ payload: [String: Any],
        source: AgentSource,
        receivedAt: Date
    ) throws -> RelayEvent {
        guard let rawStatus = firstString(payload, keys: ["status"]),
              let status = RelayStatus(rawValue: rawStatus) else {
            throw RelayError.invalidPayload("generic events require a supported status")
        }

        let sourceEvent = firstString(payload, keys: ["event_type", "event", "type"])
            ?? status.rawValue
        let sessionID = try requiredSessionID(payload, source: source)
        let summary = safeSummary(firstString(payload, keys: ["summary"]))
            ?? defaultSummary(source: source, status: status)

        return makeEvent(
            payload: payload,
            source: source,
            sourceEvent: sourceEvent,
            sessionID: sessionID,
            status: status,
            summary: summary,
            receivedAt: receivedAt
        )
    }

    private static func makeEvent(
        payload: [String: Any],
        source: AgentSource,
        sourceEvent: String,
        sessionID: String,
        status: RelayStatus,
        summary: String,
        receivedAt: Date
    ) -> RelayEvent {
        let cwd = safePath(firstString(payload, keys: ["cwd", "working_directory", "workingDirectory"]))
        let explicitProjectName = safeLabel(
            firstString(payload, keys: ["project_name", "projectName", "project"])
        )
        let derivedProjectName = cwd.map { URL(fileURLWithPath: $0).lastPathComponent }
        let occurredAt = parseDate(payload["occurred_at"] ?? payload["occurredAt"] ?? payload["timestamp"])
            ?? receivedAt

        return RelayEvent(
            source: source,
            sourceEvent: sourceEvent,
            sessionID: sessionID,
            turnID: safeIdentifier(firstString(payload, keys: ["turn_id", "turn-id", "turnId"])),
            status: status,
            project: ProjectContext(
                cwd: cwd,
                name: explicitProjectName ?? derivedProjectName,
                repository: safeLabel(firstString(payload, keys: ["repository", "repo"])),
                branch: safeLabel(firstString(payload, keys: ["branch"]))
            ),
            model: safeLabel(firstString(payload, keys: ["model"])),
            summary: summary,
            progress: structuredProgress(payload),
            completionEvidence: completionEvidence(payload),
            occurredAt: occurredAt,
            receivedAt: receivedAt
        )
    }

    private static func requiredSessionID(
        _ payload: [String: Any],
        source: AgentSource
    ) throws -> String {
        guard let raw = firstString(
            payload,
            keys: ["session_id", "session-id", "sessionId", "thread_id", "thread-id", "threadId"]
        ), let sessionID = safeIdentifier(raw), !sessionID.isEmpty else {
            throw RelayError.invalidPayload("\(source.rawValue) event is missing session_id")
        }
        return sessionID
    }

    private static func firstString(_ payload: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let value = payload[key] as? String {
                return value
            }
            if let value = payload[key] as? NSNumber {
                return value.stringValue
            }
        }
        return nil
    }

    private static func firstDouble(_ payload: [String: Any], keys: [String]) -> Double? {
        for key in keys {
            if let number = payload[key] as? NSNumber {
                return number.doubleValue
            }
            if let string = payload[key] as? String, let number = Double(string) {
                return number
            }
        }
        return nil
    }

    private static func structuredProgress(_ payload: [String: Any]) -> RelayProgress? {
        guard let completed = firstDouble(
            payload,
            keys: ["progress_completed", "progressCompleted"]
        ), let total = firstDouble(
            payload,
            keys: ["progress_total", "progressTotal"]
        ) else { return nil }
        return RelayProgress(
            completed: completed,
            total: total,
            unit: safeLabel(firstString(payload, keys: ["progress_unit", "progressUnit"]))
        )
    }

    private static func completionEvidence(_ payload: [String: Any]) -> CompletionEvidenceBundle? {
        guard let rawKind = firstString(payload, keys: ["evidence_kind", "evidenceKind"]),
              let kind = CompletionEvidenceKind(rawValue: rawKind),
              let summary = safeSummary(
                  firstString(payload, keys: ["evidence_summary", "evidenceSummary"])
              ) else { return nil }
        let evidence = CompletionEvidence(
            kind: kind,
            summary: summary,
            sourceID: safeIdentifier(
                firstString(payload, keys: ["evidence_id", "evidenceId"])
            )
        )
        return CompletionEvidenceBundle([evidence])
    }

    private static func normalize(_ value: String) -> String {
        value.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    private static func safeIdentifier(_ value: String?) -> String? {
        guard let value else { return nil }
        let cleanedScalars = value.unicodeScalars.filter { scalar in
            scalar.value >= 0x20 && scalar.value != 0x7F
        }
        let cleaned = cleanedScalars.map(String.init).joined()
        return cleaned.prefixString(256)
    }

    private static func safeLabel(_ value: String?) -> String? {
        guard let value else { return nil }
        let collapsed = value
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard !collapsed.isEmpty else { return nil }
        return collapsed.prefixString(120)
    }

    private static func safeSummary(_ value: String?) -> String? {
        guard let value else { return nil }
        let collapsed = value
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard !collapsed.isEmpty else { return nil }
        return collapsed.prefixString(240)
    }

    private static func safePath(_ value: String?) -> String? {
        guard let value, value.hasPrefix("/") else { return nil }
        return safeIdentifier(value)
    }

    private static func defaultSummary(source: AgentSource, status: RelayStatus) -> String {
        let name = source.rawValue.capitalized
        switch status {
        case .running:
            return "\(name) is running"
        case .needsInput:
            return "\(name) is waiting for input"
        case .needsPermission:
            return "\(name) requires permission"
        case .readyToReview:
            return "\(name) result is ready to review"
        case .failed:
            return "\(name) failed"
        case .completed:
            return "\(name) completed"
        case .cancelled:
            return "\(name) was cancelled"
        case .ended:
            return "\(name) session ended"
        }
    }

    private static func parseDate(_ value: Any?) -> Date? {
        if let number = value as? NSNumber {
            let raw = number.doubleValue
            return Date(timeIntervalSince1970: raw > 10_000_000_000 ? raw / 1_000 : raw)
        }
        guard let string = value as? String else { return nil }

        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: string) {
            return date
        }

        let standard = ISO8601DateFormatter()
        standard.formatOptions = [.withInternetDateTime]
        return standard.date(from: string)
    }
}

private extension String {
    func prefixString(_ limit: Int) -> String {
        String(prefix(limit))
    }
}
