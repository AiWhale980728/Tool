import Foundation

public struct LocalJestVerificationSnapshot: Equatable, Sendable {
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
            reference = "local-jest:\(headCommit.lowercased())"
        } else {
            binding = "；工作区未干净绑定到单一 Git 提交"
            reference = nil
        }
        return [CompletionReviewEvidenceObservation(
            kind: .testPassed,
            source: EvidenceSource(kind: .tool, sourceID: "relay-local-jest-v1"),
            summary: "Relay 观察到 \(testCount) 个本地 Jest 测试通过\(binding)。",
            reference: reference,
            observedAt: observedAt,
            dataLevel: .l1StructuredEvidence,
            integrity: integrity
        )]
    }
}

public struct LocalJestVerificationEvidenceAdapter: Sendable {
    static let supportedJestVersion = "30.4.2"
    static let maximumPackageBytes = 256 * 1_024
    static let maximumReportBytes = 512 * 1_024
    static let maximumTestCount = 1_000_000

    public var nodeExecutableURL: URL?
    public var timeout: TimeInterval
    public var maximumOutputBytes: Int

    public init(
        nodeExecutableURL: URL? = nil,
        timeout: TimeInterval = 180,
        maximumOutputBytes: Int = 512 * 1_024
    ) {
        self.nodeExecutableURL = nodeExecutableURL
        self.timeout = min(max(1, timeout), 180)
        self.maximumOutputBytes = min(max(16 * 1_024, maximumOutputBytes), 512 * 1_024)
    }

    public static func supports(
        _ session: RelaySessionState,
        nodeExecutableURL: URL? = nil,
        fileManager: FileManager = .default
    ) -> Bool {
        guard resolvedNodeExecutable(
            override: nodeExecutableURL,
            fileManager: fileManager
        ) != nil else { return false }
        return jestCLI(for: session, fileManager: fileManager) != nil
    }

    public func collect(
        for session: RelaySessionState,
        now: Date = Date(),
        fileManager: FileManager = .default
    ) async -> [CompletionReviewEvidenceObservation] {
        guard let cwd = session.project.cwd,
              let node = Self.resolvedNodeExecutable(
                  override: nodeExecutableURL,
                  fileManager: fileManager
              ),
              let jestCLI = Self.jestCLI(for: session, fileManager: fileManager) else {
            return []
        }
        let git = GitCompletionEvidenceAdapter()
        let before = await git.snapshot(for: session, now: now)
        let temporaryRoot = fileManager.temporaryDirectory
            .appendingPathComponent("notch-relay-jest-verification-\(UUID().uuidString)", isDirectory: true)
        do {
            try fileManager.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
        } catch {
            return []
        }
        defer { try? fileManager.removeItem(at: temporaryRoot) }

        do {
            let report = try await runTests(
                node: node,
                jestCLI: jestCLI,
                cwd: cwd,
                temporaryRoot: temporaryRoot
            )
            guard let testCount = Self.parseSuccessfulJSONReport(report), testCount > 0 else {
                return []
            }
            let observedAt = Date()
            let after = await git.snapshot(for: session, now: observedAt)
            let cleanBinding = before?.isClean == true
                && after?.isClean == true
                && before?.headCommit.caseInsensitiveCompare(after?.headCommit ?? "") == .orderedSame
            return LocalJestVerificationSnapshot(
                testCount: testCount,
                headCommit: cleanBinding ? after?.headCommit : nil,
                integrity: cleanBinding ? .complete : .partial,
                observedAt: observedAt
            ).observations
        } catch {
            return []
        }
    }

    func runTests(
        node: URL,
        jestCLI: URL,
        cwd: String,
        temporaryRoot: URL
    ) async throws -> Data {
        let home = temporaryRoot.appendingPathComponent("home", isDirectory: true)
        let cache = temporaryRoot.appendingPathComponent("cache", isDirectory: true)
        let report = temporaryRoot.appendingPathComponent("jest-results.json", isDirectory: false)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)

        let command = BoundedProcess(
            executableURL: node,
            arguments: [
                jestCLI.path,
                "--json",
                "--outputFile=\(report.path)",
                "--ci",
                "--runInBand",
                "--no-cache",
                "--no-watchman",
                "--watch=false",
                "--watchAll=false",
                "--colors=false"
            ],
            maximumOutputBytes: maximumOutputBytes,
            environment: [
                "PATH": "/usr/bin:/bin",
                "LANG": "C",
                "LC_ALL": "C",
                "HOME": home.path,
                "TMPDIR": temporaryRoot.path,
                "XDG_CACHE_HOME": cache.path,
                "CI": "1",
                "FORCE_COLOR": "0"
            ],
            currentDirectoryURL: URL(fileURLWithPath: cwd, isDirectory: true),
            captureStandardError: true
        )
        _ = try await command.run(deadline: Date().addingTimeInterval(timeout))
        return try Self.readBoundedReport(at: report)
    }

    static func parseSuccessfulJSONReport(_ data: Data) -> Int? {
        guard !data.isEmpty,
              data.count <= maximumReportBytes,
              let object = try? JSONSerialization.jsonObject(with: data),
              let report = object as? [String: Any],
              report["success"] as? Bool == true,
              report["wasInterrupted"] as? Bool == false,
              let total = boundedInteger(report["numTotalTests"]),
              let passed = boundedInteger(report["numPassedTests"]),
              let failed = boundedInteger(report["numFailedTests"]),
              let pending = boundedInteger(report["numPendingTests"]),
              let todo = boundedInteger(report["numTodoTests"]),
              let totalSuites = boundedInteger(report["numTotalTestSuites"]),
              let passedSuites = boundedInteger(report["numPassedTestSuites"]),
              let failedSuites = boundedInteger(report["numFailedTestSuites"]),
              let pendingSuites = boundedInteger(report["numPendingTestSuites"]),
              let runtimeErrorSuites = boundedInteger(report["numRuntimeErrorTestSuites"]),
              total > 0,
              passed > 0,
              failed == 0,
              runtimeErrorSuites == 0,
              passed + pending + todo == total,
              totalSuites > 0,
              failedSuites == 0,
              passedSuites + pendingSuites == totalSuites else {
            return nil
        }
        return passed
    }

    private static func resolvedNodeExecutable(
        override: URL?,
        fileManager: FileManager
    ) -> URL? {
        if let override {
            return isExecutableRegularFile(override, fileManager: fileManager) ? override : nil
        }
        let trustedPaths = [
            "/opt/homebrew/bin/node",
            "/usr/local/bin/node",
            "/usr/bin/node"
        ]
        return trustedPaths
            .map { URL(fileURLWithPath: $0, isDirectory: false) }
            .first { isExecutableRegularFile($0, fileManager: fileManager) }
    }

    private static func jestCLI(
        for session: RelaySessionState,
        fileManager: FileManager
    ) -> URL? {
        guard let cwd = session.project.cwd,
              cwd.hasPrefix("/"),
              !cwd.contains("\0") else { return nil }
        let root = URL(fileURLWithPath: cwd, isDirectory: true)
        let package = root.appendingPathComponent("package.json", isDirectory: false)
        guard isBoundedRegularFile(package, maximumBytes: maximumPackageBytes) else { return nil }

        let nodeModules = root.appendingPathComponent("node_modules", isDirectory: true)
        let jest = nodeModules.appendingPathComponent("jest", isDirectory: true)
        let bin = jest.appendingPathComponent("bin", isDirectory: true)
        guard isDirectory(nodeModules),
              isDirectory(jest),
              isDirectory(bin),
              !isSymbolicLink(nodeModules),
              !isSymbolicLink(jest),
              !isSymbolicLink(bin) else { return nil }

        let installedPackage = jest.appendingPathComponent("package.json", isDirectory: false)
        guard isBoundedRegularFile(installedPackage, maximumBytes: maximumPackageBytes),
              let data = try? Data(contentsOf: installedPackage, options: .mappedIfSafe),
              let object = try? JSONSerialization.jsonObject(with: data),
              let manifest = object as? [String: Any],
              manifest["name"] as? String == "jest",
              manifest["version"] as? String == supportedJestVersion,
              manifest["bin"] as? String == "./bin/jest.js" else {
            return nil
        }

        let cli = bin.appendingPathComponent("jest.js", isDirectory: false)
        guard isBoundedRegularFile(cli, maximumBytes: maximumPackageBytes) else { return nil }
        return cli
    }

    private static func readBoundedReport(at url: URL) throws -> Data {
        let values = try url.resourceValues(forKeys: [
            .fileSizeKey,
            .isRegularFileKey,
            .isSymbolicLinkKey
        ])
        guard values.isRegularFile == true,
              values.isSymbolicLink != true,
              let size = values.fileSize,
              size > 0,
              size <= maximumReportBytes else {
            throw LocalJestVerificationError.invalidReport
        }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard data.count == size else { throw LocalJestVerificationError.invalidReport }
        return data
    }

    private static func boundedInteger(_ value: Any?) -> Int? {
        guard let value,
              let number = value as? NSNumber,
              String(cString: number.objCType) != "c" else { return nil }
        let double = number.doubleValue
        guard double.isFinite,
              double.rounded(.towardZero) == double,
              double >= 0,
              double <= Double(maximumTestCount) else { return nil }
        return Int(double)
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

private enum LocalJestVerificationError: Error {
    case invalidReport
}
