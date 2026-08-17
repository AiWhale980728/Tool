import Foundation

public struct LocalSwiftVerificationSnapshot: Equatable, Sendable {
    public var testCount: Int
    public var suiteCount: Int?
    public var headCommit: String?
    public var integrity: EvidenceIntegrity
    public var observedAt: Date

    public init(
        testCount: Int,
        suiteCount: Int?,
        headCommit: String?,
        integrity: EvidenceIntegrity,
        observedAt: Date
    ) {
        self.testCount = max(0, testCount)
        self.suiteCount = suiteCount.map { max(0, $0) }
        self.headCommit = headCommit
        self.integrity = integrity
        self.observedAt = observedAt
    }

    public var observations: [CompletionReviewEvidenceObservation] {
        guard testCount > 0 else { return [] }
        let suiteText = suiteCount.map { "，共 \($0) 个测试套件" } ?? ""
        let binding: String
        let reference: String?
        if integrity == .complete, let headCommit {
            let shortCommit = String(headCommit.prefix(12)).lowercased()
            binding = "，绑定到干净的 Git 提交 \(shortCommit)"
            reference = "local-swift-verification:\(headCommit.lowercased())"
        } else {
            binding = "；工作区未干净绑定到单一 Git 提交"
            reference = nil
        }
        let source = EvidenceSource(kind: .tool, sourceID: "relay-local-swift-test-v1")
        let consentLevel = SupervisorDataLevel.l1StructuredEvidence
        return [
            CompletionReviewEvidenceObservation(
                kind: .testPassed,
                source: source,
                summary: "Relay 观察到 \(testCount) 个本地 Swift 测试通过\(suiteText)\(binding)。",
                reference: reference,
                observedAt: observedAt,
                dataLevel: consentLevel,
                integrity: integrity
            ),
            CompletionReviewEvidenceObservation(
                kind: .buildSucceeded,
                source: source,
                summary: "Relay 观察到本地 Swift 测试构建成功\(binding)。",
                reference: reference,
                observedAt: observedAt,
                dataLevel: consentLevel,
                integrity: integrity
            )
        ]
    }
}

public struct LocalSwiftVerificationEvidenceAdapter: Sendable {
    public var executableURL: URL
    public var timeout: TimeInterval
    public var maximumOutputBytes: Int

    public init(
        executableURL: URL = URL(fileURLWithPath: "/usr/bin/xcrun"),
        timeout: TimeInterval = 180,
        maximumOutputBytes: Int = 512 * 1_024
    ) {
        self.executableURL = executableURL
        self.timeout = min(max(1, timeout), 180)
        self.maximumOutputBytes = min(max(16 * 1_024, maximumOutputBytes), 512 * 1_024)
    }

    public static func supports(_ session: RelaySessionState) -> Bool {
        guard let cwd = session.project.cwd,
              cwd.hasPrefix("/"),
              !cwd.contains("\0") else { return false }
        let manifest = URL(fileURLWithPath: cwd, isDirectory: true)
            .appendingPathComponent("Package.swift", isDirectory: false)
        guard let values = try? manifest.resourceValues(forKeys: [
            .isRegularFileKey,
            .isSymbolicLinkKey
        ]) else { return false }
        return values.isRegularFile == true && values.isSymbolicLink != true
    }

    public func collect(
        for session: RelaySessionState,
        now: Date = Date(),
        fileManager: FileManager = .default
    ) async -> [CompletionReviewEvidenceObservation] {
        guard Self.supports(session), let cwd = session.project.cwd else { return [] }
        let git = GitCompletionEvidenceAdapter()
        let before = await git.snapshot(for: session, now: now)
        let temporaryRoot = fileManager.temporaryDirectory
            .appendingPathComponent("notch-relay-local-verification-\(UUID().uuidString)", isDirectory: true)
        do {
            try fileManager.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
        } catch {
            return []
        }
        defer { try? fileManager.removeItem(at: temporaryRoot) }

        do {
            let output = try await runTests(cwd: cwd, temporaryRoot: temporaryRoot)
            guard let counts = Self.parseSuccessfulTestRun(output), counts.tests > 0 else {
                return []
            }
            let observedAt = Date()
            let after = await git.snapshot(for: session, now: observedAt)
            let cleanBinding = before?.isClean == true
                && after?.isClean == true
                && before?.headCommit.caseInsensitiveCompare(after?.headCommit ?? "") == .orderedSame
            let snapshot = LocalSwiftVerificationSnapshot(
                testCount: counts.tests,
                suiteCount: counts.suites,
                headCommit: cleanBinding ? after?.headCommit : nil,
                integrity: cleanBinding ? .complete : .partial,
                observedAt: observedAt
            )
            return snapshot.observations
        } catch {
            return []
        }
    }

    func runTests(cwd: String, temporaryRoot: URL) async throws -> Data {
        let home = temporaryRoot.appendingPathComponent("home", isDirectory: true)
        let scratch = temporaryRoot.appendingPathComponent("build", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let command = BoundedProcess(
            executableURL: executableURL,
            arguments: [
                "swift", "test",
                "--package-path", cwd,
                "--scratch-path", scratch.path,
                "--disable-automatic-resolution"
            ],
            maximumOutputBytes: maximumOutputBytes,
            environment: [
                "PATH": "/usr/bin:/bin",
                "LANG": "C",
                "LC_ALL": "C",
                "HOME": home.path,
                "TMPDIR": temporaryRoot.path,
                "CLANG_MODULE_CACHE_PATH": temporaryRoot.appendingPathComponent("module-cache").path,
                "SWIFTPM_MODULECACHE_OVERRIDE": temporaryRoot.appendingPathComponent("module-cache").path
            ],
            currentDirectoryURL: URL(fileURLWithPath: cwd, isDirectory: true)
        )
        return try await command.run(deadline: Date().addingTimeInterval(timeout))
    }

    static func parseSuccessfulTestRun(_ data: Data) -> (tests: Int, suites: Int?)? {
        guard data.count <= 512 * 1_024,
              let output = String(data: data, encoding: .utf8) else { return nil }
        if let match = firstMatch(
            pattern: #"Test run with ([0-9]+) tests? in ([0-9]+) suites? passed"#,
            in: output
        ), let tests = Int(match[0]), let suites = Int(match[1]) {
            return (tests, suites)
        }
        if let match = firstMatch(
            pattern: #"Executed ([0-9]+) tests?, with 0 failures"#,
            in: output
        ), let tests = Int(match[0]) {
            return (tests, nil)
        }
        return nil
    }

    private static func firstMatch(pattern: String, in text: String) -> [String]? {
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(
                in: text,
                range: NSRange(text.startIndex..., in: text)
              ) else { return nil }
        return (1..<match.numberOfRanges).compactMap { index in
            guard let range = Range(match.range(at: index), in: text) else { return nil }
            return String(text[range])
        }
    }
}
