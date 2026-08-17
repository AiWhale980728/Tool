import Foundation
import Testing
@testable import RelayCore

@Suite("Local pytest verification evidence")
struct LocalPytestVerificationEvidenceAdapterTests {
    @Test
    func successfulJUnitReportBecomesBoundEvidence() throws {
        let report = Data("""
        <?xml version="1.0" encoding="utf-8"?>
        <testsuites name="pytest tests">
          <testsuite name="pytest" errors="0" failures="0" skipped="2" tests="7" time="0.01">
            <testcase classname="private.path" name="private_name" time="0.001" />
          </testsuite>
        </testsuites>
        """.utf8)
        let testCount = try #require(
            LocalPytestVerificationEvidenceAdapter.parseSuccessfulJUnitReport(report)
        )
        let snapshot = LocalPytestVerificationSnapshot(
            testCount: testCount,
            headCommit: String(repeating: "c", count: 40),
            integrity: .complete,
            observedAt: SupervisorTestSupport.now
        )

        #expect(testCount == 5)
        #expect(snapshot.observations.count == 1)
        #expect(snapshot.observations[0].kind == .testPassed)
        #expect(snapshot.observations[0].source.kind == .tool)
        #expect(snapshot.observations[0].source.sourceID == "relay-local-pytest-v1")
        #expect(snapshot.observations[0].integrity == .complete)
        #expect(snapshot.observations[0].reference == "local-pytest:\(String(repeating: "c", count: 40))")
        #expect(!snapshot.observations[0].summary.contains("private"))
    }

    @Test(arguments: [
        "<testsuites><testsuite errors=\"0\" failures=\"1\" skipped=\"0\" tests=\"2\" /></testsuites>",
        "<testsuites><testsuite errors=\"0\" failures=\"0\" skipped=\"2\" tests=\"2\" /></testsuites>",
        "<testsuites><testsuite errors=\"0\" failures=\"0\" tests=\"2\" /></testsuites>",
        "<not-tests />",
        "not XML"
    ])
    func failedEmptyOrInvalidJUnitCannotBecomeEvidence(report: String) {
        #expect(
            LocalPytestVerificationEvidenceAdapter.parseSuccessfulJUnitReport(Data(report.utf8)) == nil
        )
    }

    @Test
    func multipleSuitesAreSummedWithoutRetainingCaseData() {
        let report = Data("""
        <testsuites>
          <testsuite errors="0" failures="0" skipped="1" tests="4">
            <testcase classname="secret.module" name="secret_case" />
          </testsuite>
          <testsuite errors="0" failures="0" skipped="0" tests="3" />
        </testsuites>
        """.utf8)

        #expect(LocalPytestVerificationEvidenceAdapter.parseSuccessfulJUnitReport(report) == 6)
    }

    @Test
    func unboundWorkspaceEvidenceRemainsPartialAndPathFree() {
        let snapshot = LocalPytestVerificationSnapshot(
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
        let adapter = LocalPytestVerificationEvidenceAdapter(
            timeout: 10_000,
            maximumOutputBytes: 10_000_000
        )

        #expect(adapter.executableURL.path == "/usr/bin/python3")
        #expect(adapter.timeout == 180)
        #expect(adapter.maximumOutputBytes == 512 * 1_024)
    }

    @Test
    func supportRequiresBoundedPytestConfigurationAndRegularTestsDirectory() throws {
        let root = try makePytestWorkspace(configuration: .pytestINI)
        defer { try? FileManager.default.removeItem(at: root) }
        let session = makeSession(root: root, id: "pytest-support")

        #expect(LocalPytestVerificationEvidenceAdapter.supports(session))

        try FileManager.default.removeItem(at: root.appendingPathComponent("pytest.ini"))
        try Data("[project]\nname = \"fixture\"\n".utf8).write(
            to: root.appendingPathComponent("pyproject.toml")
        )
        #expect(!LocalPytestVerificationEvidenceAdapter.supports(session))

        try Data("[tool.pytest.ini_options]\naddopts = \"-q\"\n".utf8).write(
            to: root.appendingPathComponent("pyproject.toml")
        )
        #expect(LocalPytestVerificationEvidenceAdapter.supports(session))
    }

    @Test
    func symbolicLinkAndOversizedConfigurationsAreRejected() throws {
        let root = try makePytestWorkspace(configuration: .none)
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("real-pytest.ini")
        try Data("[pytest]\n".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("pytest.ini"),
            withDestinationURL: target
        )
        let session = makeSession(root: root, id: "pytest-symlink")
        #expect(!LocalPytestVerificationEvidenceAdapter.supports(session))

        try FileManager.default.removeItem(at: root.appendingPathComponent("pytest.ini"))
        let oversized = Data(
            repeating: 0x20,
            count: LocalPytestVerificationEvidenceAdapter.maximumConfigurationBytes + 1
        )
        try oversized.write(to: root.appendingPathComponent("pytest.ini"))
        #expect(!LocalPytestVerificationEvidenceAdapter.supports(session))
    }

    @Test
    func fixedPresetProducesPartialEvidenceWithoutGitAndDoesNotInheritPythonPath() async throws {
        let root = try makePytestWorkspace(configuration: .pytestINI)
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = try makeFakePytestExecutable(in: root)
        let session = makeSession(root: root, id: "pytest-partial")

        let observations = await LocalPytestVerificationEvidenceAdapter(
            executableURL: executable,
            timeout: 10
        ).collect(for: session)

        #expect(observations.count == 1)
        #expect(observations[0].integrity == .partial)
        #expect(observations[0].reference == nil)
        #expect(observations[0].summary.contains("3 个本地 pytest 测试"))
        #expect(!observations[0].summary.contains(root.path))
    }

    @Test
    func fixedPresetProducesCompleteEvidenceForOneCleanCommit() async throws {
        let root = try makePytestWorkspace(configuration: .pyproject)
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = try makeFakePytestExecutable(in: root)
        try runGit(["init", "-q"], in: root)
        try runGit(["config", "user.name", "Notch Relay Test"], in: root)
        try runGit(["config", "user.email", "notch-relay@example.invalid"], in: root)
        try runGit(["add", "."], in: root)
        try runGit(["commit", "-q", "-m", "fixture"], in: root)
        let session = makeSession(root: root, id: "pytest-complete")

        let observations = await LocalPytestVerificationEvidenceAdapter(
            executableURL: executable,
            timeout: 10
        ).collect(for: session)

        #expect(observations.count == 1)
        #expect(observations[0].integrity == .complete)
        #expect(observations[0].reference?.hasPrefix("local-pytest:") == true)
        #expect(!observations[0].summary.contains(root.path))
    }

    private enum ConfigurationFixture {
        case none
        case pytestINI
        case pyproject
    }

    private func makePytestWorkspace(configuration: ConfigurationFixture) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("notch-relay-pytest-run-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("tests", isDirectory: true),
            withIntermediateDirectories: true
        )
        try Data("def test_fixture():\n    assert True\n".utf8).write(
            to: root.appendingPathComponent("tests/test_fixture.py")
        )
        switch configuration {
        case .none:
            break
        case .pytestINI:
            try Data("[pytest]\n".utf8).write(to: root.appendingPathComponent("pytest.ini"))
        case .pyproject:
            try Data("[tool.pytest.ini_options]\n".utf8).write(
                to: root.appendingPathComponent("pyproject.toml")
            )
        }
        return root
    }

    private func makeFakePytestExecutable(in root: URL) throws -> URL {
        let executable = root.appendingPathComponent("fake-pytest")
        try Data("""
        #!/bin/sh
        if [ "${PYTEST_DISABLE_PLUGIN_AUTOLOAD:-}" != "1" ]; then exit 21; fi
        if [ -n "${PYTHONPATH+x}" ]; then exit 22; fi
        case " $* " in
          *" -I -B -m pytest "*) ;;
          *) exit 23 ;;
        esac
        case " $* " in
          *" -p no:cacheprovider "*) ;;
          *) exit 24 ;;
        esac
        report=""
        previous=""
        for argument in "$@"; do
          if [ "$previous" = "--junitxml" ]; then report="$argument"; fi
          previous="$argument"
        done
        if [ -z "$report" ]; then exit 25; fi
        printf '%s\n' '<testsuites><testsuite errors="0" failures="0" skipped="1" tests="4" /></testsuites>' > "$report"
        printf '%s\n' 'raw pytest output is discarded'
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
        guard process.terminationStatus == 0 else { throw PytestFixtureError.gitFailed }
    }
}

private enum PytestFixtureError: Error {
    case gitFailed
}
