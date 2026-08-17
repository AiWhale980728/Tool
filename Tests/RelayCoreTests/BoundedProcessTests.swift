import Foundation
import Testing
@testable import RelayCore

@Suite("Bounded subprocess integration")
struct BoundedProcessTests {
    @Test
    func officialSubprocessCombinesBoundedOutputWhenRequested() async throws {
        let process = BoundedProcess(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "printf stdout; printf stderr >&2"],
            maximumOutputBytes: 1_024,
            environment: ["PATH": "/usr/bin:/bin"],
            captureStandardError: true
        )

        let data = try await process.run(deadline: Date().addingTimeInterval(2))
        let output = String(decoding: data, as: UTF8.self)

        #expect(output.contains("stdout"))
        #expect(output.contains("stderr"))
    }

    @Test
    func officialSubprocessRejectsNonzeroExitAndOversizedOutput() async {
        let failed = BoundedProcess(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "exit 7"],
            maximumOutputBytes: 1_024,
            environment: ["PATH": "/usr/bin:/bin"]
        )
        await #expect(throws: GitEvidenceAdapterError.processFailed) {
            try await failed.run(deadline: Date().addingTimeInterval(2))
        }

        let oversized = BoundedProcess(
            executableURL: URL(fileURLWithPath: "/usr/bin/yes"),
            arguments: ["bounded"],
            maximumOutputBytes: 1_024,
            environment: ["PATH": "/usr/bin:/bin"]
        )
        await #expect(throws: GitEvidenceAdapterError.outputLimitExceeded) {
            try await oversized.run(deadline: Date().addingTimeInterval(2))
        }
    }

    @Test
    func officialSubprocessCancelsTimedOutProcessGroup() async {
        let process = BoundedProcess(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "sleep 10"],
            maximumOutputBytes: 1_024,
            environment: ["PATH": "/usr/bin:/bin"]
        )
        let startedAt = Date()

        await #expect(throws: GitEvidenceAdapterError.timedOut) {
            try await process.run(deadline: Date().addingTimeInterval(0.1))
        }
        #expect(Date().timeIntervalSince(startedAt) < 2)
    }
}
