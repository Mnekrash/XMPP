/// Errors as the user sees them. Technical detail goes to diagnostic logging only.
public enum UserFacingError: Error, Sendable, Equatable {
    case cannotConnect
    case invalidCredentials
    case accountDisabled
    case sendFailed
    case attachmentTooLarge
    case storageFull
    case unknown

    // English for now; localization is added in Phase 10.
    public var message: String {
        switch self {
        case .cannotConnect: "Unable to connect. Try again."
        case .invalidCredentials: "Wrong username or password."
        case .accountDisabled: "Your account is disabled. Contact your administrator."
        case .sendFailed: "Message not sent. Tap to retry."
        case .attachmentTooLarge: "This file is too large to send."
        case .storageFull: "Your iPhone is out of storage."
        case .unknown: "Something went wrong. Try again."
        }
    }
}
