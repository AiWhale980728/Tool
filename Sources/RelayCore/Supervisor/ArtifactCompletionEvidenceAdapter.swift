import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum CompletionArtifactFormat: String, CaseIterable, Sendable {
    case pdf = "PDF"
    case png = "PNG"
    case jpeg = "JPEG"
    case json = "JSON"
    case zip = "ZIP"
}

public enum CompletionArtifactSizeBucket: String, CaseIterable, Sendable {
    case upTo64KiB = "不超过 64 KiB"
    case upTo1MiB = "64 KiB 至 1 MiB"
    case upTo8MiB = "1 MiB 至 8 MiB"
    case upTo32MiB = "8 MiB 至 32 MiB"

    public init(byteCount: Int) {
        switch byteCount {
        case ...(64 * 1_024):
            self = .upTo64KiB
        case ...(1_024 * 1_024):
            self = .upTo1MiB
        case ...(8 * 1_024 * 1_024):
            self = .upTo8MiB
        default:
            self = .upTo32MiB
        }
    }
}

public struct CompletionArtifactDescriptor: Equatable, Sendable {
    public var format: CompletionArtifactFormat
    public var sizeBucket: CompletionArtifactSizeBucket
    public var byteCount: Int
    public var sha256: String

    public init(
        format: CompletionArtifactFormat,
        sizeBucket: CompletionArtifactSizeBucket,
        byteCount: Int,
        sha256: String
    ) {
        self.format = format
        self.sizeBucket = sizeBucket
        self.byteCount = byteCount
        self.sha256 = sha256
    }

    public var disclosureSummary: String {
        "交付物证据：\(format.rawValue)，\(sizeBucket.rawValue)。"
    }

    public func observation(observedAt: Date) -> CompletionReviewEvidenceObservation {
        CompletionReviewEvidenceObservation(
            kind: .artifactProduced,
            source: EvidenceSource(kind: .tool, sourceID: "relay-local-artifact-validation-v1"),
            summary: disclosureSummary,
            reference: "artifact-sha256:\(sha256)",
            observedAt: observedAt,
            dataLevel: .l1StructuredEvidence,
            integrity: .complete
        )
    }
}

public enum CompletionArtifactValidationError: Error, Equatable, Sendable {
    case workspaceUnavailable
    case tooManyArtifacts
    case duplicateArtifact
    case outsideWorkspace
    case symbolicLink
    case notRegularFile
    case unsupportedFormat
    case fileTooLarge
    case fileChanged
    case invalidContent
    case unreadable
}

public struct ArtifactCompletionEvidenceAdapter: Sendable {
    public static let maximumArtifactCount = 8
    public static let maximumFileSize = 32 * 1_024 * 1_024

    public init() {}

    public func collect(
        selectedURLs: [URL],
        for session: RelaySessionState,
        now: Date = Date()
    ) async -> [CompletionReviewEvidenceObservation]? {
        guard !selectedURLs.isEmpty else { return [] }
        guard let cwd = session.project.cwd else { return nil }
        let workspaceRoot = URL(fileURLWithPath: cwd, isDirectory: true)
        return await Task.detached(priority: .utility) {
            do {
                let descriptors = try inspect(
                    selectedURLs: selectedURLs,
                    workspaceRoot: workspaceRoot
                )
                return descriptors.map { $0.observation(observedAt: now) }
            } catch {
                return nil
            }
        }.value
    }

    public func inspect(
        selectedURLs: [URL],
        workspaceRoot: URL
    ) throws -> [CompletionArtifactDescriptor] {
        guard selectedURLs.count <= Self.maximumArtifactCount else {
            throw CompletionArtifactValidationError.tooManyArtifacts
        }
        let normalized = selectedURLs.map(\.standardizedFileURL)
        guard Set(normalized.map(\.path)).count == normalized.count else {
            throw CompletionArtifactValidationError.duplicateArtifact
        }
        return try normalized.map { try inspect(url: $0, workspaceRoot: workspaceRoot) }
    }

    public func inspectAsync(
        selectedURLs: [URL],
        workspaceRoot: URL
    ) async throws -> [CompletionArtifactDescriptor] {
        try await Task.detached(priority: .utility) {
            try inspect(selectedURLs: selectedURLs, workspaceRoot: workspaceRoot)
        }.value
    }

    public func inspect(
        url: URL,
        workspaceRoot: URL
    ) throws -> CompletionArtifactDescriptor {
        let root = workspaceRoot.standardizedFileURL
        let candidate = url.standardizedFileURL
        try validateContainment(candidate, in: root)

        let before = try resourceSnapshot(for: candidate)
        guard before.isRegularFile else {
            throw CompletionArtifactValidationError.notRegularFile
        }
        guard before.fileSize <= Self.maximumFileSize else {
            throw CompletionArtifactValidationError.fileTooLarge
        }
        guard let format = Self.format(forExtension: candidate.pathExtension) else {
            throw CompletionArtifactValidationError.unsupportedFormat
        }

        let data: Data
        do {
            let handle = try FileHandle(forReadingFrom: candidate)
            defer { try? handle.close() }
            data = try handle.read(upToCount: Self.maximumFileSize + 1) ?? Data()
        } catch {
            throw CompletionArtifactValidationError.unreadable
        }
        guard data.count <= Self.maximumFileSize else {
            throw CompletionArtifactValidationError.fileTooLarge
        }

        try validateContainment(candidate, in: root)
        let after = try resourceSnapshot(for: candidate)
        guard before == after, after.fileSize == data.count else {
            throw CompletionArtifactValidationError.fileChanged
        }
        guard Self.hasValidContent(data, format: format) else {
            throw CompletionArtifactValidationError.invalidContent
        }

        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return CompletionArtifactDescriptor(
            format: format,
            sizeBucket: CompletionArtifactSizeBucket(byteCount: data.count),
            byteCount: data.count,
            sha256: digest
        )
    }

    private func validateContainment(_ candidate: URL, in root: URL) throws {
        guard root.isFileURL,
              candidate.isFileURL,
              root.path.hasPrefix("/"),
              candidate.path.hasPrefix("/") else {
            throw CompletionArtifactValidationError.outsideWorkspace
        }
        let rootComponents = root.pathComponents
        let candidateComponents = candidate.pathComponents
        guard candidateComponents.count > rootComponents.count,
              Array(candidateComponents.prefix(rootComponents.count)) == rootComponents else {
            throw CompletionArtifactValidationError.outsideWorkspace
        }

        let rootValues: URLResourceValues
        do {
            rootValues = try root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        } catch {
            throw CompletionArtifactValidationError.workspaceUnavailable
        }
        guard rootValues.isDirectory == true else {
            throw CompletionArtifactValidationError.workspaceUnavailable
        }
        guard rootValues.isSymbolicLink != true else {
            throw CompletionArtifactValidationError.symbolicLink
        }

        var componentURL = root
        for component in candidateComponents.dropFirst(rootComponents.count) {
            componentURL.appendPathComponent(component)
            let values: URLResourceValues
            do {
                values = try componentURL.resourceValues(forKeys: [.isSymbolicLinkKey])
            } catch {
                throw CompletionArtifactValidationError.unreadable
            }
            guard values.isSymbolicLink != true else {
                throw CompletionArtifactValidationError.symbolicLink
            }
        }
    }

    private func resourceSnapshot(for url: URL) throws -> ArtifactResourceSnapshot {
        do {
            let values = try url.resourceValues(forKeys: [
                .isRegularFileKey,
                .isSymbolicLinkKey,
                .fileSizeKey,
                .fileResourceIdentifierKey,
                .contentModificationDateKey
            ])
            guard values.isSymbolicLink != true else {
                throw CompletionArtifactValidationError.symbolicLink
            }
            guard let fileSize = values.fileSize,
                  fileSize >= 0 else {
                throw CompletionArtifactValidationError.unreadable
            }
            return ArtifactResourceSnapshot(
                isRegularFile: values.isRegularFile == true,
                fileSize: fileSize,
                resourceIdentifier: values.fileResourceIdentifier.map { String(describing: $0) },
                modificationDate: values.contentModificationDate
            )
        } catch let error as CompletionArtifactValidationError {
            throw error
        } catch {
            throw CompletionArtifactValidationError.unreadable
        }
    }

    private static func format(forExtension pathExtension: String) -> CompletionArtifactFormat? {
        switch pathExtension.lowercased() {
        case "pdf": .pdf
        case "png": .png
        case "jpg", "jpeg": .jpeg
        case "json": .json
        case "zip": .zip
        default: nil
        }
    }

    private static func hasValidContent(_ data: Data, format: CompletionArtifactFormat) -> Bool {
        let bytes = [UInt8](data)
        switch format {
        case .pdf:
            guard bytes.starts(with: Array("%PDF-".utf8)),
                  let provider = CGDataProvider(data: data as CFData),
                  let document = CGPDFDocument(provider) else { return false }
            return document.numberOfPages > 0
        case .png:
            return validImage(data, expectedType: .png)
        case .jpeg:
            return validImage(data, expectedType: .jpeg)
        case .json:
            guard !data.isEmpty,
                  let object = try? JSONSerialization.jsonObject(with: data) else { return false }
            return object is [String: Any] || object is [Any]
        case .zip:
            return validZIP(bytes)
        }
    }

    private static func validImage(_ data: Data, expectedType: UTType) -> Bool {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0,
              let typeIdentifier = CGImageSourceGetType(source),
              UTType(typeIdentifier as String) == expectedType else { return false }
        return CGImageSourceCreateImageAtIndex(source, 0, nil) != nil
    }

    private static func validZIP(_ bytes: [UInt8]) -> Bool {
        guard bytes.count >= 22 else { return false }
        let localHeader: [UInt8] = [0x50, 0x4B, 0x03, 0x04]
        let emptyHeader: [UInt8] = [0x50, 0x4B, 0x05, 0x06]
        guard bytes.starts(with: localHeader) || bytes.starts(with: emptyHeader) else { return false }
        let earliest = max(0, bytes.count - 65_557)
        var cursor = bytes.count - 22
        while cursor >= earliest {
            if bytes[cursor...].starts(with: emptyHeader),
               let disk = littleEndianUInt16(bytes, at: cursor + 4),
               let centralDisk = littleEndianUInt16(bytes, at: cursor + 6),
               let entriesOnDisk = littleEndianUInt16(bytes, at: cursor + 8),
               let totalEntries = littleEndianUInt16(bytes, at: cursor + 10),
               let centralSize = littleEndianUInt32(bytes, at: cursor + 12),
               let centralOffset = littleEndianUInt32(bytes, at: cursor + 16),
               let commentLength = littleEndianUInt16(bytes, at: cursor + 20),
               disk == 0,
               centralDisk == 0,
               entriesOnDisk == totalEntries,
               cursor + 22 + Int(commentLength) == bytes.count {
                if totalEntries == 0 {
                    return centralSize == 0
                }
                let offset = Int(centralOffset)
                let size = Int(centralSize)
                let centralHeader: [UInt8] = [0x50, 0x4B, 0x01, 0x02]
                return offset <= cursor
                    && size <= cursor - offset
                    && offset + size == cursor
                    && bytes[offset...].starts(with: centralHeader)
            }
            if cursor == 0 { break }
            cursor -= 1
        }
        return false
    }

    private static func littleEndianUInt16(_ bytes: [UInt8], at offset: Int) -> UInt16? {
        guard offset >= 0, offset + 2 <= bytes.count else { return nil }
        return UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8
    }

    private static func littleEndianUInt32(_ bytes: [UInt8], at offset: Int) -> UInt32? {
        guard offset >= 0, offset + 4 <= bytes.count else { return nil }
        return UInt32(bytes[offset])
            | UInt32(bytes[offset + 1]) << 8
            | UInt32(bytes[offset + 2]) << 16
            | UInt32(bytes[offset + 3]) << 24
    }
}

private struct ArtifactResourceSnapshot: Equatable {
    var isRegularFile: Bool
    var fileSize: Int
    var resourceIdentifier: String?
    var modificationDate: Date?
}
