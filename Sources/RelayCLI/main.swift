import Darwin
import Foundation
import RelayCore

@main
struct RelayCLI {
    static func main() async {
        let arguments = Array(CommandLine.arguments.dropFirst())
        let failOpen = arguments.contains("--fail-open")

        do {
            try await run(arguments)
        } catch {
            writeError("relayctl: \(error.localizedDescription)")
            if !failOpen {
                Foundation.exit(EXIT_FAILURE)
            }
        }
    }

    private static func run(_ arguments: [String]) async throws {
        guard let command = arguments.first else {
            printUsage()
            return
        }

        let commandArguments = Array(arguments.dropFirst())
        switch command {
        case "ingest":
            try ingest(commandArguments)
        case "emit":
            try emit(commandArguments)
        case "process":
            try process(commandArguments)
        case "daemon":
            try daemon(commandArguments)
        case "status":
            try status(commandArguments)
        case "paths":
            try paths(commandArguments)
        case "integration":
            try integration(commandArguments)
        case "doctor":
            try doctor(commandArguments)
        case "quota":
            try await quota(commandArguments)
        case "help", "--help", "-h":
            printUsage()
        default:
            throw CLIError.usage("unknown command '\(command)'")
        }
    }

    private static func ingest(_ arguments: [String]) throws {
        let parsed = try ParsedArguments(
            arguments,
            valueOptions: ["--source", "--store"],
            flags: ["--fail-open"]
        )
        let source = try requiredSource(parsed)
        let payload = FileHandle.standardInput.readDataToEndOfFile()
        guard !payload.isEmpty else {
            throw CLIError.usage("ingest expects one JSON object on stdin")
        }

        let event = try HookPayloadAdapter.decode(data: payload, source: source)
        let spool = EventSpool(root: try storeRoot(parsed))
        try spool.enqueue(event)
    }

    private static func emit(_ arguments: [String]) throws {
        let parsed = try ParsedArguments(
            arguments,
            valueOptions: [
                "--source", "--session", "--status", "--summary", "--event",
                "--turn", "--cwd", "--project", "--model", "--store",
                "--progress-completed", "--progress-total", "--progress-unit",
                "--evidence-kind", "--evidence-summary", "--evidence-id"
            ]
        )
        let source = try requiredSource(parsed)
        let sessionID = try parsed.requiredValue("--session")
        let rawStatus = try parsed.requiredValue("--status")
        guard let status = RelayStatus(rawValue: rawStatus) else {
            throw RelayError.unsupportedStatus(rawStatus)
        }

        var payload: [String: Any] = [
            "session_id": sessionID,
            "status": status.rawValue,
            "event_type": parsed.value("--event") ?? "relayctl_emit",
            "summary": parsed.value("--summary") ?? defaultSummary(source: source, status: status),
            "timestamp": Date().timeIntervalSince1970
        ]
        copyOption("--turn", to: "turn_id", from: parsed, into: &payload)
        copyOption("--cwd", to: "cwd", from: parsed, into: &payload)
        copyOption("--project", to: "project_name", from: parsed, into: &payload)
        copyOption("--model", to: "model", from: parsed, into: &payload)
        copyOption("--progress-completed", to: "progress_completed", from: parsed, into: &payload)
        copyOption("--progress-total", to: "progress_total", from: parsed, into: &payload)
        copyOption("--progress-unit", to: "progress_unit", from: parsed, into: &payload)
        copyOption("--evidence-kind", to: "evidence_kind", from: parsed, into: &payload)
        copyOption("--evidence-summary", to: "evidence_summary", from: parsed, into: &payload)
        copyOption("--evidence-id", to: "evidence_id", from: parsed, into: &payload)

        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        let event = try HookPayloadAdapter.decode(data: data, source: source)
        let file = try EventSpool(root: try storeRoot(parsed)).enqueue(event)
        print("queued \(event.id.uuidString.lowercased()) at \(file.path)")
    }

    private static func process(_ arguments: [String]) throws {
        let parsed = try ParsedArguments(arguments, valueOptions: ["--store"])
        let report = try RelayProcessor(root: try storeRoot(parsed)).processPending()
        print(
            "processed \(report.total): "
                + "applied=\(report.applied) duplicates=\(report.duplicates) "
                + "stale=\(report.stale) quarantined=\(report.quarantined)"
                + " cleaned=\(report.cleanedUp)"
        )
    }

    private static func daemon(_ arguments: [String]) throws {
        let parsed = try ParsedArguments(
            arguments,
            valueOptions: ["--store", "--interval-ms", "--max-passes"]
        )
        let root = try storeRoot(parsed)
        let interval = try positiveInteger(parsed.value("--interval-ms") ?? "250", option: "--interval-ms")
        let maxPasses = try parsed.value("--max-passes").map {
            try positiveInteger($0, option: "--max-passes")
        }
        let processor = RelayProcessor(root: root)
        let lease = try RelayProcessingLease(paths: processor.spool.paths)
        let healthStore = RelayDaemonHealthStore(paths: processor.spool.paths)
        var health = RelayDaemonHealth()

        while maxPasses == nil || health.passCount < maxPasses! {
            do {
                let report = try processor.processPending(holding: lease)
                health.record(report)
                if report.total > 0 {
                    print(
                        "daemon pass \(health.passCount): applied=\(report.applied) "
                            + "duplicates=\(report.duplicates) stale=\(report.stale) "
                            + "quarantined=\(report.quarantined)"
                            + " cleaned=\(report.cleanedUp)"
                    )
                }
            } catch {
                health.record(error: error)
                writeError("relayctl daemon: \(error.localizedDescription)")
            }
            try healthStore.persist(health)

            if maxPasses == nil || health.passCount < maxPasses! {
                Thread.sleep(forTimeInterval: Double(interval) / 1_000)
            }
        }
    }

    private static func status(_ arguments: [String]) throws {
        let parsed = try ParsedArguments(
            arguments,
            valueOptions: ["--store"],
            flags: ["--json"]
        )
        let root = try storeRoot(parsed)
        let snapshot = try RelayStateStore(paths: RelayStorePaths(root: root)).load()
        let sessions = snapshot.sessions.values.sorted {
            if $0.lastEventAt == $1.lastEventAt {
                return $0.key < $1.key
            }
            return $0.lastEventAt > $1.lastEventAt
        }

        if parsed.hasFlag("--json") {
            let output = StatusOutput(snapshot: snapshot, sessions: sessions)
            let data = try RelayJSON.makeEncoder(prettyPrinted: true).encode(output)
            guard let string = String(data: data, encoding: .utf8) else {
                throw CLIError.runtime("failed to encode status output")
            }
            print(string)
            return
        }

        print(
            "sessions=\(sessions.count) running=\(snapshot.runningCount) "
                + "attention=\(snapshot.attentionRequiredCount) "
                + "review=\(snapshot.readyToReviewCount) completed=\(snapshot.completedCount)"
        )
        for session in sessions {
            let project = session.project.name.map { " [\($0)]" } ?? ""
            print("\(session.source.rawValue)/\(session.sessionID) \(session.status.rawValue)\(project) — \(session.summary)")
        }
    }

    private static func paths(_ arguments: [String]) throws {
        let parsed = try ParsedArguments(arguments, valueOptions: ["--store"])
        let relayPaths = RelayStorePaths(root: try storeRoot(parsed))
        print("root: \(relayPaths.root.path)")
        print("inbox: \(relayPaths.inbox.path)")
        print("archive: \(relayPaths.archive.path)")
        print("quarantine: \(relayPaths.quarantine.path)")
        print("state: \(relayPaths.snapshot.path)")
        print("daemon health: \(relayPaths.daemonHealth.path)")
    }

    private static func integration(_ arguments: [String]) throws {
        guard let action = arguments.first else {
            throw CLIError.usage("integration requires preview, install, or uninstall")
        }
        let parsed = try ParsedArguments(
            Array(arguments.dropFirst()),
            valueOptions: [
                "--store", "--executable", "--codex-config", "--claude-config", "--launch-agent"
            ],
            flags: ["--apply", "--skip-launchctl"]
        )
        let layout = try installationLayout(parsed)
        let installer = IntegrationInstaller(layout: layout)

        switch action {
        case "preview":
            try printInstallationPreview(installer.preview(operation: .install))
        case "install":
            let preview = try installer.preview(operation: .install)
            try printInstallationPreview(preview)
            guard parsed.hasFlag("--apply") else {
                print("preview only; rerun with --apply to write these changes")
                return
            }
            let receipt = try installer.install()
            if !parsed.hasFlag("--skip-launchctl") {
                do {
                    try activateLaunchAgent(at: layout.launchAgent)
                } catch {
                    try? installer.rollback(receipt)
                    if preview.launchAgentOriginalData != nil {
                        try? activateLaunchAgent(at: layout.launchAgent)
                    }
                    throw CLIError.runtime(
                        "LaunchAgent activation failed; installation files were rolled back. "
                            + "Backup: \(receipt.backupDirectory.path). \(error.localizedDescription)"
                    )
                }
            }
            print("installed; backup: \(receipt.backupDirectory.path)")
        case "uninstall":
            let preview = try installer.preview(operation: .uninstall)
            try printInstallationPreview(preview)
            guard parsed.hasFlag("--apply") else {
                print("preview only; rerun with --apply to write these changes")
                return
            }
            if !parsed.hasFlag("--skip-launchctl") {
                deactivateLaunchAgent(at: layout.launchAgent)
            }
            let receipt: InstallationReceipt
            do {
                receipt = try installer.uninstall()
            } catch {
                if !parsed.hasFlag("--skip-launchctl"), FileManager.default.fileExists(atPath: layout.launchAgent.path) {
                    try? activateLaunchAgent(at: layout.launchAgent)
                }
                throw error
            }
            print("uninstalled owned files and handlers; backup: \(receipt.backupDirectory.path)")
        default:
            throw CLIError.usage("unknown integration action '\(action)'")
        }
    }

    private static func doctor(_ arguments: [String]) throws {
        let parsed = try ParsedArguments(
            arguments,
            valueOptions: [
                "--store", "--executable", "--codex-config", "--claude-config", "--launch-agent"
            ],
            flags: ["--json"]
        )
        let layout = try installationLayout(parsed)
        let fileManager = FileManager.default
        var checks: [DoctorCheck] = []
        checks.append(DoctorCheck(
            name: "installed executable",
            passed: fileManager.isExecutableFile(atPath: layout.installedExecutable.path),
            detail: layout.installedExecutable.path
        ))
        checks.append(DoctorCheck(
            name: "LaunchAgent",
            passed: fileManager.fileExists(atPath: layout.launchAgent.path),
            detail: layout.launchAgent.path
        ))
        checks.append(configurationDoctorCheck(target: .codex, file: layout.codexConfiguration, expected: 6))
        checks.append(configurationDoctorCheck(target: .claude, file: layout.claudeConfiguration, expected: 8))

        let healthStore = RelayDaemonHealthStore(paths: RelayStorePaths(root: layout.storeRoot))
        do {
            if let health = try healthStore.load() {
                let age = Date().timeIntervalSince(health.lastPassAt)
                let probe = Darwin.kill(health.processID, 0)
                let processIsAlive = probe == 0 || Darwin.errno == EPERM
                checks.append(DoctorCheck(
                    name: "daemon heartbeat",
                    passed: age <= 5 && health.lastError == nil && processIsAlive,
                    detail: health.lastError
                        ?? "last pass \(String(format: "%.2f", age))s ago; pid=\(health.processID); alive=\(processIsAlive)"
                ))
            } else {
                checks.append(DoctorCheck(name: "daemon heartbeat", passed: false, detail: "daemon.json is missing"))
            }
        } catch {
            checks.append(DoctorCheck(name: "daemon heartbeat", passed: false, detail: error.localizedDescription))
        }

        if parsed.hasFlag("--json") {
            let data = try RelayJSON.makeEncoder(prettyPrinted: true).encode(DoctorOutput(checks: checks))
            print(String(decoding: data, as: UTF8.self))
        } else {
            for check in checks {
                print("\(check.passed ? "PASS" : "FAIL")  \(check.name) — \(check.detail)")
            }
        }
        if checks.contains(where: { !$0.passed }) {
            Foundation.exit(EXIT_FAILURE)
        }
    }

    private static func quota(_ arguments: [String]) async throws {
        let parsed = try ParsedArguments(arguments, valueOptions: [], flags: ["--json"])
        let snapshot: AgentQuotaSnapshot
        do {
            snapshot = try await CodexQuotaProbe().fetch()
        } catch let error as CodexQuotaProbeError {
            throw CLIError.runtime("Codex quota probe failed safely (\(error)).")
        }

        if parsed.hasFlag("--json") {
            let data = try RelayJSON.makeEncoder(prettyPrinted: true).encode(snapshot)
            print(String(decoding: data, as: UTF8.self))
            return
        }

        print("Codex quota · plan=\(snapshot.plan ?? "unknown")")
        for window in snapshot.windows {
            let reset = window.resetsAt.map { " · resets \($0.formatted())" } ?? ""
            print("\(window.displayName): \(Int(window.remainingPercent.rounded()))% remaining\(reset)")
        }
        if snapshot.creditsUnlimited {
            print("Codex credits: unlimited")
        } else if let credits = snapshot.creditsRemaining {
            print("Codex credits: \(credits.formatted(.number.precision(.fractionLength(0...2))))")
        }
    }

    private static func requiredSource(_ arguments: ParsedArguments) throws -> AgentSource {
        let rawSource = try arguments.requiredValue("--source")
        guard let source = AgentSource(rawValue: rawSource) else {
            throw RelayError.unsupportedSource(rawSource)
        }
        return source
    }

    private static func storeRoot(_ arguments: ParsedArguments) throws -> URL {
        if let rawPath = arguments.value("--store") {
            let expanded = (rawPath as NSString).expandingTildeInPath
            guard expanded.hasPrefix("/") else {
                throw CLIError.usage("--store must be an absolute path")
            }
            return URL(fileURLWithPath: expanded, isDirectory: true)
        }
        return try RelayStorePaths.defaultRoot()
    }

    private static func installationLayout(_ arguments: ParsedArguments) throws -> InstallationLayout {
        let root = try storeRoot(arguments)
        let currentExecutable = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        let sourceExecutable = try absoluteURL(
            arguments.value("--executable") ?? currentExecutable.path,
            option: "--executable"
        )
        var layout = InstallationLayout.defaults(sourceExecutable: sourceExecutable, storeRoot: root)
        if let value = arguments.value("--codex-config") {
            layout.codexConfiguration = try absoluteURL(value, option: "--codex-config")
        }
        if let value = arguments.value("--claude-config") {
            layout.claudeConfiguration = try absoluteURL(value, option: "--claude-config")
        }
        if let value = arguments.value("--launch-agent") {
            layout.launchAgent = try absoluteURL(value, option: "--launch-agent")
        }
        return layout
    }

    private static func absoluteURL(_ path: String, option: String) throws -> URL {
        let expanded = (path as NSString).expandingTildeInPath
        guard expanded.hasPrefix("/") else {
            throw CLIError.usage("\(option) must be an absolute path")
        }
        return URL(fileURLWithPath: expanded)
    }

    private static func positiveInteger(_ value: String, option: String) throws -> Int {
        guard let integer = Int(value), integer > 0 else {
            throw CLIError.usage("\(option) must be a positive integer")
        }
        return integer
    }

    private static func printInstallationPreview(_ preview: InstallationPreview) throws {
        print("operation: \(preview.operation.rawValue)")
        print("binary: \(preview.layout.sourceExecutable.path) -> \(preview.layout.installedExecutable.path)")
        print("binary change: \(preview.executableWillChange ? "yes" : "no")")
        for edit in preview.configurationEdits {
            print("\n[\(edit.target.rawValue)] \(edit.changed ? "change" : "unchanged")")
            if !edit.diff.isEmpty { print(edit.diff, terminator: "") }
        }
        print("\n[launch-agent] \(preview.launchAgentOriginalData == preview.launchAgentProposedData ? "unchanged" : "change")")
        if !preview.launchAgentDiff.isEmpty { print(preview.launchAgentDiff, terminator: "") }
    }

    private static func configurationDoctorCheck(
        target: IntegrationTarget,
        file: URL,
        expected: Int
    ) -> DoctorCheck {
        do {
            let data = try Data(contentsOf: file)
            let count = try HookConfigurationEditor.managedHandlerCount(in: data, file: file)
            return DoctorCheck(
                name: "\(target.rawValue) Hook ownership",
                passed: count == expected,
                detail: "managed=\(count), expected=\(expected); \(file.path)"
            )
        } catch {
            return DoctorCheck(
                name: "\(target.rawValue) Hook ownership",
                passed: false,
                detail: error.localizedDescription
            )
        }
    }

    private static func activateLaunchAgent(at plist: URL) throws {
        deactivateLaunchAgent(at: plist)
        let domain = "gui/\(getuid())"
        try runLaunchctl(["bootstrap", domain, plist.path], tolerateFailure: false)
        try runLaunchctl(
            ["kickstart", "-k", "\(domain)/\(IntegrationInstaller.launchAgentLabel)"],
            tolerateFailure: false
        )
    }

    private static func deactivateLaunchAgent(at plist: URL) {
        try? runLaunchctl(["bootout", "gui/\(getuid())", plist.path], tolerateFailure: true)
    }

    private static func runLaunchctl(_ arguments: [String], tolerateFailure: Bool) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        let errorPipe = Pipe()
        process.standardOutput = Pipe()
        process.standardError = errorPipe
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 || tolerateFailure else {
            let data = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let message = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            throw CLIError.runtime(message ?? "launchctl failed with status \(process.terminationStatus)")
        }
    }

    private static func copyOption(
        _ option: String,
        to key: String,
        from arguments: ParsedArguments,
        into payload: inout [String: Any]
    ) {
        if let value = arguments.value(option) {
            payload[key] = value
        }
    }

    private static func defaultSummary(source: AgentSource, status: RelayStatus) -> String {
        let name = source.rawValue.capitalized
        return switch status {
        case .running: "\(name) is running"
        case .needsInput: "\(name) is waiting for input"
        case .needsPermission: "\(name) requires permission"
        case .readyToReview: "\(name) result is ready to review"
        case .failed: "\(name) failed"
        case .completed: "\(name) completed"
        case .cancelled: "\(name) was cancelled"
        case .ended: "\(name) session ended"
        }
    }

    private static func printUsage() {
        print(
            """
            relayctl — local Agent attention event relay

            Usage:
              relayctl ingest --source codex|claude|generic [--store PATH] [--fail-open]
              relayctl emit --source SOURCE --session ID --status STATUS [--summary TEXT] [--store PATH]
              relayctl process [--store PATH]
              relayctl daemon [--store PATH] [--interval-ms 250]
              relayctl status [--store PATH] [--json]
              relayctl paths [--store PATH]
              relayctl integration preview [path overrides]
              relayctl integration install [path overrides] [--apply]
              relayctl integration uninstall [path overrides] [--apply]
              relayctl doctor [path overrides] [--json]
              relayctl quota [--json]

            Statuses: running, needs_input, needs_permission, ready_to_review, failed, completed, cancelled, ended
            """
        )
    }

    private static func writeError(_ message: String) {
        guard let data = "\(message)\n".data(using: .utf8) else { return }
        FileHandle.standardError.write(data)
    }
}

private struct ParsedArguments {
    private var values: [String: String] = [:]
    private var enabledFlags: Set<String> = []

    init(_ arguments: [String], valueOptions: Set<String>, flags: Set<String> = []) throws {
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            if flags.contains(argument) {
                enabledFlags.insert(argument)
                index += 1
                continue
            }
            guard valueOptions.contains(argument) else {
                throw CLIError.usage("unknown argument '\(argument)'")
            }
            guard values[argument] == nil else {
                throw CLIError.usage("argument '\(argument)' was provided more than once")
            }
            let valueIndex = index + 1
            guard valueIndex < arguments.count, !arguments[valueIndex].hasPrefix("--") else {
                throw RelayError.missingArgument(argument)
            }
            values[argument] = arguments[valueIndex]
            index += 2
        }
    }

    func value(_ option: String) -> String? {
        values[option]
    }

    func requiredValue(_ option: String) throws -> String {
        guard let value = values[option], !value.isEmpty else {
            throw RelayError.missingArgument(option)
        }
        return value
    }

    func hasFlag(_ flag: String) -> Bool {
        enabledFlags.contains(flag)
    }
}

private struct StatusOutput: Codable {
    var schemaVersion: Int
    var updatedAt: Date
    var counts: StatusCounts
    var sessions: [RelaySessionState]

    init(snapshot: RelaySnapshot, sessions: [RelaySessionState]) {
        schemaVersion = snapshot.schemaVersion
        updatedAt = snapshot.updatedAt
        counts = StatusCounts(
            sessions: sessions.count,
            running: snapshot.runningCount,
            attentionRequired: snapshot.attentionRequiredCount,
            readyToReview: snapshot.readyToReviewCount,
            completed: snapshot.completedCount
        )
        self.sessions = sessions
    }
}

private struct StatusCounts: Codable {
    var sessions: Int
    var running: Int
    var attentionRequired: Int
    var readyToReview: Int
    var completed: Int
}

private struct DoctorCheck: Codable {
    var name: String
    var passed: Bool
    var detail: String
}

private struct DoctorOutput: Codable {
    var checks: [DoctorCheck]
    var passed: Bool

    init(checks: [DoctorCheck]) {
        self.checks = checks
        passed = checks.allSatisfy(\.passed)
    }
}

private enum CLIError: LocalizedError {
    case usage(String)
    case runtime(String)

    var errorDescription: String? {
        switch self {
        case .usage(let message): "Usage error: \(message)"
        case .runtime(let message): "Runtime error: \(message)"
        }
    }
}
