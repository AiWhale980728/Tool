import Foundation
import Testing
@testable import RelayCore

@Suite("Local Jest verification evidence")
struct LocalJestVerificationEvidenceAdapterTests {
    @Test
    func successfulJSONReportBecomesBoundEvidence() throws {
        let report = Data(Self.successfulReport.utf8)
        let testCount = try #require(
            LocalJestVerificationEvidenceAdapter.parseSuccessfulJSONReport(report)
        )
        let snapshot = LocalJestVerificationSnapshot(
            testCount: testCount,
            headCommit: String(repeating: "d", count: 40),
            integrity: .complete,
            observedAt: SupervisorTestSupport.now
        )

        #expect(testCount == 5)
        #expect(snapshot.observations.count == 1)
        #expect(snapshot.observations[0].kind == .testPassed)
        #expect(snapshot.observations[0].source.kind == .tool)
        #expect(snapshot.observations[0].source.sourceID == "relay-local-jest-v1")
        #expect(snapshot.observations[0].integrity == .complete)
        #expect(snapshot.observations[0].reference == "local-jest:\(String(repeating: "d", count: 40))")
        #expect(!snapshot.observations[0].summary.contains("private"))
    }

    @Test(arguments: [
        #"{"success":false,"wasInterrupted":false,"numTotalTests":1,"numPassedTests":1,"numFailedTests":0,"numPendingTests":0,"numTodoTests":0,"numTotalTestSuites":1,"numPassedTestSuites":1,"numFailedTestSuites":0,"numPendingTestSuites":0,"numRuntimeErrorTestSuites":0}"#,
        #"{"success":true,"wasInterrupted":true,"numTotalTests":1,"numPassedTests":1,"numFailedTests":0,"numPendingTests":0,"numTodoTests":0,"numTotalTestSuites":1,"numPassedTestSuites":1,"numFailedTestSuites":0,"numPendingTestSuites":0,"numRuntimeErrorTestSuites":0}"#,
        #"{"success":true,"wasInterrupted":false,"numTotalTests":1,"numPassedTests":0,"numFailedTests":0,"numPendingTests":1,"numTodoTests":0,"numTotalTestSuites":1,"numPassedTestSuites":0,"numFailedTestSuites":0,"numPendingTestSuites":1,"numRuntimeErrorTestSuites":0}"#,
        #"{"success":true,"wasInterrupted":false,"numTotalTests":2,"numPassedTests":1,"numFailedTests":1,"numPendingTests":0,"numTodoTests":0,"numTotalTestSuites":1,"numPassedTestSuites":0,"numFailedTestSuites":1,"numPendingTestSuites":0,"numRuntimeErrorTestSuites":0}"#,
        #"{"success":true,"wasInterrupted":false,"numTotalTests":2,"numPassedTests":1,"numFailedTests":0,"numPendingTests":0,"numTodoTests":0,"numTotalTestSuites":1,"numPassedTestSuites":1,"numFailedTestSuites":0,"numPendingTestSuites":0,"numRuntimeErrorTestSuites":0}"#,
        "not JSON"
    ])
    func failedInterruptedEmptyOrInconsistentReportCannotBecomeEvidence(report: String) {
        #expect(
            LocalJestVerificationEvidenceAdapter.parseSuccessfulJSONReport(Data(report.utf8)) == nil
        )
    }

    @Test
    func unboundWorkspaceEvidenceRemainsPartialAndPathFree() {
        let snapshot = LocalJestVerificationSnapshot(
            testCount: 5,
            headCommit: nil,
            integrity: .partial,
            observedAt: SupervisorTestSupport.now
        )
        let observation = snapshot.observations[0]

        #expect(observation.integrity == .partial)
        #expect(observation.reference == nil)
        #expect(!observation.summary.contains("/Users/"))
        #expect(observation.summary.contains("未干净绑定"))
    }

    @Test
    func adapterBoundsExecutionConfiguration() {
        let adapter = LocalJestVerificationEvidenceAdapter(
            timeout: 10_000,
            maximumOutputBytes: 10_000_000
        )

        #expect(adapter.nodeExecutableURL == nil)
        #expect(adapter.timeout == 180)
        #expect(adapter.maximumOutputBytes == 512 * 1_024)
    }

    @Test
    func supportRequiresReviewedProjectLocalJestAndExecutableNode() throws {
        let root = try makeJestWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let node = try makeFakeNodeExecutable(in: root)
        let session = makeSession(root: root, id: "jest-support")

        #expect(LocalJestVerificationEvidenceAdapter.supports(
            session,
            nodeExecutableURL: node
        ))

        let manifest = root.appendingPathComponent("node_modules/jest/package.json")
        try Data(Self.jestManifest(version: "30.4.1").utf8).write(to: manifest)
        #expect(!LocalJestVerificationEvidenceAdapter.supports(
            session,
            nodeExecutableURL: node
        ))
    }

    @Test
    func symbolicLinkAndOversizedManifestsAreRejected() throws {
        let root = try makeJestWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let node = try makeFakeNodeExecutable(in: root)
        let session = makeSession(root: root, id: "jest-symlink")
        let cli = root.appendingPathComponent("node_modules/jest/bin/jest.js")
        let target = root.appendingPathComponent("real-jest.js")
        try Data("// fixture\n".utf8).write(to: target)
        try FileManager.default.removeItem(at: cli)
        try FileManager.default.createSymbolicLink(at: cli, withDestinationURL: target)

        #expect(!LocalJestVerificationEvidenceAdapter.supports(
            session,
            nodeExecutableURL: node
        ))

        try FileManager.default.removeItem(at: cli)
        try Data("// fixture\n".utf8).write(to: cli)
        let oversized = Data(
            repeating: 0x20,
            count: LocalJestVerificationEvidenceAdapter.maximumPackageBytes + 1
        )
        try oversized.write(to: root.appendingPathComponent("package.json"))
        #expect(!LocalJestVerificationEvidenceAdapter.supports(
            session,
            nodeExecutableURL: node
        ))
    }

    @Test
    func fixedPresetProducesPartialEvidenceWithoutGitAndUsesIsolatedEnvironment() async throws {
        let root = try makeJestWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let node = try makeFakeNodeExecutable(in: root)
        let session = makeSession(root: root, id: "jest-partial")

        let observations = await LocalJestVerificationEvidenceAdapter(
            nodeExecutableURL: node,
            timeout: 10
        ).collect(for: session)
        let observation = try #require(observations.first)

        #expect(observations.count == 1)
        #expect(observation.integrity == .partial)
        #expect(observation.reference == nil)
        #expect(observation.summary.contains("5 个本地 Jest 测试"))
        #expect(!observation.summary.contains(root.path))
    }

    @Test
    func fixedPresetProducesCompleteEvidenceForOneCleanCommit() async throws {
        let root = try makeJestWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let node = try makeFakeNodeExecutable(in: root)
        try runGit(["init", "-q"], in: root)
        try runGit(["config", "user.name", "Notch Relay Test"], in: root)
        try runGit(["config", "user.email", "notch-relay@example.invalid"], in: root)
        try runGit(["add", "."], in: root)
        try runGit(["commit", "-q", "-m", "fixture"], in: root)
        let session = makeSession(root: root, id: "jest-complete")

        let observations = await LocalJestVerificationEvidenceAdapter(
            nodeExecutableURL: node,
            timeout: 10
        ).collect(for: session)
        let observation = try #require(observations.first)

        #expect(observations.count == 1)
        #expect(observation.integrity == .complete)
        #expect(observation.reference?.hasPrefix("local-jest:") == true)
        #expect(!observation.summary.contains(root.path))
    }

    private static let successfulReport = #"{"success":true,"wasInterrupted":false,"numTotalTests":7,"numPassedTests":5,"numFailedTests":0,"numPendingTests":1,"numTodoTests":1,"numTotalTestSuites":3,"numPassedTestSuites":2,"numFailedTestSuites":0,"numPendingTestSuites":1,"numRuntimeErrorTestSuites":0,"testResults":[{"name":"/private/project/secret.test.js"}]}"#

    private static func jestManifest(version: String) -> String {
        #"{"name":"jest","version":"\#(version)","bin":"./bin/jest.js","license":"MIT"}"#
    }

    private func makeJestWorkspace() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("notch-relay-jest-run-\(UUID().uuidString)", isDirectory: true)
        let bin = root.appendingPathComponent("node_modules/jest/bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try Data(#"{"name":"fixture","private":true}"#.utf8).write(
            to: root.appendingPathComponent("package.json")
        )
        try Data(Self.jestManifest(version: "30.4.2").utf8).write(
            to: root.appendingPathComponent("node_modules/jest/package.json")
        )
        try Data("// reviewed Jest CLI fixture\n".utf8).write(
            to: bin.appendingPathComponent("jest.js")
        )
        return root
    }

    private func makeFakeNodeExecutable(in root: URL) throws -> URL {
        let executable = root.appendingPathComponent("fake-node")
        try Data("""
        #!/bin/sh
        if [ "${CI:-}" != "1" ]; then exit 21; fi
        if [ "${FORCE_COLOR:-}" != "0" ]; then exit 22; fi
        if [ "${PATH:-}" != "/usr/bin:/bin" ]; then exit 23; fi
        case " $* " in
          *" --json "*) ;;
          *) exit 24 ;;
        esac
        for required in --ci --runInBand --no-cache --no-watchman --watch=false --watchAll=false --colors=false; do
          case " $* " in
            *" $required "*) ;;
            *) exit 25 ;;
          esac
        done
        report=""
        for argument in "$@"; do
          case "$argument" in
            --outputFile=*) report="${argument#--outputFile=}" ;;
          esac
        done
        if [ -z "$report" ]; then exit 26; fi
        printf '%s\n' '\(Self.successfulReport)' > "$report"
        printf '%s\n' 'raw Jest output is discarded'
        """.utf8).write(to: executable)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executable.path
        )
        return executable
    }

    private func makeSession(root: URL, id: String) -> RelaySessionState {
        RelaySessionState(event: RelayEvent(
            source: .codex,
            sourceEvent: "TurnComplete",
            sessionID: id,
            status: .readyToReview,
            project: ProjectContext(cwd: root.path),
            summary: "Result ready for review.",
            occurredAt: SupervisorTestSupport.now,
            receivedAt: SupervisorTestSupport.now
        ))
    }

    private func runGit(_ arguments: [String], in root: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", root.path] + arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw JestFixtureError.gitFailed }
    }
}

private enum JestFixtureError: Error {
    case gitFailed
}
