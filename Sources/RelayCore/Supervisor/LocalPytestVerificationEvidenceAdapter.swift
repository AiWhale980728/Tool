import Foundation

public struct LocalPytestVerificationSnapshot: Equatable, Sendable {
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
            reference = "local-pytest:\(headCommit.lowercased())"
        } else {
            binding = "；工作区未干净绑定到单一 Git 提交"
            reference = nil
        }
        return [CompletionReviewEvidenceObservation(
            kind: .testPassed,
            source: EvidenceSource(kind: .tool, sourceID: "relay-local-pytest-v1"),
            summary: "Relay 观察到 \(testCount) 个本地 pytest 测试通过\(binding)。",
            reference: reference,
            observedAt: observedAt,
            dataLevel: .l1StructuredEvidence,
            integrity: integrity
        )]
    }
}

public struct LocalPytestVerificationEvidenceAdapter: Sendable {
    static let maximumConfigurationBytes = 256 * 1_024
    static let maximumJUnitBytes = 512 * 1_024

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

        let pytestINI = root.appendingPathComponent("pytest.ini", isDirectory: false)
        if configuration(at: pytestINI, containsSection: "[pytest]", fileManager: fileManager) {
            return true
        }
        let pyproject = root.appendingPathComponent("pyproject.toml", isDirectory: false)
        return configuration(
            at: pyproject,
            containsSection: "[tool.pytest.ini_options]",
            fileManager: fileManager
        )
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
            .appendingPathComponent("notch-relay-pytest-verification-\(UUID().uuidString)", isDirectory: true)
        do {
            try fileManager.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
        } catch {
            return []
        }
        defer { try? fileManager.removeItem(at: temporaryRoot) }

        do {
            let report = try await runTests(cwd: cwd, temporaryRoot: temporaryRoot)
            guard let testCount = Self.parseSuccessfulJUnitReport(report), testCount > 0 else {
                return []
            }
            let observedAt = Date()
            let after = await git.snapshot(for: session, now: observedAt)
            let cleanBinding = before?.isClean == true
                && after?.isClean == true
                && before?.headCommit.caseInsensitiveCompare(after?.headCommit ?? "") == .orderedSame
            return LocalPytestVerificationSnapshot(
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
        let pytestConfiguration = temporaryRoot.appendingPathComponent("pytest.ini", isDirectory: false)
        let report = temporaryRoot.appendingPathComponent("pytest-junit.xml", isDirectory: false)
        let baseTemp = temporaryRoot.appendingPathComponent("pytest-temp", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try Data("""
        [pytest]
        addopts =
        junit_family = xunit2
        junit_logging = no
        junit_log_passing_tests = false
        """.utf8).write(to: pytestConfiguration, options: .atomic)

        let command = BoundedProcess(
            executableURL: executableURL,
            arguments: [
                "-I", "-B", "-m", "pytest",
                "-q", "--color=no", "--tb=no", "--disable-warnings",
                "-p", "no:cacheprovider",
                "-c", pytestConfiguration.path,
                "--rootdir", cwd,
                "--basetemp", baseTemp.path,
                "--junitxml", report.path,
                "tests"
            ],
            maximumOutputBytes: maximumOutputBytes,
            environment: [
                "PATH": "/usr/bin:/bin",
                "LANG": "C",
                "LC_ALL": "C",
                "HOME": home.path,
                "TMPDIR": temporaryRoot.path,
                "XDG_CACHE_HOME": temporaryRoot.appendingPathComponent("cache").path,
                "PYTHONHASHSEED": "0",
                "PYTHONPYCACHEPREFIX": temporaryRoot.appendingPathComponent("pycache").path,
                "PYTEST_DISABLE_PLUGIN_AUTOLOAD": "1"
            ],
            currentDirectoryURL: URL(fileURLWithPath: cwd, isDirectory: true),
            captureStandardError: true
        )
        _ = try await command.run(deadline: Date().addingTimeInterval(timeout))
        return try Self.readBoundedJUnitReport(at: report)
    }

    static func parseSuccessfulJUnitReport(_ data: Data) -> Int? {
        guard data.count <= maximumJUnitBytes, !data.isEmpty else { return nil }
        let delegate = PytestJUnitParserDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.shouldResolveExternalEntities = false
        guard parser.parse(), delegate.isValid, delegate.passedTestCount > 0 else { return nil }
        return delegate.passedTestCount
    }

    private static func readBoundedJUnitReport(at url: URL) throws -> Data {
        let values = try url.resourceValues(forKeys: [
            .fileSizeKey,
            .isRegularFileKey,
            .isSymbolicLinkKey
        ])
        guard values.isRegularFile == true,
              values.isSymbolicLink != true,
              let size = values.fileSize,
              size > 0,
              size <= maximumJUnitBytes else {
            throw LocalPytestVerificationError.invalidReport
        }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard data.count == size else { throw LocalPytestVerificationError.invalidReport }
        return data
    }

    private static func configuration(
        at url: URL,
        containsSection section: String,
        fileManager: FileManager
    ) -> Bool {
        guard fileManager.fileExists(atPath: url.path),
              isRegularFile(url),
              !isSymbolicLink(url),
              let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
              let size = values.fileSize,
              size > 0,
              size <= maximumConfigurationBytes,
              let data = try? Data(contentsOf: url, options: .mappedIfSafe),
              data.count == size,
              let text = String(data: data, encoding: .utf8),
              !text.contains("\0") else { return false }
        return text.split(whereSeparator: \Character.isNewline).contains { line in
            let withoutComment = line.split(separator: "#", maxSplits: 1).first ?? line[...]
            return withoutComment.trimmingCharacters(in: .whitespaces) == section
        }
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

private enum LocalPytestVerificationError: Error {
    case invalidReport
}

private final class PytestJUnitParserDelegate: NSObject, XMLParserDelegate {
    private(set) var isValid = true
    private(set) var passedTestCount = 0
    private var depth = 0
    private var rootElement: String?
    private var suiteCount = 0

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        depth += 1
        if depth == 1 {
            guard elementName == "testsuites" || elementName == "testsuite" else {
                isValid = false
                parser.abortParsing()
                return
            }
            rootElement = elementName
        }

        let isSuite = elementName == "testsuite"
            && ((rootElement == "testsuite" && depth == 1)
                || (rootElement == "testsuites" && depth == 2))
        guard isSuite else { return }
        guard let tests = boundedInteger(attributeDict["tests"]),
              let failures = boundedInteger(attributeDict["failures"]),
              let errors = boundedInteger(attributeDict["errors"]),
              let skipped = boundedInteger(attributeDict["skipped"]),
              failures == 0,
              errors == 0,
              failures + errors + skipped <= tests else {
            isValid = false
            parser.abortParsing()
            return
        }
        suiteCount += 1
        passedTestCount += tests - failures - errors - skipped
        if suiteCount > 1_000 || passedTestCount > 1_000_000 {
            isValid = false
            parser.abortParsing()
        }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        depth -= 1
        if depth < 0 {
            isValid = false
            parser.abortParsing()
        }
    }

    func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) {
        isValid = false
    }

    func parser(
        _ parser: XMLParser,
        resolveExternalEntityName name: String,
        systemID: String?
    ) -> Data? {
        isValid = false
        parser.abortParsing()
        return nil
    }

    private func boundedInteger(_ value: String?) -> Int? {
        guard let value,
              !value.isEmpty,
              value.utf8.allSatisfy({ (0x30...0x39).contains($0) }),
              let parsed = Int(value),
              parsed <= 1_000_000 else { return nil }
        return parsed
    }
}
