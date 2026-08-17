import Darwin
import Foundation

public final class RelayApplicationInstanceLease: @unchecked Sendable {
    public let lockFile: URL
    private let descriptor: Int32

    public init?(
        lockFile: URL,
        fileManager: FileManager = .default
    ) throws {
        self.lockFile = lockFile.standardizedFileURL
        try fileManager.createDirectory(
            at: self.lockFile.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let descriptor = open(self.lockFile.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else {
            throw RelayError.storage("failed to open application instance lock")
        }

        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let lockError = errno
            close(descriptor)
            if lockError == EWOULDBLOCK || lockError == EAGAIN {
                return nil
            }
            throw RelayError.storage("failed to acquire application instance lock")
        }

        self.descriptor = descriptor
    }

    deinit {
        flock(descriptor, LOCK_UN)
        close(descriptor)
    }
}
