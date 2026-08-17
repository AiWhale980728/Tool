import Foundation
import Testing
@testable import RelayCore

@Suite("Local Python verification evidence")
struct LocalPythonVerificationEvidenceAdapterTests {
    @Test
    func successfulUnittestSummaryBecomesBoundEvidence() throws {
        let output = Data("----------------------------------------------------------------------\nRan 12 tests in 0.042s\n\nOK\n".utf8)
        let testCount = try #require(
            LocalPythonVerificationEvidenceAdapter.parseSuccessfulTestRun(output)
        )
        let snapshot = LocalPythonVerificationSnapshot(
            testCount: testCount,
            headCommit: String(repeating: "b", count: 40),
            integrity: .complete,
            observedAt: SupervisorTestSupport.now
        )

        #expect(testCount == 12)
        #expect(snapshot.observations.count == 1)
        #expect(snapshot.observations[0].kind == .testPassed)
        #expect(snapshot.observations[0].source.kind == .tool)
        #expect(snapshot.observations[0].integrity == .complete)
        #expect(snapshot.observations[0].summary.contains("bbbbbbbbbbbb"))
    }

    @Test(arguments: [
        "Ran 0 tests in 0.001s\n\nOK\n",
        "Ran 3 tests in 0.010s\n\nFAILED (failures=1)\n",
        "unstructured output"
    ])
    func failedEmptyOrUnknownOutputCannotBecomeEvidence(output: String) {
        let parsed = LocalPythonVerificationEvidenceAdapter.parseSuccessfulTestRun(Data(output.utf8))
        if output.contains("Ran 0 tests") {
            #expect(parsed == 0)
        } else {
            #expect(parsed == nil)
        }
    }

    @Test
    func unboundWorkspaceEvidenceRemainsPartialAndPathFree() {
        let snapshot = LocalPythonVerificationSnapshot(
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
        let adapter = LocalPythonVerificationEvidenceAdapter(
            timeout: 10_000,
            maximumOutputBytes: 10_000_000
        )

        #expect(adapter.executableURL.path == "/usr/bin/python3")
        #expect(adapter.timeout == 180)
        #expect(adapter.maximumOutputBytes == 512 * 1_024)
    }

    @Test
    func supportRequiresRegularProjectMarkerAndTestsDirectory() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("notch-relay-python-support-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("tests", isDirectory: true),
            withIntermediateDirectories: true
        )
        try Data("[project]\nname = \"fixture\"\n".utf8).write(
            to: root.appendingPathComponent("pyproject.toml")
        )
        let session = RelaySessionState(event: RelayEvent(
            source: .codex,
            sourceEvent: "TurnComplete",
            sessionID: "python-evidence-session",
            status: .readyToReview,
            project: ProjectContext(cwd: root.path),
            summary: "Result ready for review.",
            occurredAt: SupervisorTestSupport.now,
            receivedAt: SupervisorTestSupport.now
        ))

        #expect(LocalPythonVerificationEvidenceAdapter.supports(session))
    }

    @Test
    func realSystemPythonPresetProducesOnlyPartialEvidenceWithoutGitBinding() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("notch-relay-python-run-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let tests = root.appendingPathComponent("tests", isDirectory: true)
        try FileManager.default.createDirectory(at: tests, withIntermediateDirectories: true)
        try Data("[project]\nname = \"fixture\"\n".utf8).write(
            to: root.appendingPathComponent("pyproject.toml")
        )
        try Data().write(to: tests.appendingPathComponent("__init__.py"))
        try Data("""
        import unittest

        class FixtureTest(unittest.TestCase):
            def test_value(self):
                self.assertEqual(2 + 2, 4)
        """.utf8).write(to: tests.appendingPathComponent("test_fixture.py"))
        let session = RelaySessionState(event: RelayEvent(
            source: .codex,
            sourceEvent: "TurnComplete",
            sessionID: "python-run-session",
            status: .readyToReview,
            project: ProjectContext(cwd: root.path),
            summary: "Result ready for review.",
            occurredAt: SupervisorTestSupport.now,
            receivedAt: SupervisorTestSupport.now
        ))

        let observations = await LocalPythonVerificationEvidenceAdapter(timeout: 10).collect(
            for: session
        )

        #expect(observations.count == 1)
        #expect(observations[0].kind == .testPassed)
        #expect(observations[0].integrity == .partial)
        #expect(observations[0].reference == nil)
        #expect(!observations[0].summary.contains(root.path))
    }
}
