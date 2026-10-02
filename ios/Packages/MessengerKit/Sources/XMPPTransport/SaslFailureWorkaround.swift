import Foundation
import Martin

// WORKAROUND for a Martin 3.2.4 defect (docs/known-issues/martin-sasl-failure.md):
// SaslModule.processFailure takes the FIRST child of <failure xmlns='urn:ietf:params:xml:ns:xmpp-sasl'/> as the
// error condition. ejabberd sends <text/> before the condition (e.g. <account-disabled/>), so Martin reports every
// SASL failure as not-authorized. We read the real condition from the raw stream instead.
// Isolated here: when Martin is fixed, delete this file and the two lines in AccountConnection that use it.
// Authentication and UI are unaffected (they only see TransportError).

enum SaslFailureCondition: Equatable {
    case notAuthorized
    case accountDisabled
    case other(String)

    static let namespace = "urn:ietf:params:xml:ns:xmpp-sasl"

    /// RFC 6120 §6.5: the condition is the defined-condition child; <text/> is optional descriptive text.
    static func classify(childNames: [String]) -> SaslFailureCondition? {
        guard let condition = childNames.first(where: { $0 != "text" }) else { return nil }
        switch condition {
        case "not-authorized": return .notAuthorized
        case "account-disabled": return .accountDisabled
        default: return .other(condition)
        }
    }
}

/// Observes incoming stream elements and remembers the last SASL failure condition.
final class SaslFailureObserver: StreamLogger, @unchecked Sendable {
    private let lock = NSLock()
    private var condition: SaslFailureCondition?

    var lastCondition: SaslFailureCondition? { lock.withLock { condition } }

    func reset() { lock.withLock { condition = nil } }

    func incoming(_ value: StreamEvent) {
        guard case .stanza(let stanza) = value, stanza.element.name == "failure",
              stanza.element.xmlns == SaslFailureCondition.namespace else { return }
        let names = stanza.element.getChildren().map(\.name)
        lock.withLock { condition = SaslFailureCondition.classify(childNames: names) }
    }

    func outgoing(_ value: StreamEvent) {}
}
