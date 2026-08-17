import Foundation

public struct LocalPythonVerificationSnapshot: Equatable, Sendable {
    public var testCount: Int
    public var headCommit: String?
    public var integrity: EvidenceIntegrity
    public var observedAt: Date

    public init(
        testCount: Int,
        headCommit: String?,
        integrity: EvidenceIntegrity,
        observedAt: Date
    ) {
        self.testCount = max(0, testCount)
        self.headCommit = headCommit
        self.integrity = integrity
        self.observedAt = observedAt
    }

    public var observations: [CompletionReviewEvidenceObservation] {
        guard testCount > 0 else { return [] }
        let binding: String
        let reference: String?
        if integrity == .complete, let headCommit {
            let shortCommit = String(headCommit.prefix(12)).lowercased()
            binding = "，绑定到干净的 Git 提交 \(shortCommit)"
            reference = "local-python-unittest:\(headCommit.lowercased())"
        } else {
            binding = "；工作区未干净绑定到单一 Git 提交"
            reference = nil
        }
        return [CompletionReviewEvidenceObservation(
            kind: .testPassed,
            source: EvidenceSource(kind: .tool, sourceID: "relay-local-python-unittest-v1"),
            summary: "Relay 观察到 \(testCount) 个本地 Python unittest 通过\(binding)。",
            reference: reference,
            observedAt: observedAt,
            dataLevel: .l1StructuredEvidence,
            integrity: integrity
        )]
    }
}

public struct LocalPythonVerificationEvidenceAdapter: Sendable {
    public var executableURL: URL
    public var timeout: TimeInterval
    public var maximumOutputBytes: Int

    public init(
        executableURL: URL = URL(fileURLWithPath: "/usr/bin/python3"),
        timeout: TimeInterval = 180,
        maximumOutputBytes: Int = 512 * 1_024
    ) {
        self.executableURL = executableURL
        self.timeout = min(max(1, timeout), 180)
        self.maximumOutputBytes = min(max(16 * 1_024, maximumOutputBytes), 512 * 1_024)
    }

    public static func supports(
        _ session: RelaySessionState,
        fileManager: FileManager = .default
    ) -> Bool {
        guard let cwd = session.project.cwd,
              cwd.hasPrefix("/"),
              !cwd.contains("\0") else { return false }
        let root = URL(fileURLWithPath: cwd, isDirectory: true)
        let tests = root.appendingPathComponent("tests", isDirectory: true)
        guard isDirectory(tests), !isSymbolicLink(tests) else { return false }
        return ["pyproject.toml", "setup.cfg", "setup.py"].contains { name in
            let marker = root.appendingPathComponent(name, isDirectory: false)
            return fileManager.fileExists(atPath: marker.path)
                && isRegularFile(marker)
                && !isSymbolicLink(marker)
        }
    }

    public func collect(
        for session: RelaySessionState,
        now: Date = Date(),
        fileManager: FileManager = .default
    ) async -> [CompletionReviewEvidenceObservation] {
        guard Self.supports(session, fileManager: fileManager),
              let cwd = session.project.cwd else { return [] }
        let git = GitCompletionEvidenceAdapter()
        let before = await git.snapshot(for: session, now: now)
        let temporaryRoot = fileManager.temporaryDirectory
            .appendingPathComponent("notch-relay-python-verification-\(UUID().uuidString)", isDirectory: true)
        do {
            try fileManager.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
        } catch {
            return []
        }
        defer { try? fileManager.removeItem(at: temporaryRoot) }

        do {
            let output = try await runTests(cwd: cwd, temporaryRoot: temporaryRoot)
            guard let testCount = Self.parseSuccessfulTestRun(output), testCount > 0 else {
                return []
            }
            let observedAt = Date()
            let after = await git.snapshot(for: session, now: observedAt)
            let cleanBinding = before?.isClean == true
                && after?.isClean == true
                && before?.headCommit.caseInsensitiveCompare(after?.headCommit ?? "") == .orderedSame
            return LocalPythonVerificationSnapshot(
                testCount: testCount,
                headCommit: cleanBinding ? after?.headCommit : nil,
                integrity: cleanBinding ? .complete : .partial,
                observedAt: observedAt
            ).observations
        } catch {
            return []
        }
    }

    func runTests(cwd: String, temporaryRoot: URL) async throws -> Data {
        let home = temporaryRoot.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let command = BoundedProcess(
            executableURL: executableURL,
            arguments: [
                "-I", "-B", "-m", "unittest", "discover",
                "-s", "tests", "-t", ".", "-p", "test*.py", "-q"
            ],
            maximumOutputBytes: maximumOutputBytes,
            environment: [
                "PATH": "/usr/bin:/bin",
                "LANG": "C",
                "LC_ALL": "C",
                "HOME": home.path,
                "TMPDIR": temporaryRoot.path,
                "PYTHONHASHSEED": "0",
                "PYTHONPYCACHEPREFIX": temporaryRoot.appendingPathComponent("pycache").path
            ],
            currentDirectoryURL: URL(fileURLWithPath: cwd, isDirectory: true),
            captureStandardError: true
        )
        return try await command.run(deadline: Date().addingTimeInterval(timeout))
    }

    static func parseSuccessfulTestRun(_ data: Data) -> Int? {
        guard data.count <= 512 * 1_024,
              let output = String(data: data, encoding: .utf8),
              let expression = try? NSRegularExpression(
                pattern: #"Ran ([0-9]+) tests? in [^\r\n]+[\r\n]+[\r\n]+OK(?:\s|$)"#
              ),
              let match = expression.firstMatch(
                in: output,
                range: NSRange(output.startIndex..., in: output)
              ),
              let range = Range(match.range(at: 1), in: output) else { return nil }
        return Int(output[range])
    }

    private static func isRegularFile(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
    }

    private static func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }

    private static func isSymbolicLink(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
    }
}
