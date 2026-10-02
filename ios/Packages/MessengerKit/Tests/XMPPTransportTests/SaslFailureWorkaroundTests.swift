import Martin
import Testing
@testable import XMPPTransport

/// Regression tests for the Martin SASL failure defect (docs/known-issues/martin-sasl-failure.md).
/// Payloads are exactly what ejabberd 26.09 sent in the measurement of 2026-10-02.
struct SaslFailureWorkaroundTests {
    /// ejabberd: wrong password → <failure><text>Invalid username or password</text><not-authorized/></failure>
    /// ejabberd: banned account  → <failure><text>Account is banned: …</text><account-disabled/></failure>
    @Test func classifiesTheDefinedConditionNotTheText() {
        #expect(SaslFailureCondition.classify(childNames: ["text", "not-authorized"]) == .notAuthorized)
        #expect(SaslFailureCondition.classify(childNames: ["text", "account-disabled"]) == .accountDisabled)
        #expect(SaslFailureCondition.classify(childNames: ["account-disabled"]) == .accountDisabled)
        #expect(SaslFailureCondition.classify(childNames: ["text", "temporary-auth-failure"]) == .other("temporary-auth-failure"))
        #expect(SaslFailureCondition.classify(childNames: ["text"]) == nil)
    }

    @Test func observerReadsTheRawFailureStanza() {
        let failure = Element(name: "failure", xmlns: SaslFailureCondition.namespace)
        failure.addChild(Element(name: "text", cdata: "Account is banned: test"))
        failure.addChild(Element(name: "account-disabled"))
        let observer = SaslFailureObserver()
        observer.incoming(.stanza(Stanza.from(element: failure)))
        #expect(observer.lastCondition == .accountDisabled)
    }

    @Test func authenticationFailureIsMappedWithTheObservedCondition() {
        let reason = XMPPClient.State.DisconnectionReason.authenticationFailure(SaslError.not_authorized)
        #expect(AccountConnection.map(reason, saslCondition: .accountDisabled) == .accountDisabled)
        #expect(AccountConnection.map(reason, saslCondition: .notAuthorized) == .notAuthorized)
        #expect(AccountConnection.map(reason, saslCondition: nil) == .notAuthorized)
    }

    /// CANARY: reproduces Martin 3.2.4's own expression (`stanza.findChild()?.name`) on ejabberd's payload.
    /// If this starts failing, Martin's parsing changed — re-check the defect and remove the workaround if fixed.
    @Test func canaryMartinFirstChildIsText() {
        let failure = Element(name: "failure", xmlns: SaslFailureCondition.namespace)
        failure.addChild(Element(name: "text", cdata: "Account is banned: test"))
        failure.addChild(Element(name: "account-disabled"))
        let name = Stanza.from(element: failure).findChild()?.name
        #expect(name == "text")
        #expect(SaslError(rawValue: name ?? "") == nil)   // → Martin falls back to .not_authorized
    }
}
