import Foundation
import Testing
@testable import RelayCore

@Suite("Hook payload adapter")
struct HookPayloadAdapterTests {
    @Test
    func testCodexSessionStartIsNormalized() throws {
        let receivedAt = Date(timeIntervalSince1970: 1_700_000_100)
        let event = try decode(
            [
                "hook_event_name": "SessionStart",
                "session_id": "codex-session-1",
                "cwd": "/private/tmp/notch-relay-tests/my-project",
                "model": "gpt-test",
                "timestamp": "2023-11-14T22:13:20Z"
            ],
            source: .codex,
            receivedAt: receivedAt
        )

        #expect(event.source == .codex)
        #expect(event.sourceEvent == "SessionStart")
        #expect(event.sessionID == "codex-session-1")
        #expect(event.status == .running)
        #expect(event.attention == .silent)
        #expect(event.project.name == "my-project")
        #expect(event.model == "gpt-test")
        #expect(event.occurredAt == Date(timeIntervalSince1970: 1_700_000_000))
        #expect(event.receivedAt == receivedAt)
    }

    @Test
    func testCodexPermissionRequestDoesNotRetainSensitivePayloadFields() throws {
        let secret = "SUPER_SECRET_TOKEN_938475"
        let event = try decode(
            [
                "hook_event_name": "PermissionRequest",
                "session_id": "codex-session-2",
                "turn_id": "turn-7",
                "tool_name": "Bash",
                "tool_input": ["command": "curl -H Bearer_\(secret)"],
                "prompt": "read \(secret)",
                "transcript": "full transcript \(secret)",
                "transcript_path": "/private/\(secret)",
                "api_key": secret,
                "message": "permission message \(secret)"
            ],
            source: .codex
        )

        #expect(event.status == .needsPermission)
        #expect(event.summary == "Codex requires permission for Bash")
        #expect(event.turnID == "turn-7")

        let encoded = try RelayJSON.makeEncoder().encode(event)
        let encodedString = try #require(String(data: encoded, encoding: .utf8))
        #expect(!encodedString.contains(secret))
        #expect(!encodedString.contains("tool_input"))
        #expect(!encodedString.contains("prompt"))
        #expect(!encodedString.contains("transcript"))
        #expect(!encodedString.contains("api_key"))
    }

    @Test
    func testClaudeIdlePromptRequiresInput() throws {
        let event = try decode(
            [
                "hook_event_name": "Notification",
                "notification_type": "idle_prompt",
                "session_id": "claude-session-1"
            ],
            source: .claude
        )

        #expect(event.status == .needsInput)
        #expect(event.attention == .interrupt)
        #expect(event.summary == "Claude is waiting for input")
    }

    @Test
    func testClaudePermissionNotificationRequiresPermission() throws {
        let event = try decode(
            [
                "hook_event_name": "Notification",
                "notification_type": "permission_prompt",
                "session_id": "claude-session-2"
            ],
            source: .claude
        )

        #expect(event.status == .needsPermission)
        #expect(event.attention == .interrupt)
        #expect(event.summary == "Claude requires permission")
    }

    @Test
    func testStopFailureBecomesCriticalWithoutKeepingErrorDetails() throws {
        let secret = "PRIVATE_FAILURE_DETAIL_2849"
        let event = try decode(
            [
                "hook_event_name": "StopFailure",
                "session_id": "claude-session-3",
                "error": "request contained \(secret)",
                "tool_input": ["url": "https://example.test/\(secret)"]
            ],
            source: .claude
        )

        #expect(event.status == .failed)
        #expect(event.attention == .critical)
        #expect(event.summary == "Claude turn failed")
        let encoded = try RelayJSON.makeEncoder().encode(event)
        let encodedString = try #require(String(data: encoded, encoding: .utf8))
        #expect(!encodedString.contains(secret))
    }

    @Test
    func testRecoverableToolFailureDoesNotInterrupt() throws {
        let event = try decode(
            [
                "hook_event_name": "PostToolUseFailure",
                "session_id": "claude-session-4",
                "tool_name": "WebFetch"
            ],
            source: .claude
        )

        #expect(event.status == .running)
        #expect(event.attention == .silent)
    }

    @Test
    func testMillisecondsTimestampIsAccepted() throws {
        let event = try decode(
            [
                "event_type": "test",
                "session_id": "generic-1",
                "status": "completed",
                "evidence_kind": "test_passed",
                "evidence_summary": "Verified test suite passed",
                "timestamp": 1_700_000_000_500 as NSNumber
            ],
            source: .generic
        )

        #expect(abs(event.occurredAt.timeIntervalSince1970 - 1_700_000_000.5) < 0.001)
        #expect(event.effectiveStatus == .completed)
    }

    @Test
    func testStopBecomesReadyToReviewWithoutEvidence() throws {
        let codex = try decode(
            ["hook_event_name": "Stop", "session_id": "codex-review"],
            source: .codex
        )
        let claude = try decode(
            ["hook_event_name": "Stop", "session_id": "claude-review"],
            source: .claude
        )

        #expect(codex.status == .readyToReview)
        #expect(codex.effectiveStatus == .readyToReview)
        #expect(claude.status == .readyToReview)
        #expect(claude.effectiveStatus == .readyToReview)
    }

    @Test
    func testStructuredProgressRequiresNumeratorAndDenominator() throws {
        let trusted = try decode(
            [
                "event_type": "progress",
                "session_id": "progress-trusted",
                "status": "running",
                "progress_completed": 31,
                "progress_total": 50,
                "progress_unit": "checks"
            ],
            source: .generic
        )
        let untrusted = try decode(
            [
                "event_type": "progress",
                "session_id": "progress-untrusted",
                "status": "running",
                "progress_percent": 62
            ],
            source: .generic
        )

        #expect(trusted.progress?.percentage == 62)
        #expect(trusted.progress?.unit == "checks")
        #expect(untrusted.progress == nil)
    }

    @Test
    func testMissingSessionIDIsRejected() throws {
        #expect(throws: (any Error).self) {
            try decode(
                ["hook_event_name": "Stop"],
                source: .claude
            )
        }
    }

    private func decode(
        _ payload: [String: Any],
        source: AgentSource,
        receivedAt: Date = Date(timeIntervalSince1970: 1_700_000_010)
    ) throws -> RelayEvent {
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        return try HookPayloadAdapter.decode(data: data, source: source, receivedAt: receivedAt)
    }
}
