import Foundation

public struct GitHubCISnapshot: Equatable, Sendable {
    public var headCommit: String
    public var successfulCheckCount: Int
    public var failedCheckCount: Int
    public var pendingCheckCount: Int
    public var observedAt: Date

    public init(
        headCommit: String,
        successfulCheckCount: Int,
        failedCheckCount: Int,
        pendingCheckCount: Int,
        observedAt: Date
    ) {
        self.headCommit = headCommit
        self.successfulCheckCount = max(0, successfulCheckCount)
        self.failedCheckCount = max(0, failedCheckCount)
        self.pendingCheckCount = max(0, pendingCheckCount)
        self.observedAt = observedAt
    }

    public func observation(
        expectedHeadCommit: String?
    ) -> CompletionReviewEvidenceObservation {
        let matchesLocalHead = expectedHeadCommit.map {
            $0.caseInsensitiveCompare(headCommit) == .orderedSame
        }
        let integrity: EvidenceIntegrity
        if matchesLocalHead == true {
            integrity = .complete
        } else if matchesLocalHead == false {
            integrity = .conflicting
        } else {
            integrity = .unverifiable
        }

        let kind: EvidenceKind
        if failedCheckCount > 0 {
            kind = .ciChecksFailed
        } else if pendingCheckCount > 0 || successfulCheckCount == 0 {
            kind = .ciChecksIncomplete
        } else {
            kind = .ciChecksPassed
        }
        let head = String(headCommit.prefix(12)).lowercased()
        let binding: String
        switch matchesLocalHead {
        case true: binding = "与本地 Git 提交匹配"
        case false: binding = "与本地 Git 提交冲突"
        case nil: binding = "没有本地验证的提交绑定"
        }
        let summary = "GitHub 独立报告提交 \(head) 的 CI，\(binding)：\(successfulCheckCount) 项成功、\(failedCheckCount) 项失败、\(pendingCheckCount) 项等待。"
        return CompletionReviewEvidenceObservation(
            kind: kind,
            source: EvidenceSource(kind: .tool, sourceID: "github-cli-readonly-v1"),
            summary: summary,
            reference: "github-checks:\(headCommit.lowercased())",
            observedAt: observedAt,
            dataLevel: .l1StructuredEvidence,
            integrity: integrity
        )
    }

}

public struct GitHubCICompletionEvidenceAdapter: Sendable {
    public var executableURL: URL?
    public var timeout: TimeInterval
    public var maximumOutputBytes: Int

    public init(
        executableURL: URL? = nil,
        timeout: TimeInterval = 5,
        maximumOutputBytes: Int = 128 * 1_024
    ) {
        self.executableURL = executableURL ?? Self.defaultExecutableURL()
        self.timeout = max(0.1, timeout)
        self.maximumOutputBytes = max(1_024, maximumOutputBytes)
    }

    public func collect(
        for session: RelaySessionState,
        expectedHeadCommit: String?,
        now: Date = Date()
    ) async -> [CompletionReviewEvidenceObservation] {
        guard let executableURL,
              let cwd = session.project.cwd,
              cwd.hasPrefix("/"),
              !cwd.contains("\0") else { return [] }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: cwd, isDirectory: &isDirectory),
              isDirectory.boolValue else { return [] }

        do {
            let snapshot = try await readSnapshot(
                executableURL: executableURL,
                cwd: cwd,
                now: now
            )
            return [snapshot.observation(expectedHeadCommit: expectedHeadCommit)]
        } catch {
            return []
        }
    }

    private func readSnapshot(
        executableURL: URL,
        cwd: String,
        now: Date
    ) async throws -> GitHubCISnapshot {
        var environment = [
            "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin",
            "LANG": "C",
            "LC_ALL": "C",
            "GH_PROMPT_DISABLED": "1",
            "GH_NO_UPDATE_NOTIFIER": "1",
            "GIT_TERMINAL_PROMPT": "0"
        ]
        let inherited = ProcessInfo.processInfo.environment
        if let home = inherited["HOME"] { environment["HOME"] = home }
        if let config = inherited["XDG_CONFIG_HOME"] { environment["XDG_CONFIG_HOME"] = config }
        let command = BoundedProcess(
            executableURL: executableURL,
            arguments: ["pr", "view", "--json", "headRefOid,statusCheckRollup"],
            maximumOutputBytes: maximumOutputBytes,
            environment: environment,
            currentDirectoryURL: URL(fileURLWithPath: cwd, isDirectory: true)
        )
        let data = try await command.run(deadline: Date().addingTimeInterval(timeout))
        return try Self.decodeSnapshot(data, now: now)
    }

    static func decodeSnapshot(_ data: Data, now: Date) throws -> GitHubCISnapshot {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let head = object["headRefOid"] as? String,
              Self.isCommitIdentifier(head),
              let checks = object["statusCheckRollup"] as? [[String: Any]] else {
            throw GitHubCIEvidenceError.invalidOutput
        }
        var successful = 0
        var failed = 0
        var pending = 0
        for check in checks {
            let conclusion = (check["conclusion"] as? String)?.uppercased()
            let state = (check["state"] as? String)?.uppercased()
            let status = (check["status"] as? String)?.uppercased()
            let value = conclusion ?? state
            if ["SUCCESS", "NEUTRAL", "SKIPPED"].contains(value) {
                successful += 1
            } else if [
                "FAILURE", "ERROR", "TIMED_OUT", "CANCELLED", "ACTION_REQUIRED",
                "STARTUP_FAILURE"
            ].contains(value) {
                failed += 1
            } else if status != "COMPLETED" || value == nil || value == "PENDING" {
                pending += 1
            } else {
                pending += 1
            }
        }
        return GitHubCISnapshot(
            headCommit: head,
            successfulCheckCount: successful,
            failedCheckCount: failed,
            pendingCheckCount: pending,
            observedAt: now
        )
    }

    private static func defaultExecutableURL(fileManager: FileManager = .default) -> URL? {
        ["/opt/homebrew/bin/gh", "/usr/local/bin/gh", "/usr/bin/gh"]
            .map { URL(fileURLWithPath: $0) }
            .first { fileManager.isExecutableFile(atPath: $0.path) }
    }

    private static func isCommitIdentifier(_ value: String) -> Bool {
        (40...64).contains(value.count)
            && value.utf8.allSatisfy {
                (0x30...0x39).contains($0) || (0x61...0x66).contains($0) || (0x41...0x46).contains($0)
            }
    }
}

private enum GitHubCIEvidenceError: Error {
    case invalidOutput
}
