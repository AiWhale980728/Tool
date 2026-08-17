import Foundation

public struct LocalCargoNextestVerificationSnapshot: Equatable, Sendable {
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
            reference = "local-cargo-nextest:\(headCommit.lowercased())"
        } else {
            binding = "；工作区未干净绑定到单一 Git 提交"
            reference = nil
        }
        return [CompletionReviewEvidenceObservation(
            kind: .testPassed,
            source: EvidenceSource(kind: .tool, sourceID: "relay-local-cargo-nextest-v1"),
            summary: "Relay 观察到 \(testCount) 个本地 Cargo nextest 测试通过\(binding)。",
            reference: reference,
            observedAt: observedAt,
            dataLevel: .l1StructuredEvidence,
            integrity: integrity
        )]
    }
}

public struct LocalCargoNextestVerificationEvidenceAdapter: Sendable {
    static let supportedNextestVersion = "0.9.143"
    static let maximumManifestBytes = 256 * 1_024
    static let maximumLockfileBytes = 4 * 1_024 * 1_024
    static let maximumJUnitBytes = 512 * 1_024

    public var cargoExecutableURL: URL?
    public var nextestExecutableURL: URL?
    public var timeout: TimeInterval
    public var maximumOutputBytes: Int

    public init(
        cargoExecutableURL: URL? = nil,
        nextestExecutableURL: URL? = nil,
        timeout: TimeInterval = 180,
        maximumOutputBytes: Int = 512 * 1_024
    ) {
        self.cargoExecutableURL = cargoExecutableURL
        self.nextestExecutableURL = nextestExecutableURL
        self.timeout = min(max(1, timeout), 180)
        self.maximumOutputBytes = min(max(16 * 1_024, maximumOutputBytes), 512 * 1_024)
    }

    public static func supports(
        _ session: RelaySessionState,
        cargoExecutableURL: URL? = nil,
        nextestExecutableURL: URL? = nil,
        fileManager: FileManager = .default
    ) -> Bool {
        guard resolvedExecutable(
            override: cargoExecutableURL,
            trustedNames: ["cargo"],
            fileManager: fileManager
        ) != nil,
        resolvedExecutable(
            override: nextestExecutableURL,
            trustedNames: ["cargo-nextest"],
            fileManager: fileManager
        ) != nil else { return false }
        return hasBoundedCargoProject(session)
    }

    public func collect(
        for session: RelaySessionState,
        now: Date = Date(),
        fileManager: FileManager = .default
    ) async -> [CompletionReviewEvidenceObservation] {
        guard let cwd = session.project.cwd,
              Self.hasBoundedCargoProject(session),
              let cargo = Self.resolvedExecutable(
                  override: cargoExecutableURL,
                  trustedNames: ["cargo"],
                  fileManager: fileManager
              ),
              let nextest = Self.resolvedExecutable(
                  override: nextestExecutableURL,
                  trustedNames: ["cargo-nextest"],
                  fileManager: fileManager
              ),
              await validatesReviewedVersion(nextest: nextest) else {
            return []
        }

        let git = GitCompletionEvidenceAdapter()
        let before = await git.snapshot(for: session, now: now)
        let temporaryRoot = fileManager.temporaryDirectory
            .appendingPathComponent("notch-relay-cargo-nextest-verification-\(UUID().uuidString)", isDirectory: true)
        do {
            try fileManager.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
        } catch {
            return []
        }
        defer { try? fileManager.removeItem(at: temporaryRoot) }

        do {
            let report = try await runTests(
                cargo: cargo,
                nextest: nextest,
                cwd: cwd,
                temporaryRoot: temporaryRoot,
                fileManager: fileManager
            )
            guard let testCount = Self.parseSuccessfulJUnitReport(report), testCount > 0 else {
                return []
            }
            let observedAt = Date()
            let after = await git.snapshot(for: session, now: observedAt)
            let cleanBinding = before?.isClean == true
                && after?.isClean == true
                && before?.headCommit.caseInsensitiveCompare(after?.headCommit ?? "") == .orderedSame
            return LocalCargoNextestVerificationSnapshot(
                testCount: testCount,
                headCommit: cleanBinding ? after?.headCommit : nil,
                integrity: cleanBinding ? .complete : .partial,
                observedAt: observedAt
            ).observations
        } catch {
            return []
        }
    }

    func validatesReviewedVersion(nextest: URL) async -> Bool {
        let command = BoundedProcess(
            executableURL: nextest,
            arguments: ["nextest", "--version"],
            maximumOutputBytes: 16 * 1_024,
            environment: Self.baseEnvironment(temporaryRoot: FileManager.default.temporaryDirectory),
            captureStandardError: true
        )
        guard let output = try? await command.run(deadline: Date().addingTimeInterval(5)) else {
            return false
        }
        return Self.parseReviewedVersion(output)
    }

    func runTests(
        cargo: URL,
        nextest: URL,
        cwd: String,
        temporaryRoot: URL,
        fileManager: FileManager
    ) async throws -> Data {
        let home = temporaryRoot.appendingPathComponent("home", isDirectory: true)
        let cargoHome = temporaryRoot.appendingPathComponent("cargo-home", isDirectory: true)
        let target = temporaryRoot.appendingPathComponent("target", isDirectory: true)
        let report = temporaryRoot.appendingPathComponent("nextest-junit.xml", isDirectory: false)
        let configuration = temporaryRoot.appendingPathComponent("nextest.toml", isDirectory: false)
        try fileManager.createDirectory(at: home, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: cargoHome, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: target, withIntermediateDirectories: true)
        guard Self.isSafeTOMLPath(report.path) else {
            throw LocalCargoNextestVerificationError.invalidPath
        }
        try Data("""
        [profile.relay]
        retries = 0
        fail-fast = false
        test-threads = 1

        [profile.relay.junit]
        path = "\(report.path)"
        store-success-output = false
        store-failure-output = false
        report-skipped = "none"
        """.utf8).write(to: configuration, options: .atomic)

        var environment = Self.baseEnvironment(temporaryRoot: temporaryRoot)
        environment["HOME"] = home.path
        environment["CARGO"] = cargo.path
        environment["CARGO_HOME"] = cargoHome.path
        environment["CARGO_NET_OFFLINE"] = "true"
        environment["CARGO_TERM_COLOR"] = "never"
        environment["NEXTEST_HIDE_PROGRESS_BAR"] = "1"
        environment["NEXTEST_NO_TESTS"] = "fail"
        environment["RUST_BACKTRACE"] = "0"
        let rustupHome = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".rustup", isDirectory: true)
        if Self.isDirectory(rustupHome), !Self.isSymbolicLink(rustupHome) {
            environment["RUSTUP_HOME"] = rustupHome.path
        }

        let command = BoundedProcess(
            executableURL: nextest,
            arguments: [
                "nextest",
                "--no-pager",
                "--color", "never",
                "run",
                "--config-file", configuration.path,
                "--profile", "relay",
                "--offline",
                "--locked",
                "--target-dir", target.path,
                "--test-threads", "1",
                "--retries", "0",
                "--flaky-result", "fail",
                "--no-fail-fast",
                "--no-tests", "fail",
                "--show-progress", "none",
                "--status-level", "none",
                "--final-status-level", "none",
                "--success-output", "never",
                "--failure-output", "never"
            ],
            maximumOutputBytes: maximumOutputBytes,
            environment: environment,
            currentDirectoryURL: URL(fileURLWithPath: cwd, isDirectory: true),
            captureStandardError: true
        )
        _ = try await command.run(deadline: Date().addingTimeInterval(timeout))
        return try Self.readBoundedJUnitReport(at: report)
    }

    static func parseReviewedVersion(_ data: Data) -> Bool {
        guard data.count <= 16 * 1_024,
              let output = String(data: data, encoding: .utf8) else { return false }
        let line = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard line.hasPrefix("cargo-nextest \(supportedNextestVersion)") else { return false }
        let suffix = line.dropFirst("cargo-nextest \(supportedNextestVersion)".count)
        return suffix.isEmpty || (suffix.first == " " && suffix.hasPrefix(" (") && suffix.last == ")")
    }

    static func parseSuccessfulJUnitReport(_ data: Data) -> Int? {
        guard !data.isEmpty, data.count <= maximumJUnitBytes else { return nil }
        let delegate = NextestJUnitParserDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.shouldResolveExternalEntities = false
        guard parser.parse(), delegate.isValid, delegate.passedTestCount > 0 else { return nil }
        return delegate.passedTestCount
    }

    private static func hasBoundedCargoProject(_ session: RelaySessionState) -> Bool {
        guard let cwd = session.project.cwd,
              cwd.hasPrefix("/"),
              !cwd.contains("\0") else { return false }
        let root = URL(fileURLWithPath: cwd, isDirectory: true)
        return isBoundedRegularFile(
            root.appendingPathComponent("Cargo.toml", isDirectory: false),
            maximumBytes: maximumManifestBytes
        ) && isBoundedRegularFile(
            root.appendingPathComponent("Cargo.lock", isDirectory: false),
            maximumBytes: maximumLockfileBytes
        )
    }

    private static func resolvedExecutable(
        override: URL?,
        trustedNames: [String],
        fileManager: FileManager
    ) -> URL? {
        if let override {
            return isExecutableRegularFile(override, fileManager: fileManager) ? override : nil
        }
        let homeBin = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(".cargo/bin", isDirectory: true)
        let prefixes = [
            homeBin,
            URL(fileURLWithPath: "/opt/homebrew/bin", isDirectory: true),
            URL(fileURLWithPath: "/usr/local/bin", isDirectory: true),
            URL(fileURLWithPath: "/usr/bin", isDirectory: true)
        ]
        for prefix in prefixes {
            for name in trustedNames {
                let candidate = prefix.appendingPathComponent(name, isDirectory: false)
                if isExecutableRegularFile(candidate, fileManager: fileManager) {
                    return candidate
                }
            }
        }
        return nil
    }

    private static func baseEnvironment(temporaryRoot: URL) -> [String: String] {
        [
            "PATH": "/usr/bin:/bin",
            "LANG": "C",
            "LC_ALL": "C",
            "TMPDIR": temporaryRoot.path
        ]
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
            throw LocalCargoNextestVerificationError.invalidReport
        }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard data.count == size else { throw LocalCargoNextestVerificationError.invalidReport }
        return data
    }

    private static func isSafeTOMLPath(_ path: String) -> Bool {
        path.hasPrefix("/")
            && !path.contains("\0")
            && !path.contains("\"")
            && !path.contains("\\")
            && !path.contains("\n")
            && !path.contains("\r")
    }

    private static func isBoundedRegularFile(_ url: URL, maximumBytes: Int) -> Bool {
        guard !isSymbolicLink(url),
              let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true,
              let size = values.fileSize else { return false }
        return size > 0 && size <= maximumBytes
    }

    private static func isExecutableRegularFile(_ url: URL, fileManager: FileManager) -> Bool {
        fileManager.isExecutableFile(atPath: url.path)
            && (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
    }

    private static func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }

    private static func isSymbolicLink(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
    }
}

private enum LocalCargoNextestVerificationError: Error {
    case invalidPath
    case invalidReport
}

private final class NextestJUnitParserDelegate: NSObject, XMLParserDelegate {
    private(set) var isValid = true
    private(set) var passedTestCount = 0
    private var depth = 0
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
            guard elementName == "testsuites" else {
                invalidate(parser)
                return
            }
        }
        if elementName == "failure" || elementName == "error" {
            invalidate(parser)
            return
        }
        guard elementName == "testsuite", depth == 2 else { return }
        guard let tests = boundedInteger(attributeDict["tests"]),
              let failures = boundedInteger(attributeDict["failures"]),
              let errors = boundedInteger(attributeDict["errors"]),
              let skipped = optionalBoundedInteger(attributeDict["skipped"]),
              let disabled = optionalBoundedInteger(attributeDict["disabled"]),
              failures == 0,
              errors == 0,
              failures + errors + skipped + disabled <= tests else {
            invalidate(parser)
            return
        }
        suiteCount += 1
        passedTestCount += tests - failures - errors - skipped - disabled
        if suiteCount > 1_000 || passedTestCount > 1_000_000 {
            invalidate(parser)
        }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        depth -= 1
        if depth < 0 { invalidate(parser) }
    }

    func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) {
        isValid = false
    }

    func parser(
        _ parser: XMLParser,
        resolveExternalEntityName name: String,
        systemID: String?
    ) -> Data? {
        invalidate(parser)
        return nil
    }

    private func invalidate(_ parser: XMLParser) {
        isValid = false
        parser.abortParsing()
    }

    private func optionalBoundedInteger(_ value: String?) -> Int? {
        value == nil ? 0 : boundedInteger(value)
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
