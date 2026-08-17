import Foundation
import Testing
@testable import RelayCore

@Suite("Local task metadata")
struct LocalTaskMetadataTests {
    @Test
    func testCodexProjectAndThreadTitleAreResolvedByExactSessionID() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let index = root.appendingPathComponent("session_index.jsonl")
        let global = root.appendingPathComponent("global.json")
        try Data(
            """
            {"id":"wanted","thread_name":"完善小说影视化评估方案","ignored":"private"}
            {"id":"other","thread_name":"Do not read me"}
            """.utf8
        ).write(to: index)
        try Data(
            """
            {
              "local-projects": {
                "project-1": {"name": "影视化", "rootPaths": ["/private/path"]}
              },
              "thread-project-assignments": {
                "wanted": {"projectId": "project-1", "cwd": "/private/path"}
              },
              "credential-shaped-field": "must be ignored"
            }
            """.utf8
        ).write(to: global)

        let session = RelaySessionState(event: RelayEvent(
            source: .codex,
            sourceEvent: "Stop",
            sessionID: "wanted",
            status: .readyToReview,
            summary: "Codex result is ready to review"
        ))
        let metadata = LocalTaskMetadataResolver(
            codexSessionIndex: index,
            codexGlobalState: global
        ).resolve(sessions: [session])

        #expect(metadata[session.key] == LocalTaskMetadata(
            projectName: "影视化",
            taskTitle: "完善小说影视化评估方案"
        ))
        #expect(metadata.count == 1)
    }

    @Test
    func testMissingOrNonCodexMetadataDoesNotInventATitle() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = RelaySessionState(event: RelayEvent(
            source: .claude,
            sourceEvent: "Stop",
            sessionID: "claude-session",
            status: .readyToReview,
            summary: "Claude result is ready to review"
        ))

        let metadata = LocalTaskMetadataResolver(
            codexSessionIndex: root.appendingPathComponent("missing-index"),
            codexGlobalState: root.appendingPathComponent("missing-global")
        ).resolve(sessions: [session])

        #expect(metadata.isEmpty)
    }

    @Test
    func testClaudeSessionRegistryDefinesCurrentTasksWithoutReadingTranscripts() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let sessionsDirectory = root.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionsDirectory, withIntermediateDirectories: true)
        try Data(
            """
            {
              "sessionId": "current-custom",
              "name": "撰写小组项目立项报告",
              "nameSource": "custom",
              "cwd": "/Users/example/group-project",
              "pid": 101,
              "status": "busy",
              "ignoredPrivateField": "must not be decoded"
            }
            """.utf8
        ).write(to: sessionsDirectory.appendingPathComponent("101.json"))
        try Data(
            """
            {
              "sessionId": "current-derived",
              "name": "group-project-57",
              "nameSource": "derived",
              "cwd": "/Users/example/group-project",
              "pid": 102,
              "status": "idle"
            }
            """.utf8
        ).write(to: sessionsDirectory.appendingPathComponent("102.json"))
        try Data(
            """
            {
              "sessionId": "current-waiting",
              "name": "等待权限确认",
              "nameSource": "custom",
              "cwd": "/Users/example/group-project",
              "pid": 103,
              "status": "waiting"
            }
            """.utf8
        ).write(to: sessionsDirectory.appendingPathComponent("103.json"))
        try Data(
            """
            {
              "sessionId": "closed",
              "name": "Old validation",
              "nameSource": "custom",
              "cwd": "/private/tmp/validation",
              "status": "ended"
            }
            """.utf8
        ).write(to: sessionsDirectory.appendingPathComponent("104.json"))

        let relaySessions = [
            makeSession(source: .claude, sessionID: "current-custom", status: .needsInput),
            makeSession(source: .claude, sessionID: "current-derived", status: .running),
            makeSession(source: .claude, sessionID: "current-waiting", status: .needsPermission),
            makeSession(source: .claude, sessionID: "closed", status: .completed),
            makeSession(source: .claude, sessionID: "historical-validation", status: .failed)
        ]
        let resolution = LocalTaskMetadataResolver(
            codexSessionIndex: root.appendingPathComponent("missing-index"),
            codexGlobalState: root.appendingPathComponent("missing-global"),
            claudeSessionsDirectory: sessionsDirectory
        ).resolveSnapshot(sessions: relaySessions)

        #expect(resolution.authoritativeCurrentSources == [.claude])
        #expect(resolution.currentSessionKeys == [
            "claude:current-custom",
            "claude:current-derived",
            "claude:current-waiting"
        ])
        #expect(resolution.metadata["claude:current-custom"] == LocalTaskMetadata(
            projectName: "group-project",
            taskTitle: "撰写小组项目立项报告",
            showsProjectPrefix: false
        ))
        #expect(resolution.metadata["claude:current-derived"] == LocalTaskMetadata(
            projectName: "group-project",
            taskTitle: nil,
            showsProjectPrefix: false
        ))
        #expect(resolution.metadata["claude:current-waiting"] == LocalTaskMetadata(
            projectName: "group-project",
            taskTitle: "等待权限确认",
            showsProjectPrefix: false
        ))
        #expect(resolution.processIDsBySessionKey == [
            "claude:current-custom": 101,
            "claude:current-derived": 102,
            "claude:current-waiting": 103
        ])
        #expect(LocalTaskPresentation.shouldDisplay(
            session: relaySessions[2],
            metadata: resolution.metadata[relaySessions[2].key],
            currentSessionKeys: resolution.currentSessionKeys,
            authoritativeCurrentSources: resolution.authoritativeCurrentSources
        ))
        #expect(!LocalTaskPresentation.shouldDisplay(
            session: relaySessions[3],
            metadata: resolution.metadata[relaySessions[3].key],
            currentSessionKeys: resolution.currentSessionKeys,
            authoritativeCurrentSources: resolution.authoritativeCurrentSources
        ))
        #expect(!LocalTaskPresentation.shouldDisplay(
            session: relaySessions[4],
            metadata: nil,
            currentSessionKeys: resolution.currentSessionKeys,
            authoritativeCurrentSources: resolution.authoritativeCurrentSources
        ))
    }

    @Test
    func testTerminalTaskTitleParserRemovesClaudeActivityMarkerAndBoundsOutput() {
        #expect(
            TerminalTaskTitleParser.taskTitle(from: "✳ 撰写小组项目立项报告")
                == "撰写小组项目立项报告"
        )
        #expect(
            TerminalTaskTitleParser.taskTitle(from: "  ·  用飞书CLI写入设计报告文档  ")
                == "用飞书CLI写入设计报告文档"
        )
        #expect(
            TerminalTaskTitleParser.taskTitle(from: "⠐ 撰写小组项目立项报告")
                == "撰写小组项目立项报告"
        )
        #expect(TerminalTaskTitleParser.taskTitle(from: "✳   ") == nil)
        #expect(TerminalTaskTitleParser.taskTitle(from: String(repeating: "a", count: 140))?.count == 120)
    }

    @Test
    func testUntitledHistoricalCodexRowsAreHiddenWithoutHidingLiveAttention() {
        let untitledReview = makeSession(
            source: .codex,
            sessionID: "review",
            status: .readyToReview
        )
        let titledReview = makeSession(
            source: .codex,
            sessionID: "titled",
            status: .readyToReview
        )
        let permission = makeSession(
            source: .codex,
            sessionID: "permission",
            status: .needsPermission
        )
        let untitledRunning = makeSession(
            source: .codex,
            sessionID: "running",
            status: .running
        )
        let claudeReview = makeSession(
            source: .claude,
            sessionID: "claude",
            status: .readyToReview
        )

        #expect(!LocalTaskPresentation.shouldDisplay(
            session: untitledReview,
            metadata: LocalTaskMetadata(projectName: "tool")
        ))
        #expect(LocalTaskPresentation.shouldDisplay(
            session: titledReview,
            metadata: LocalTaskMetadata(projectName: "tool", taskTitle: "测试链路")
        ))
        #expect(LocalTaskPresentation.shouldDisplay(
            session: permission,
            metadata: LocalTaskMetadata(projectName: "/")
        ))
        #expect(!LocalTaskPresentation.shouldDisplay(
            session: untitledRunning,
            metadata: LocalTaskMetadata(projectName: "tool")
        ))
        #expect(LocalTaskPresentation.shouldDisplay(
            session: claudeReview,
            metadata: nil
        ))
    }

    @Test
    func testGenericContainerNamesAreNotPresentedAsProjects() {
        #expect(LocalTaskPresentation.meaningfulProjectName("tool") == nil)
        #expect(LocalTaskPresentation.meaningfulProjectName("/") == nil)
        #expect(LocalTaskPresentation.meaningfulProjectName("  tool  ") == nil)
        #expect(LocalTaskPresentation.meaningfulProjectName("QuietLens") == "QuietLens")
    }

    @Test
    func testDisplayTitleUsesOnlyTheActualTaskNameWithoutProjectPrefix() {
        let session = makeSession(
            source: .codex,
            sessionID: "title-only",
            status: .running
        )

        #expect(LocalTaskPresentation.displayTitle(
            session: session,
            metadata: LocalTaskMetadata(
                projectName: "tool",
                taskTitle: "修改 Notch Relay"
            )
        ) == "修改 Notch Relay")

        #expect(LocalTaskPresentation.displayTitle(
            session: session,
            metadata: LocalTaskMetadata(
                projectName: "passage",
                taskTitle: "调研 DeepSeek Harness 并策划文章"
            )
        ) == "调研 DeepSeek Harness 并策划文章")
    }

    @Test
    func testMissingBlockingTaskTitleUsesTruthfulFallbackWithoutProjectName() {
        let permission = makeSession(
            source: .codex,
            sessionID: "untitled-permission",
            status: .needsPermission
        )

        let title = LocalTaskPresentation.displayTitle(
            session: permission,
            metadata: LocalTaskMetadata(projectName: "tool")
        )
        #expect(title == "Task name unavailable · approval required")
        #expect(!title.contains("tool"))
        #expect(!title.contains("/"))
    }

    private func makeSession(
        source: AgentSource,
        sessionID: String,
        status: RelayStatus
    ) -> RelaySessionState {
        RelaySessionState(event: RelayEvent(
            source: source,
            sourceEvent: "test",
            sessionID: sessionID,
            status: status,
            summary: "Fixed test summary"
        ))
    }

    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("notch-relay-task-metadata-\(UUID().uuidString)")
    }
}
