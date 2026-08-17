import Foundation

public struct LocalTaskMetadata: Equatable, Sendable {
    public var projectName: String?
    public var taskTitle: String?
    public var showsProjectPrefix: Bool

    public init(
        projectName: String? = nil,
        taskTitle: String? = nil,
        showsProjectPrefix: Bool = true
    ) {
        self.projectName = projectName
        self.taskTitle = taskTitle
        self.showsProjectPrefix = showsProjectPrefix
    }
}

public struct LocalTaskMetadataResolution: Equatable, Sendable {
    public var metadata: [String: LocalTaskMetadata]
    public var currentSessionKeys: Set<String>
    public var authoritativeCurrentSources: Set<AgentSource>
    public var processIDsBySessionKey: [String: Int32]

    public init(
        metadata: [String: LocalTaskMetadata] = [:],
        currentSessionKeys: Set<String> = [],
        authoritativeCurrentSources: Set<AgentSource> = [],
        processIDsBySessionKey: [String: Int32] = [:]
    ) {
        self.metadata = metadata
        self.currentSessionKeys = currentSessionKeys
        self.authoritativeCurrentSources = authoritativeCurrentSources
        self.processIDsBySessionKey = processIDsBySessionKey
    }
}

public enum LocalTaskPresentation {
    public static func meaningfulProjectName(_ value: String?) -> String? {
        guard let value else { return nil }
        let collapsed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !collapsed.isEmpty else { return nil }
        let genericNames = Set(["/", "tool"])
        guard !genericNames.contains(collapsed.lowercased()) else { return nil }
        return collapsed
    }

    public static func shouldDisplay(
        session: RelaySessionState,
        metadata: LocalTaskMetadata?,
        currentSessionKeys: Set<String> = [],
        authoritativeCurrentSources: Set<AgentSource> = []
    ) -> Bool {
        if authoritativeCurrentSources.contains(session.source) {
            return currentSessionKeys.contains(session.key)
        }

        guard session.source == .codex else { return true }
        if metadata?.taskTitle != nil { return true }

        switch session.status {
        case .needsInput, .needsPermission, .failed:
            return true
        case .running, .readyToReview, .completed, .cancelled, .ended:
            return false
        }
    }

    public static func displayTitle(
        session: RelaySessionState,
        metadata: LocalTaskMetadata?
    ) -> String {
        if let taskTitle = metadata?.taskTitle {
            return taskTitle
        }

        return switch session.status {
        case .needsPermission:
            "Task name unavailable · approval required"
        case .needsInput:
            "Task name unavailable · input required"
        case .failed:
            "Task name unavailable · failed"
        case .running, .readyToReview, .completed, .cancelled, .ended:
            "Task name unavailable"
        }
    }
}

public struct LocalTaskMetadataResolver: Sendable {
    public var codexSessionIndex: URL
    public var codexGlobalState: URL
    public var claudeSessionsDirectory: URL?

    public init(
        codexSessionIndex: URL,
        codexGlobalState: URL,
        claudeSessionsDirectory: URL? = nil
    ) {
        self.codexSessionIndex = codexSessionIndex.standardizedFileURL
        self.codexGlobalState = codexGlobalState.standardizedFileURL
        self.claudeSessionsDirectory = claudeSessionsDirectory?.standardizedFileURL
    }

    public static func defaults(fileManager: FileManager = .default) -> Self {
        let codexRoot = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex", isDirectory: true)
        return Self(
            codexSessionIndex: codexRoot.appendingPathComponent("session_index.jsonl"),
            codexGlobalState: codexRoot.appendingPathComponent(".codex-global-state.json"),
            claudeSessionsDirectory: fileManager.homeDirectoryForCurrentUser
                .appendingPathComponent(".claude", isDirectory: true)
                .appendingPathComponent("sessions", isDirectory: true)
        )
    }

    public func resolve(
        sessions: [RelaySessionState],
        fileManager: FileManager = .default
    ) -> [String: LocalTaskMetadata] {
        resolveSnapshot(sessions: sessions, fileManager: fileManager).metadata
    }

    public func resolveSnapshot(
        sessions: [RelaySessionState],
        fileManager: FileManager = .default
    ) -> LocalTaskMetadataResolution {
        let codexSessions = sessions.filter { $0.source == .codex }
        let wantedIDs = Set(codexSessions.map(\.sessionID))
        let titles = readCodexTitles(wantedIDs: wantedIDs, fileManager: fileManager)
        let projects = readCodexProjects(wantedIDs: wantedIDs, fileManager: fileManager)
        var metadata: [String: LocalTaskMetadata] = Dictionary(
            uniqueKeysWithValues: codexSessions.compactMap { session -> (String, LocalTaskMetadata)? in
            let metadata = LocalTaskMetadata(
                projectName: projects[session.sessionID],
                taskTitle: titles[session.sessionID]
            )
            guard metadata.projectName != nil || metadata.taskTitle != nil else { return nil }
            return (session.key, metadata)
            }
        )

        var currentSessionKeys = Set<String>()
        var authoritativeCurrentSources = Set<AgentSource>()
        var processIDsBySessionKey: [String: Int32] = [:]
        if let claudeSessionsDirectory,
           fileManager.fileExists(atPath: claudeSessionsDirectory.path) {
            authoritativeCurrentSources.insert(.claude)
            let claudeSessions = sessions.filter { $0.source == .claude }
            let relayByID = Dictionary(uniqueKeysWithValues: claudeSessions.map { ($0.sessionID, $0) })
            for entry in readClaudeSessions(directory: claudeSessionsDirectory, fileManager: fileManager) {
                guard entry.isCurrent,
                      let session = relayByID[entry.sessionID] else { continue }
                currentSessionKeys.insert(session.key)
                if let processID = entry.processID, processID > 0 {
                    processIDsBySessionKey[session.key] = processID
                }

                let explicitTitle = entry.nameSource == "derived"
                    ? nil
                    : Self.safeLabel(entry.name, limit: 120)
                let projectName = Self.safeProjectName(entry.cwd)
                let resolved = LocalTaskMetadata(
                    projectName: projectName,
                    taskTitle: explicitTitle,
                    showsProjectPrefix: false
                )
                if resolved.projectName != nil || resolved.taskTitle != nil {
                    metadata[session.key] = resolved
                }
            }
        }

        return LocalTaskMetadataResolution(
            metadata: metadata,
            currentSessionKeys: currentSessionKeys,
            authoritativeCurrentSources: authoritativeCurrentSources,
            processIDsBySessionKey: processIDsBySessionKey
        )
    }

    private func readClaudeSessions(
        directory: URL,
        fileManager: FileManager
    ) -> [ClaudeLocalSessionEntry] {
        guard let files = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        let decoder = JSONDecoder()
        return files
            .filter { $0.pathExtension.lowercased() == "json" }
            .compactMap { file in
                guard let data = try? Data(contentsOf: file) else { return nil }
                return try? decoder.decode(ClaudeLocalSessionEntry.self, from: data)
            }
    }

    private func readCodexTitles(
        wantedIDs: Set<String>,
        fileManager: FileManager
    ) -> [String: String] {
        guard fileManager.fileExists(atPath: codexSessionIndex.path),
              let data = try? Data(contentsOf: codexSessionIndex),
              let text = String(data: data, encoding: .utf8) else { return [:] }

        let decoder = JSONDecoder()
        var titles: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            guard let lineData = String(line).data(using: .utf8),
                  let entry = try? decoder.decode(CodexSessionIndexEntry.self, from: lineData),
                  wantedIDs.contains(entry.id),
                  let title = Self.safeLabel(entry.threadName, limit: 120) else { continue }
            titles[entry.id] = title
        }
        return titles
    }

    private func readCodexProjects(
        wantedIDs: Set<String>,
        fileManager: FileManager
    ) -> [String: String] {
        guard fileManager.fileExists(atPath: codexGlobalState.path),
              let data = try? Data(contentsOf: codexGlobalState),
              let state = try? JSONDecoder().decode(CodexGlobalState.self, from: data) else {
            return [:]
        }

        var result: [String: String] = [:]
        for sessionID in wantedIDs {
            guard let projectID = state.threadProjectAssignments?[sessionID]?.projectID,
                  let rawName = state.localProjects?[projectID]?.name,
                  let name = Self.safeLabel(rawName, limit: 80) else { continue }
            result[sessionID] = name
        }
        return result
    }

    private static func safeLabel(_ value: String?, limit: Int) -> String? {
        guard let value else { return nil }
        let printable = value.unicodeScalars.filter { $0.value >= 0x20 && $0.value != 0x7F }
        let collapsed = printable
            .map(String.init)
            .joined()
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard !collapsed.isEmpty else { return nil }
        return String(collapsed.prefix(limit))
    }

    private static func safeProjectName(_ path: String?) -> String? {
        guard let path = safeLabel(path, limit: 1_024), path.hasPrefix("/") else { return nil }
        return safeLabel(URL(fileURLWithPath: path).lastPathComponent, limit: 80)
    }
}

private struct ClaudeLocalSessionEntry: Decodable {
    var sessionID: String
    var name: String?
    var nameSource: String?
    var cwd: String?
    var status: String
    var processID: Int32?

    var isCurrent: Bool {
        status == "busy" || status == "idle" || status == "waiting"
    }

    private enum CodingKeys: String, CodingKey {
        case sessionID = "sessionId"
        case name
        case nameSource
        case cwd
        case status
        case processID = "pid"
    }
}

public enum TerminalTaskTitleParser {
    public static func taskTitle(from rawTitle: String) -> String? {
        let collapsed = rawTitle.unicodeScalars
            .filter { $0.value >= 0x20 && $0.value != 0x7F }
            .map(String.init)
            .joined()
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        let trimmed = collapsed.drop(while: { character in
            character.isWhitespace || (!character.isLetter && !character.isNumber)
        })
        guard !trimmed.isEmpty else { return nil }
        return String(trimmed.prefix(120))
    }
}

private struct CodexSessionIndexEntry: Decodable {
    var id: String
    var threadName: String

    private enum CodingKeys: String, CodingKey {
        case id
        case threadName = "thread_name"
    }
}

private struct CodexGlobalState: Decodable {
    var localProjects: [String: CodexLocalProject]?
    var threadProjectAssignments: [String: CodexThreadProjectAssignment]?

    private enum CodingKeys: String, CodingKey {
        case localProjects = "local-projects"
        case threadProjectAssignments = "thread-project-assignments"
    }
}

private struct CodexLocalProject: Decodable {
    var name: String
}

private struct CodexThreadProjectAssignment: Decodable {
    var projectID: String?

    private enum CodingKeys: String, CodingKey {
        case projectID = "projectId"
    }
}
