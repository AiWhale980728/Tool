import Foundation
import Subprocess
import System

public struct GitEvidenceSnapshot: Equatable, Sendable {
    public var headCommit: String
    public var trackedChangeCount: Int
    public var untrackedEntryCount: Int
    public var conflictCount: Int
    public var observedAt: Date

    public init(
        headCommit: String,
        trackedChangeCount: Int,
        untrackedEntryCount: Int,
        conflictCount: Int,
        observedAt: Date
    ) {
        self.headCommit = headCommit
        self.trackedChangeCount = max(0, trackedChangeCount)
        self.untrackedEntryCount = max(0, untrackedEntryCount)
        self.conflictCount = max(0, conflictCount)
        self.observedAt = observedAt
    }

    public var observation: CompletionReviewEvidenceObservation {
        let shortCommit = String(headCommit.prefix(12)).lowercased()
        let summary: String
        if trackedChangeCount == 0, untrackedEntryCount == 0, conflictCount == 0 {
            summary = "Git 独立观察到提交 \(shortCommit)，工作区干净。"
        } else {
            summary = "Git 独立观察到提交 \(shortCommit)；工作区有 \(trackedChangeCount) 个已跟踪改动、\(untrackedEntryCount) 个未跟踪条目和 \(conflictCount) 个冲突。"
        }
        return CompletionReviewEvidenceObservation(
            kind: .gitState,
            source: EvidenceSource(kind: .tool, sourceID: "git-local-readonly-v1"),
            summary: summary,
            reference: "git:\(headCommit.lowercased())",
            observedAt: observedAt,
            dataLevel: .l1StructuredEvidence,
            integrity: .partial
        )
    }

    public var isClean: Bool {
        trackedChangeCount == 0 && untrackedEntryCount == 0 && conflictCount == 0
    }

}

public struct GitCompletionEvidenceAdapter: Sendable {
    public var executableURL: URL
    public var timeout: TimeInterval
    public var maximumOutputBytes: Int

    public init(
        executableURL: URL = URL(fileURLWithPath: "/usr/bin/git"),
        timeout: TimeInterval = 2,
        maximumOutputBytes: Int = 64 * 1_024
    ) {
        self.executableURL = executableURL
        self.timeout = max(0.1, timeout)
        self.maximumOutputBytes = max(1_024, maximumOutputBytes)
    }

    public func collect(
        for session: RelaySessionState,
        now: Date = Date()
    ) async -> [CompletionReviewEvidenceObservation] {
        guard let snapshot = await snapshot(for: session, now: now) else { return [] }
        return [snapshot.observation]
    }

    public func snapshot(
        for session: RelaySessionState,
        now: Date = Date()
    ) async -> GitEvidenceSnapshot? {
        guard let cwd = session.project.cwd,
              cwd.hasPrefix("/"),
              !cwd.contains("\0") else { return nil }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: cwd, isDirectory: &isDirectory),
              isDirectory.boolValue else { return nil }

        do {
            return try await readSnapshot(at: cwd, now: now)
        } catch {
            return nil
        }
    }

    func readSnapshot(at cwd: String, now: Date) async throws -> GitEvidenceSnapshot {
        let headData = try await runGit(
            cwd: cwd,
            arguments: ["rev-parse", "--verify", "HEAD^{commit}"]
        )
        guard let head = String(data: headData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              Self.isCommitIdentifier(head) else {
            throw GitEvidenceAdapterError.invalidOutput
        }
        let statusData = try await runGit(
            cwd: cwd,
            arguments: ["status", "--porcelain=v1", "-z", "--untracked-files=normal", "--ignore-submodules=all"]
        )
        let counts = try Self.parseStatus(statusData)
        return GitEvidenceSnapshot(
            headCommit: head,
            trackedChangeCount: counts.tracked,
            untrackedEntryCount: counts.untracked,
            conflictCount: counts.conflicts,
            observedAt: now
        )
    }

    private func runGit(cwd: String, arguments: [String]) async throws -> Data {
        let command = BoundedProcess(
            executableURL: executableURL,
            arguments: [
                "-c", "core.fsmonitor=false",
                "-c", "submodule.recurse=false",
                "-C", cwd
            ] + arguments,
            maximumOutputBytes: maximumOutputBytes,
            environment: [
                "PATH": "/usr/bin:/bin",
                "LANG": "C",
                "LC_ALL": "C",
                "GIT_TERMINAL_PROMPT": "0"
            ]
        )
        return try await command.run(deadline: Date().addingTimeInterval(timeout))
    }

    static func parseStatus(_ data: Data) throws -> (tracked: Int, untracked: Int, conflicts: Int) {
        let records = data.split(separator: 0, omittingEmptySubsequences: true)
        var tracked = 0
        var untracked = 0
        var conflicts = 0
        var index = 0
        while index < records.count {
            let record = records[index]
            guard record.count >= 3, record[record.startIndex.advanced(by: 2)] == 0x20 else {
                throw GitEvidenceAdapterError.invalidOutput
            }
            let x = record[record.startIndex]
            let y = record[record.startIndex.advanced(by: 1)]
            if x == 0x3F, y == 0x3F {
                untracked += 1
            } else {
                tracked += 1
                if Self.isConflict(x: x, y: y) { conflicts += 1 }
                if x == 0x52 || x == 0x43 { index += 1 }
            }
            index += 1
        }
        return (tracked, untracked, conflicts)
    }

    private static func isCommitIdentifier(_ value: String) -> Bool {
        (40...64).contains(value.count)
            && value.utf8.allSatisfy {
                (0x30...0x39).contains($0) || (0x61...0x66).contains($0) || (0x41...0x46).contains($0)
            }
    }

    private static func isConflict(x: UInt8, y: UInt8) -> Bool {
        let pair = String(bytes: [x, y], encoding: .ascii)
        return ["DD", "AU", "UD", "UA", "DU", "AA", "UU"].contains(pair)
    }
}

enum GitEvidenceAdapterError: Error {
    case invalidOutput
    case outputLimitExceeded
    case processFailed
    case timedOut
}

struct BoundedProcess: Sendable {
    private let executableURL: URL
    private let arguments: [String]
    private let maximumOutputBytes: Int
    private let environment: [String: String]
    private let currentDirectoryURL: URL?
    private let captureStandardError: Bool
    init(
        executableURL: URL,
        arguments: [String],
        maximumOutputBytes: Int,
        environment: [String: String],
        currentDirectoryURL: URL? = nil,
        captureStandardError: Bool = false
    ) {
        self.executableURL = executableURL
        self.arguments = arguments
        self.maximumOutputBytes = maximumOutputBytes
        self.environment = environment
        self.currentDirectoryURL = currentDirectoryURL
        self.captureStandardError = captureStandardError
    }

    func run(deadline: Date) async throws -> Data {
        let remaining = deadline.timeIntervalSinceNow
        guard remaining > 0 else { throw GitEvidenceAdapterError.timedOut }

        do {
            return try await withThrowingTaskGroup(of: Data.self) { group in
                group.addTask {
                    try await runSubprocess()
                }
                group.addTask {
                    try await Task.sleep(for: .seconds(remaining))
                    throw GitEvidenceAdapterError.timedOut
                }
                guard let first = try await group.next() else {
                    throw GitEvidenceAdapterError.processFailed
                }
                group.cancelAll()
                return first
            }
        } catch let error as GitEvidenceAdapterError {
            throw error
        } catch let error as SubprocessError where error.code == .outputLimitExceeded {
            throw GitEvidenceAdapterError.outputLimitExceeded
        } catch {
            throw GitEvidenceAdapterError.processFailed
        }
    }

    private func runSubprocess() async throws -> Data {
        var platformOptions = PlatformOptions()
        platformOptions.createSession = true
        platformOptions.teardownSequence = [
            .gracefulShutDown(
                toProcessGroup: true,
                allowedDurationToNextStep: .milliseconds(250)
            )
        ]
        let executable = Executable.path(FilePath(executableURL.path))
        let workingDirectory = currentDirectoryURL.map { FilePath($0.path) }
        let subprocessEnvironment = Environment.custom(
            Dictionary(uniqueKeysWithValues: environment.compactMap { key, value in
                Environment.Key(rawValue: key).map { ($0, value) }
            })
        )

        if captureStandardError {
            let result = try await Subprocess.run(
                executable,
                arguments: Arguments(arguments),
                environment: subprocessEnvironment,
                workingDirectory: workingDirectory,
                platformOptions: platformOptions,
                output: .data(limit: maximumOutputBytes),
                error: .combinedWithOutput
            )
            guard result.terminationStatus.isSuccess else {
                throw GitEvidenceAdapterError.processFailed
            }
            return result.standardOutput
        }

        let result = try await Subprocess.run(
            executable,
            arguments: Arguments(arguments),
            environment: subprocessEnvironment,
            workingDirectory: workingDirectory,
            platformOptions: platformOptions,
            output: .data(limit: maximumOutputBytes)
        )
        guard result.terminationStatus.isSuccess else {
            throw GitEvidenceAdapterError.processFailed
        }
        return result.standardOutput
    }
}
