import Foundation
import Testing
@testable import RelayCore

@Suite("Local Cargo nextest verification evidence", .serialized)
struct LocalCargoNextestVerificationEvidenceAdapterTests {
    @Test
    func successfulJUnitReportBecomesBoundEvidence() throws {
        let report = Data(Self.successfulReport.utf8)
        let testCount = try #require(
            LocalCargoNextestVerificationEvidenceAdapter.parseSuccessfulJUnitReport(report)
        )
        let snapshot = LocalCargoNextestVerificationSnapshot(
            testCount: testCount,
            headCommit: String(repeating: "e", count: 40),
            integrity: .complete,
            observedAt: SupervisorTestSupport.now
        )

        #expect(testCount == 5)
        #expect(snapshot.observations.count == 1)
        #expect(snapshot.observations[0].source.sourceID == "relay-local-cargo-nextest-v1")
        #expect(snapshot.observations[0].integrity == .complete)
        #expect(snapshot.observations[0].reference == "local-cargo-nextest:\(String(repeating: "e", count: 40))")
        #expect(!snapshot.observations[0].summary.contains("private"))
    }

    @Test(arguments: [
        "<testsuites><testsuite tests=\"2\" failures=\"1\" errors=\"0\" disabled=\"0\"><testcase><failure /></testcase></testsuite></testsuites>",
        "<testsuites><testsuite tests=\"2\" failures=\"0\" errors=\"1\" disabled=\"0\" /></testsuites>",
        "<testsuites><testsuite tests=\"2\" failures=\"0\" errors=\"0\" disabled=\"2\" /></testsuites>",
        "<testsuites><testsuite tests=\"2\" failures=\"0\" errors=\"0\" disabled=\"3\" /></testsuites>",
        "<testsuite tests=\"2\" failures=\"0\" errors=\"0\" />",
        "not XML"
    ])
    func failedEmptyOrInvalidJUnitCannotBecomeEvidence(report: String) {
        #expect(
            LocalCargoNextestVerificationEvidenceAdapter.parseSuccessfulJUnitReport(
                Data(report.utf8)
            ) == nil
        )
    }

    @Test(arguments: [
        "cargo-nextest 0.9.143",
        "cargo-nextest 0.9.143 (60fa45f 2026-08-04)"
    ])
    func reviewedVersionOutputIsAccepted(output: String) {
        #expect(LocalCargoNextestVerificationEvidenceAdapter.parseReviewedVersion(Data(output.utf8)))
    }

    @Test(arguments: [
        "cargo-nextest 0.9.142",
        "cargo-nextest 0.9.143 unexpected",
        "cargo 0.9.143",
        "not a version"
    ])
    func unreviewedVersionOutputIsRejected(output: String) {
        #expect(!LocalCargoNextestVerificationEvidenceAdapter.parseReviewedVersion(Data(output.utf8)))
    }

    @Test
    func unboundWorkspaceEvidenceRemainsPartialAndPathFree() {
        let snapshot = LocalCargoNextestVerificationSnapshot(
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
        let adapter = LocalCargoNextestVerificationEvidenceAdapter(
            timeout: 10_000,
            maximumOutputBytes: 10_000_000
        )

        #expect(adapter.cargoExecutableURL == nil)
        #expect(adapter.nextestExecutableURL == nil)
        #expect(adapter.timeout == 180)
        #expect(adapter.maximumOutputBytes == 512 * 1_024)
    }

    @Test
    func supportRequiresBoundedManifestLockfileAndExecutables() throws {
        let root = try makeCargoWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let cargo = try makeExecutable(named: "fake-cargo", in: root, contents: "#!/bin/sh\nexit 0\n")
        let nextest = try makeFakeNextestExecutable(in: root, cargo: cargo)
        let session = makeSession(root: root, id: "cargo-support")

        #expect(LocalCargoNextestVerificationEvidenceAdapter.supports(
            session,
            cargoExecutableURL: cargo,
            nextestExecutableURL: nextest
        ))

        try FileManager.default.removeItem(at: root.appendingPathComponent("Cargo.lock"))
        #expect(!LocalCargoNextestVerificationEvidenceAdapter.supports(
            session,
            cargoExecutableURL: cargo,
            nextestExecutableURL: nextest
        ))
    }

    @Test
    func symbolicLinkAndOversizedProjectFilesAreRejected() throws {
        let root = try makeCargoWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let cargo = try makeExecutable(named: "fake-cargo", in: root, contents: "#!/bin/sh\nexit 0\n")
        let nextest = try makeFakeNextestExecutable(in: root, cargo: cargo)
        let session = makeSession(root: root, id: "cargo-bounds")
        let manifest = root.appendingPathComponent("Cargo.toml")
        let target = root.appendingPathComponent("real-Cargo.toml")
        try Data("[package]\nname = \"fixture\"\n".utf8).write(to: target)
        try FileManager.default.removeItem(at: manifest)
        try FileManager.default.createSymbolicLink(at: manifest, withDestinationURL: target)

        #expect(!LocalCargoNextestVerificationEvidenceAdapter.supports(
            session,
            cargoExecutableURL: cargo,
            nextestExecutableURL: nextest
        ))

        try FileManager.default.removeItem(at: manifest)
        let oversized = Data(
            repeating: 0x20,
            count: LocalCargoNextestVerificationEvidenceAdapter.maximumManifestBytes + 1
        )
        try oversized.write(to: manifest)
        #expect(!LocalCargoNextestVerificationEvidenceAdapter.supports(
            session,
            cargoExecutableURL: cargo,
            nextestExecutableURL: nextest
        ))
    }

    @Test
    func wrongNextestVersionProducesNoEvidence() async throws {
        let root = try makeCargoWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let cargo = try makeExecutable(named: "fake-cargo", in: root, contents: "#!/bin/sh\nexit 0\n")
        let nextest = try makeExecutable(
            named: "fake-nextest",
            in: root,
            contents: "#!/bin/sh\nprintf '%s\\n' 'cargo-nextest 0.9.142'\n"
        )
        let session = makeSession(root: root, id: "cargo-version")

        let observations = await LocalCargoNextestVerificationEvidenceAdapter(
            cargoExecutableURL: cargo,
            nextestExecutableURL: nextest,
            timeout: 10
        ).collect(for: session)

        #expect(observations.isEmpty)
    }

    @Test
    func fixedPresetProducesPartialEvidenceWithoutGitAndUsesOfflineEnvironment() async throws {
        let root = try makeCargoWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let cargo = try makeExecutable(named: "fake-cargo", in: root, contents: "#!/bin/sh\nexit 0\n")
        let nextest = try makeFakeNextestExecutable(in: root, cargo: cargo)
        let session = makeSession(root: root, id: "cargo-partial")

        let observations = await LocalCargoNextestVerificationEvidenceAdapter(
            cargoExecutableURL: cargo,
            nextestExecutableURL: nextest,
            timeout: 10
        ).collect(for: session)
        let observation = try #require(observations.first)

        #expect(observations.count == 1)
        #expect(observation.integrity == .partial)
        #expect(observation.reference == nil)
        #expect(observation.summary.contains("5 个本地 Cargo nextest 测试"))
        #expect(!observation.summary.contains(root.path))
    }

    @Test
    func fixedPresetProducesCompleteEvidenceForOneCleanCommit() async throws {
        let root = try makeCargoWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let cargo = try makeExecutable(named: "fake-cargo", in: root, contents: "#!/bin/sh\nexit 0\n")
        let nextest = try makeFakeNextestExecutable(in: root, cargo: cargo)
        try runGit(["init", "-q"], in: root)
        try runGit(["config", "user.name", "Notch Relay Test"], in: root)
        try runGit(["config", "user.email", "notch-relay@example.invalid"], in: root)
        try runGit(["add", "."], in: root)
        try runGit(["commit", "-q", "-m", "fixture"], in: root)
        let session = makeSession(root: root, id: "cargo-complete")

        let observations = await LocalCargoNextestVerificationEvidenceAdapter(
            cargoExecutableURL: cargo,
            nextestExecutableURL: nextest,
            timeout: 10
        ).collect(for: session)
        let observation = try #require(observations.first)

        #expect(observations.count == 1)
        #expect(observation.integrity == .complete)
        #expect(observation.reference?.hasPrefix("local-cargo-nextest:") == true)
        #expect(!observation.summary.contains(root.path))
    }

    private static let successfulReport = """
    <?xml version="1.0" encoding="UTF-8"?>
    <testsuites name="nextest-run" tests="6" failures="0" errors="0">
      <testsuite name="private::unit" tests="4" disabled="1" errors="0" failures="0">
        <testcase name="private_name" classname="private::unit" />
      </testsuite>
      <testsuite name="private::integration" tests="2" disabled="0" errors="0" failures="0" />
    </testsuites>
    """

    private func makeCargoWorkspace() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("notch-relay-cargo-run-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("""
        [package]
        name = "fixture"
        version = "0.1.0"
        edition = "2021"
        """.utf8).write(to: root.appendingPathComponent("Cargo.toml"))
        try Data("# fixture lock\nversion = 4\n".utf8).write(
            to: root.appendingPathComponent("Cargo.lock")
        )
        return root
    }

    private func makeFakeNextestExecutable(in root: URL, cargo: URL) throws -> URL {
        try makeExecutable(
            named: "fake-nextest",
            in: root,
            contents: """
            #!/bin/sh
            if [ "$1" != "nextest" ]; then exit 21; fi
            if [ "$2" = "--version" ]; then
              printf '%s\n' 'cargo-nextest 0.9.143 (60fa45f 2026-08-04)'
              exit 0
            fi
            if [ "${CARGO:-}" != "\(cargo.path)" ]; then exit 22; fi
            if [ "${CARGO_NET_OFFLINE:-}" != "true" ]; then exit 23; fi
            if [ "${PATH:-}" != "/usr/bin:/bin" ]; then exit 24; fi
            for required in --no-pager --offline --locked --no-fail-fast; do
              case " $* " in
                *" $required "*) ;;
                *) exit 25 ;;
              esac
            done
            config=""
            previous=""
            for argument in "$@"; do
              if [ "$previous" = "--config-file" ]; then config="$argument"; fi
              previous="$argument"
            done
            if [ -z "$config" ]; then exit 26; fi
            report=$(/usr/bin/sed -n 's/^path = "\\(.*\\)"$/\\1/p' "$config")
            if [ -z "$report" ]; then exit 27; fi
            printf '%s\n' '\(Self.successfulReport)' > "$report"
            printf '%s\n' 'raw cargo-nextest output is discarded'
            """
        )
    }

    private func makeExecutable(
        named name: String,
        in root: URL,
        contents: String
    ) throws -> URL {
        let executable = root.appendingPathComponent(name)
        try Data(contents.utf8).write(to: executable)
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
        guard process.terminationStatus == 0 else { throw CargoNextestFixtureError.gitFailed }
    }
}

private enum CargoNextestFixtureError: Error {
    case gitFailed
}
