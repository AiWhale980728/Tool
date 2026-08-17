import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import RelayCore

@Suite("Artifact Completion Review evidence")
struct ArtifactCompletionEvidenceAdapterTests {
    @Test
    func supportedFormatsProducePathFreeCompleteEvidence() throws {
        let root = temporaryDirectory("supported")
        defer { try? FileManager.default.removeItem(at: root) }
        let fixtures: [(String, Data, CompletionArtifactFormat)] = [
            ("private-report.pdf", try makePDFData(), .pdf),
            ("customer-image.png", try makeImageData(type: .png), .png),
            ("release-photo.jpeg", try makeImageData(type: .jpeg), .jpeg),
            ("credentials.json", Data(#"{"apiKey":"sk-live-not-sent"}"#.utf8), .json),
            ("bundle.zip", emptyZIPData, .zip)
        ]
        let adapter = ArtifactCompletionEvidenceAdapter()

        for (name, data, expectedFormat) in fixtures {
            let url = root.appendingPathComponent(name)
            try data.write(to: url)

            let first = try adapter.inspect(url: url, workspaceRoot: root)
            let second = try adapter.inspect(url: url, workspaceRoot: root)
            let observation = first.observation(observedAt: SupervisorTestSupport.now)

            #expect(first.format == expectedFormat)
            #expect(first.sha256 == second.sha256)
            #expect(first.sha256.count == 64)
            #expect(first.sha256.allSatisfy { $0.isHexDigit && !$0.isUppercase })
            #expect(observation.kind == .artifactProduced)
            #expect(observation.source.kind == .tool)
            #expect(observation.integrity == .complete)
            #expect(observation.reference == "artifact-sha256:\(first.sha256)")
            #expect(!observation.summary.contains(name))
            #expect(!observation.summary.contains(root.path))
            #expect(!observation.summary.contains("sk-live"))
        }
    }

    @Test
    func contentMustMatchARecognizedExtension() throws {
        let root = temporaryDirectory("content")
        defer { try? FileManager.default.removeItem(at: root) }
        let adapter = ArtifactCompletionEvidenceAdapter()
        let fakePDF = root.appendingPathComponent("fake.pdf")
        let scalarJSON = root.appendingPathComponent("scalar.json")
        let unsupported = root.appendingPathComponent("result.txt")
        try Data(#"{"valid":"json but not pdf"}"#.utf8).write(to: fakePDF)
        try Data("42".utf8).write(to: scalarJSON)
        try Data("plain text".utf8).write(to: unsupported)

        #expect(throws: CompletionArtifactValidationError.invalidContent) {
            try adapter.inspect(url: fakePDF, workspaceRoot: root)
        }
        #expect(throws: CompletionArtifactValidationError.invalidContent) {
            try adapter.inspect(url: scalarJSON, workspaceRoot: root)
        }
        #expect(throws: CompletionArtifactValidationError.unsupportedFormat) {
            try adapter.inspect(url: unsupported, workspaceRoot: root)
        }
    }

    @Test
    func pathEscapeAndSymbolicLinksAreRejected() throws {
        let parent = temporaryDirectory("containment")
        defer { try? FileManager.default.removeItem(at: parent) }
        let workspace = parent.appendingPathComponent("workspace", isDirectory: true)
        let sibling = parent.appendingPathComponent("workspace-other", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: true)
        let outside = sibling.appendingPathComponent("outside.json")
        try Data(#"{"outside":true}"#.utf8).write(to: outside)
        let linked = workspace.appendingPathComponent("linked.json")
        try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: outside)
        let adapter = ArtifactCompletionEvidenceAdapter()

        #expect(throws: CompletionArtifactValidationError.outsideWorkspace) {
            try adapter.inspect(url: outside, workspaceRoot: workspace)
        }
        #expect(throws: CompletionArtifactValidationError.symbolicLink) {
            try adapter.inspect(url: linked, workspaceRoot: workspace)
        }
    }

    @Test
    func selectionCountDuplicatesAndFileSizeAreBounded() throws {
        let root = temporaryDirectory("bounds")
        defer { try? FileManager.default.removeItem(at: root) }
        let adapter = ArtifactCompletionEvidenceAdapter()
        let valid = root.appendingPathComponent("valid.json")
        try Data(#"{"valid":true}"#.utf8).write(to: valid)

        #expect(throws: CompletionArtifactValidationError.duplicateArtifact) {
            try adapter.inspect(selectedURLs: [valid, valid], workspaceRoot: root)
        }

        var tooMany: [URL] = []
        for index in 0...ArtifactCompletionEvidenceAdapter.maximumArtifactCount {
            let url = root.appendingPathComponent("artifact-\(index).json")
            try Data("{\"index\":\(index)}".utf8).write(to: url)
            tooMany.append(url)
        }
        #expect(throws: CompletionArtifactValidationError.tooManyArtifacts) {
            try adapter.inspect(selectedURLs: tooMany, workspaceRoot: root)
        }

        let oversized = root.appendingPathComponent("oversized.json")
        FileManager.default.createFile(atPath: oversized.path, contents: nil)
        let handle = try FileHandle(forWritingTo: oversized)
        try handle.truncate(atOffset: UInt64(ArtifactCompletionEvidenceAdapter.maximumFileSize + 1))
        try handle.close()
        #expect(throws: CompletionArtifactValidationError.fileTooLarge) {
            try adapter.inspect(url: oversized, workspaceRoot: root)
        }
    }

    @Test
    func collectionRequiresTheTaskWorkspaceAndKeepsReferencesLocal() async throws {
        let root = temporaryDirectory("collection")
        defer { try? FileManager.default.removeItem(at: root) }
        let artifact = root.appendingPathComponent("handoff-secret.pdf")
        try makePDFData().write(to: artifact)
        let session = reviewSession(workspace: root.path)
        let adapter = ArtifactCompletionEvidenceAdapter()

        let observations = try #require(await adapter.collect(
            selectedURLs: [artifact],
            for: session,
            now: SupervisorTestSupport.now
        ))
        #expect(observations.count == 1)
        #expect(observations[0].reference?.hasPrefix("artifact-sha256:") == true)
        #expect(!observations[0].summary.contains("handoff-secret"))
        #expect(!observations[0].summary.contains(root.path))

        var unbound = session
        unbound.project.cwd = nil
        #expect(await adapter.collect(selectedURLs: [artifact], for: unbound) == nil)
    }

    private func temporaryDirectory(_ suffix: String) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "notch-relay-artifact-\(suffix)-\(UUID().uuidString)",
                isDirectory: true
            )
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func reviewSession(workspace: String) -> RelaySessionState {
        RelaySessionState(event: RelayEvent(
            source: .codex,
            sourceEvent: "TurnComplete",
            sessionID: "artifact-evidence-session",
            status: .readyToReview,
            project: ProjectContext(cwd: workspace),
            summary: "Result ready for review.",
            occurredAt: SupervisorTestSupport.now,
            receivedAt: SupervisorTestSupport.now
        ))
    }

    private func makePDFData() throws -> Data {
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data as CFMutableData) else {
            throw ArtifactFixtureError.creationFailed
        }
        var mediaBox = CGRect(x: 0, y: 0, width: 16, height: 16)
        guard let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            throw ArtifactFixtureError.creationFailed
        }
        context.beginPDFPage(nil)
        context.setFillColor(CGColor(gray: 0.5, alpha: 1))
        context.fill(mediaBox)
        context.endPDFPage()
        context.closePDF()
        return data as Data
    }

    private func makeImageData(type: UTType) throws -> Data {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ), let image = context.makeImage() else {
            throw ArtifactFixtureError.creationFailed
        }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data as CFMutableData,
            type.identifier as CFString,
            1,
            nil
        ) else {
            throw ArtifactFixtureError.creationFailed
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw ArtifactFixtureError.creationFailed
        }
        return data as Data
    }

    private var emptyZIPData: Data {
        Data([
            0x50, 0x4B, 0x05, 0x06,
            0, 0, 0, 0, 0, 0, 0, 0,
            0, 0, 0, 0, 0, 0, 0, 0,
            0, 0
        ])
    }
}

private enum ArtifactFixtureError: Error {
    case creationFailed
}
