import Darwin
import Foundation

public struct CodexCurrentTask: Equatable, Sendable {
    public var sessionID: String
    public var title: String
    public var titleUpdatedAt: Date?
    public var observedAt: Date

    public init(
        sessionID: String,
        title: String,
        titleUpdatedAt: Date? = nil,
        observedAt: Date = Date()
    ) {
        self.sessionID = sessionID
        self.title = title
        self.titleUpdatedAt = titleUpdatedAt
        self.observedAt = observedAt
    }

    public var sessionKey: String {
        "\(AgentSource.codex.rawValue):\(sessionID)"
    }
}

public enum CodexCurrentTaskAvailability: Equatable, Sendable {
    case checking
    case current
    case reconnecting
    case unavailable
}

public struct CodexCurrentTaskObservation: Equatable, Sendable {
    public private(set) var lastSuccessfulTasks: [CodexCurrentTask]
    public private(set) var lastSuccessAt: Date?
    public private(set) var lastAttemptAt: Date?
    public private(set) var lastAttemptSucceeded: Bool?

    public init() {
        lastSuccessfulTasks = []
        lastSuccessAt = nil
        lastAttemptAt = nil
        lastAttemptSucceeded = nil
    }

    public mutating func recordSuccess(_ tasks: [CodexCurrentTask], at date: Date) {
        lastSuccessfulTasks = tasks
        lastSuccessAt = date
        lastAttemptAt = date
        lastAttemptSucceeded = true
    }

    public mutating func recordFailure(at date: Date) {
        lastAttemptAt = date
        lastAttemptSucceeded = false
    }

    public func resolve(
        now: Date,
        staleGraceInterval: TimeInterval = 6
    ) -> CodexCurrentTaskObservationResolution {
        guard let lastAttemptSucceeded else {
            return CodexCurrentTaskObservationResolution(
                tasks: [],
                availability: .checking
            )
        }
        if lastAttemptSucceeded {
            return CodexCurrentTaskObservationResolution(
                tasks: lastSuccessfulTasks,
                availability: .current
            )
        }
        if let lastSuccessAt,
           now.timeIntervalSince(lastSuccessAt) <= max(0, staleGraceInterval) {
            return CodexCurrentTaskObservationResolution(
                tasks: lastSuccessfulTasks,
                availability: .reconnecting
            )
        }
        return CodexCurrentTaskObservationResolution(
            tasks: [],
            availability: .unavailable
        )
    }
}

public struct CodexCurrentTaskObservationResolution: Equatable, Sendable {
    public var tasks: [CodexCurrentTask]
    public var availability: CodexCurrentTaskAvailability

    public init(tasks: [CodexCurrentTask], availability: CodexCurrentTaskAvailability) {
        self.tasks = tasks
        self.availability = availability
    }
}

public enum CodexCurrentTaskProbeError: Error, Equatable, Sendable {
    case sourceUnavailable
    case invalidSource
    case timedOut
    case frameLimitExceeded
    case malformedResponse
}

public struct CodexCurrentTaskProbeConfiguration: Sendable {
    public var sessionIndex: URL
    public var writerLocksDirectory: URL
    public var ipcSocket: URL
    public var timeout: TimeInterval
    public var maximumInputBytes: Int
    public var maximumCandidates: Int

    public init(
        sessionIndex: URL,
        writerLocksDirectory: URL,
        ipcSocket: URL,
        timeout: TimeInterval = 2,
        maximumInputBytes: Int = 2 * 1_024 * 1_024,
        maximumCandidates: Int = 512
    ) {
        self.sessionIndex = sessionIndex.standardizedFileURL
        self.writerLocksDirectory = writerLocksDirectory.standardizedFileURL
        self.ipcSocket = ipcSocket.standardizedFileURL
        self.timeout = min(max(timeout, 0.2), 8)
        self.maximumInputBytes = min(max(maximumInputBytes, 1_024), 8 * 1_024 * 1_024)
        self.maximumCandidates = min(max(maximumCandidates, 1), 512)
    }

    public static func defaults(fileManager: FileManager = .default) -> Self {
        let root = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex", isDirectory: true)
        return Self(
            sessionIndex: root.appendingPathComponent("session_index.jsonl"),
            writerLocksDirectory: root.appendingPathComponent("thread-writer-locks", isDirectory: true),
            ipcSocket: root.appendingPathComponent("ipc/ipc.sock")
        )
    }
}

/// Finds interactive Codex tasks currently loaded by the desktop app.
/// Candidate identity comes from actively held writer locks, display names come
/// from the title-only session index, and desktop IPC is an optional ownership
/// refinement. The bounded local candidate set remains usable when that private
/// IPC edge is unavailable.
public struct CodexCurrentTaskProbe: Sendable {
    public let configuration: CodexCurrentTaskProbeConfiguration

    public init(configuration: CodexCurrentTaskProbeConfiguration = .defaults()) {
        self.configuration = configuration
    }

    public func fetch(now: Date = Date()) async throws -> [CodexCurrentTask] {
        let configuration = configuration
        return try await Task.detached(priority: .utility) {
            let candidates = try Self.readCandidates(configuration: configuration)
            guard !candidates.isEmpty else { return [] }

            let refinedCandidates: [CodexCurrentTask]
            do {
                let client = try CodexDesktopIPCClient(configuration: configuration)
                defer { client.close() }
                let ownedIDs = try client.ownedSessionIDs(
                    candidates.map(\.sessionID),
                    deadline: Date().addingTimeInterval(configuration.timeout)
                )
                refinedCandidates = candidates.filter { ownedIDs.contains($0.sessionID) }
            } catch {
                refinedCandidates = candidates
            }

            return Self.deduplicateTitles(refinedCandidates)
                .map { CodexCurrentTask(
                    sessionID: $0.sessionID,
                    title: $0.title,
                    titleUpdatedAt: $0.titleUpdatedAt,
                    observedAt: now
                ) }
                .sorted { lhs, rhs in
                    if lhs.title == rhs.title { return lhs.sessionID < rhs.sessionID }
                    return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
                }
        }.value
    }

    static func readCandidates(
        configuration: CodexCurrentTaskProbeConfiguration,
        fileManager: FileManager = .default
    ) throws -> [CodexCurrentTask] {
        guard fileManager.fileExists(atPath: configuration.writerLocksDirectory.path),
              fileManager.fileExists(atPath: configuration.sessionIndex.path) else {
            throw CodexCurrentTaskProbeError.sourceUnavailable
        }

        let lockFiles = try fileManager.contentsOfDirectory(
            at: configuration.writerLocksDirectory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )
        let candidateIDs = Set(try lockFiles.compactMap { file -> String? in
            guard file.pathExtension == "lock" else { return nil }
            let id = file.deletingPathExtension().lastPathComponent
            guard UUID(uuidString: id) != nil,
                  try isLockHeldByAnotherProcess(file) else { return nil }
            return id.lowercased()
        }.sorted().prefix(configuration.maximumCandidates))
        guard !candidateIDs.isEmpty else { return [] }

        let attributes = try fileManager.attributesOfItem(atPath: configuration.sessionIndex.path)
        guard let size = attributes[.size] as? NSNumber,
              size.intValue <= configuration.maximumInputBytes else {
            throw CodexCurrentTaskProbeError.invalidSource
        }
        let data = try Data(contentsOf: configuration.sessionIndex, options: [.mappedIfSafe])
        guard data.count <= configuration.maximumInputBytes,
              let text = String(data: data, encoding: .utf8) else {
            throw CodexCurrentTaskProbeError.invalidSource
        }

        let decoder = JSONDecoder()
        var tasksByID: [String: CodexCurrentTask] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            guard let lineData = String(line).data(using: .utf8),
                  let entry = try? decoder.decode(CodexTaskIndexEntry.self, from: lineData),
                  candidateIDs.contains(entry.id.lowercased()),
                  let title = safeTitle(entry.threadName) else { continue }
            tasksByID[entry.id.lowercased()] = CodexCurrentTask(
                sessionID: entry.id.lowercased(),
                title: title,
                titleUpdatedAt: entry.updatedAt.flatMap(Self.parseDate),
                observedAt: .distantPast
            )
        }
        return Array(tasksByID.values)
    }

    static func deduplicateTitles(_ tasks: [CodexCurrentTask]) -> [CodexCurrentTask] {
        var byTitle: [String: CodexCurrentTask] = [:]
        for task in tasks {
            let key = task.title.folding(
                options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                locale: .current
            )
            guard let existing = byTitle[key] else {
                byTitle[key] = task
                continue
            }
            let existingDate = existing.titleUpdatedAt ?? .distantPast
            let candidateDate = task.titleUpdatedAt ?? .distantPast
            if candidateDate > existingDate
                || (candidateDate == existingDate && task.sessionID > existing.sessionID) {
                byTitle[key] = task
            }
        }
        return Array(byTitle.values)
    }

    private static func parseDate(_ value: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: value) { return date }
        return ISO8601DateFormatter().date(from: value)
    }

    private static func isLockHeldByAnotherProcess(_ file: URL) throws -> Bool {
        var pathInfo = stat()
        guard lstat(file.path, &pathInfo) == 0,
              pathInfo.st_uid == geteuid(),
              pathInfo.st_mode & S_IFMT == S_IFREG,
              pathInfo.st_mode & (S_IWGRP | S_IWOTH) == 0 else {
            throw CodexCurrentTaskProbeError.invalidSource
        }

        let fd = Darwin.open(file.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw CodexCurrentTaskProbeError.sourceUnavailable }
        defer { Darwin.close(fd) }

        var descriptorInfo = stat()
        guard fstat(fd, &descriptorInfo) == 0,
              descriptorInfo.st_dev == pathInfo.st_dev,
              descriptorInfo.st_ino == pathInfo.st_ino else {
            throw CodexCurrentTaskProbeError.invalidSource
        }

        errno = 0
        if flock(fd, LOCK_EX | LOCK_NB) == 0 {
            _ = flock(fd, LOCK_UN)
            return false
        }
        if errno == EWOULDBLOCK || errno == EAGAIN {
            return true
        }
        throw CodexCurrentTaskProbeError.sourceUnavailable
    }

    private static func safeTitle(_ value: String) -> String? {
        let collapsed = value.unicodeScalars
            .filter { $0.value >= 0x20 && $0.value != 0x7F }
            .map(String.init)
            .joined()
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard !collapsed.isEmpty else { return nil }
        return String(collapsed.prefix(120))
    }
}

public struct CodexCurrentTaskReconciliation: Equatable, Sendable {
    public var snapshot: RelaySnapshot
    public var metadata: [String: LocalTaskMetadata]
    public var currentSessionKeys: Set<String>
    public var isAuthoritative: Bool
}

public enum CodexCurrentTaskPresentation {
    public static func reconcile(
        snapshot: RelaySnapshot,
        currentTasks: [CodexCurrentTask],
        now: Date = Date()
    ) -> CodexCurrentTaskReconciliation {
        var presented = snapshot
        var metadata: [String: LocalTaskMetadata] = [:]
        let boundedTasks = Array(currentTasks.prefix(512))
        for task in boundedTasks {
            let key = task.sessionKey
            metadata[key] = LocalTaskMetadata(taskTitle: task.title, showsProjectPrefix: false)
            if var existing = presented.sessions[key] {
                if existing.status == .ended {
                    existing.status = .running
                    existing.attention = AttentionPolicy.level(for: .running)
                    existing.terminalAt = nil
                    existing.lastEventAt = max(existing.lastEventAt, task.observedAt)
                    existing.summary = "Codex 当前任务正在进行"
                    presented.sessions[key] = existing
                }
                continue
            }

            let eventID = UUID(uuidString: task.sessionID) ?? UUID()
            presented.sessions[key] = RelaySessionState(event: RelayEvent(
                id: eventID,
                source: .codex,
                sourceEvent: "CodexDesktopCurrentTask",
                sessionID: task.sessionID,
                status: .running,
                summary: "Codex 当前任务正在进行",
                occurredAt: task.observedAt == .distantPast ? now : task.observedAt,
                receivedAt: now
            ))
        }

        return CodexCurrentTaskReconciliation(
            snapshot: presented,
            metadata: metadata,
            currentSessionKeys: Set(boundedTasks.map(\.sessionKey)),
            isAuthoritative: true
        )
    }
}

private struct CodexTaskIndexEntry: Decodable {
    var id: String
    var threadName: String
    var updatedAt: String?

    private enum CodingKeys: String, CodingKey {
        case id
        case threadName = "thread_name"
        case updatedAt = "updated_at"
    }
}

private final class CodexDesktopIPCClient: @unchecked Sendable {
    private let fileDescriptor: Int32
    private let maximumFrameBytes = 64 * 1_024
    private var clientID = ""

    init(configuration: CodexCurrentTaskProbeConfiguration) throws {
        try Self.validateSocket(configuration.ipcSocket)
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw CodexCurrentTaskProbeError.sourceUnavailable }
        fileDescriptor = fd

        var timeout = timeval(
            tv_sec: Int(configuration.timeout),
            tv_usec: Int32((configuration.timeout.truncatingRemainder(dividingBy: 1)) * 1_000_000)
        )
        _ = withUnsafePointer(to: &timeout) {
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, $0, socklen_t(MemoryLayout<timeval>.size))
        }
        _ = withUnsafePointer(to: &timeout) {
            setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, $0, socklen_t(MemoryLayout<timeval>.size))
        }

        do {
            try Self.connect(fd: fd, path: configuration.ipcSocket.path)
            clientID = try initialize(deadline: Date().addingTimeInterval(configuration.timeout))
        } catch {
            Darwin.close(fd)
            throw error
        }
    }

    func close() {
        Darwin.close(fileDescriptor)
    }

    func ownedSessionIDs(_ sessionIDs: [String], deadline: Date) throws -> Set<String> {
        var owned = Set<String>()
        for sessionID in sessionIDs {
            guard Date() < deadline else { throw CodexCurrentTaskProbeError.timedOut }
            let requestID = UUID().uuidString
            try writeFrame([
                "type": "request",
                "requestId": requestID,
                "sourceClientId": clientID,
                "method": "thread-owner-discovery",
                "version": 1,
                "params": ["hostId": "local", "conversationId": sessionID],
                "timeoutMs": max(100, Int(deadline.timeIntervalSinceNow * 1_000))
            ])
            let response = try readResponse(requestID: requestID, deadline: deadline)
            if response["resultType"] as? String == "success",
               response["handledByClientId"] as? String != nil {
                owned.insert(sessionID)
            } else if response["resultType"] as? String == "error" {
                throw CodexCurrentTaskProbeError.sourceUnavailable
            } else {
                throw CodexCurrentTaskProbeError.malformedResponse
            }
        }
        return owned
    }

    private func initialize(deadline: Date) throws -> String {
        let requestID = UUID().uuidString
        try writeFrame([
            "type": "request",
            "requestId": requestID,
            "method": "initialize",
            "version": 0,
            "params": ["clientType": "notch-relay-observer"],
            "timeoutMs": 1_000
        ])
        let response = try readResponse(requestID: requestID, deadline: deadline)
        guard response["resultType"] as? String == "success",
              let result = response["result"] as? [String: Any],
              let clientID = result["clientId"] as? String,
              UUID(uuidString: clientID) != nil else {
            throw CodexCurrentTaskProbeError.malformedResponse
        }
        return clientID
    }

    private func readResponse(requestID: String, deadline: Date) throws -> [String: Any] {
        for _ in 0..<128 {
            guard Date() < deadline else { throw CodexCurrentTaskProbeError.timedOut }
            let message = try readFrame()
            if message["type"] as? String == "client-discovery-request",
               let discoveryID = message["requestId"] as? String {
                try writeFrame([
                    "type": "client-discovery-response",
                    "requestId": discoveryID,
                    "response": ["canHandle": false]
                ])
                continue
            }
            if message["type"] as? String == "response",
               message["requestId"] as? String == requestID {
                return message
            }
        }
        throw CodexCurrentTaskProbeError.malformedResponse
    }

    private func writeFrame(_ object: [String: Any]) throws {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object),
              data.count <= maximumFrameBytes else {
            throw CodexCurrentTaskProbeError.frameLimitExceeded
        }
        var length = UInt32(data.count).littleEndian
        try withUnsafeBytes(of: &length) { try writeAll($0) }
        try data.withUnsafeBytes { try writeAll($0) }
    }

    private func readFrame() throws -> [String: Any] {
        var length = UInt32(0)
        try withUnsafeMutableBytes(of: &length) { try readAll($0) }
        let byteCount = Int(UInt32(littleEndian: length))
        guard byteCount > 0, byteCount <= maximumFrameBytes else {
            throw CodexCurrentTaskProbeError.frameLimitExceeded
        }
        var data = Data(count: byteCount)
        try data.withUnsafeMutableBytes { try readAll($0) }
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let message = object as? [String: Any] else {
            throw CodexCurrentTaskProbeError.malformedResponse
        }
        return message
    }

    private func writeAll(_ buffer: UnsafeRawBufferPointer) throws {
        guard let base = buffer.baseAddress else { return }
        var offset = 0
        while offset < buffer.count {
            let written = Darwin.write(fileDescriptor, base.advanced(by: offset), buffer.count - offset)
            if written > 0 {
                offset += written
            } else if errno == EAGAIN || errno == EWOULDBLOCK {
                throw CodexCurrentTaskProbeError.timedOut
            } else {
                throw CodexCurrentTaskProbeError.sourceUnavailable
            }
        }
    }

    private func readAll(_ buffer: UnsafeMutableRawBufferPointer) throws {
        guard let base = buffer.baseAddress else { return }
        var offset = 0
        while offset < buffer.count {
            let count = Darwin.read(fileDescriptor, base.advanced(by: offset), buffer.count - offset)
            if count > 0 {
                offset += count
            } else if count == 0 {
                throw CodexCurrentTaskProbeError.sourceUnavailable
            } else if errno == EAGAIN || errno == EWOULDBLOCK {
                throw CodexCurrentTaskProbeError.timedOut
            } else {
                throw CodexCurrentTaskProbeError.sourceUnavailable
            }
        }
    }

    private static func connect(fd: Int32, path: String) throws {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8CString)
        guard pathBytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
            throw CodexCurrentTaskProbeError.invalidSource
        }
        withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: pathBytes.count) { destination in
                _ = pathBytes.withUnsafeBufferPointer { source in
                    memcpy(destination, source.baseAddress, pathBytes.count)
                }
            }
        }
        let length = socklen_t(MemoryLayout<sa_family_t>.size + pathBytes.count)
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, length)
            }
        }
        guard result == 0 else { throw CodexCurrentTaskProbeError.sourceUnavailable }
    }

    private static func validateSocket(_ socketURL: URL) throws {
        var socketInfo = stat()
        guard lstat(socketURL.path, &socketInfo) == 0,
              socketInfo.st_uid == geteuid(),
              socketInfo.st_mode & S_IFMT == S_IFSOCK else {
            throw CodexCurrentTaskProbeError.sourceUnavailable
        }

        var directoryInfo = stat()
        let directory = socketURL.deletingLastPathComponent()
        guard lstat(directory.path, &directoryInfo) == 0,
              directoryInfo.st_uid == geteuid(),
              directoryInfo.st_mode & S_IFMT == S_IFDIR,
              directoryInfo.st_mode & (S_IWGRP | S_IWOTH) == 0 else {
            throw CodexCurrentTaskProbeError.sourceUnavailable
        }
    }
}
