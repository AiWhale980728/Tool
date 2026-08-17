import Foundation

public enum RelayError: Error, LocalizedError, Equatable {
    case invalidPayload(String)
    case invalidConfirmation(String)
    case unsupportedSource(String)
    case unsupportedStatus(String)
    case missingArgument(String)
    case storage(String)

    public var errorDescription: String? {
        switch self {
        case .invalidPayload(let message):
            "Invalid hook payload: \(message)"
        case .invalidConfirmation(let message):
            "Completion confirmation rejected: \(message)"
        case .unsupportedSource(let source):
            "Unsupported agent source: \(source)"
        case .unsupportedStatus(let status):
            "Unsupported relay status: \(status)"
        case .missingArgument(let argument):
            "Missing required argument: \(argument)"
        case .storage(let message):
            "Relay storage error: \(message)"
        }
    }
}
