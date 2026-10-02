# Known issue: Martin 3.2.4 reports every SASL failure as `not-authorized`

**Status:** open upstream (not reported yet) · **Workaround:** `ios/Packages/MessengerKit/Sources/XMPPTransport/SaslFailureWorkaround.swift`

## Observed (2026-10-02, ejabberd 26.09)

| Case | What ejabberd sends | What Martin reports |
|------|---------------------|---------------------|
| Wrong password | `<failure xmlns='urn:ietf:params:xml:ns:xmpp-sasl'><text>Invalid username or password</text><not-authorized/></failure>` | `SaslError.not_authorized` (correct by accident) |
| Account disabled (`admin.sh disable` → `ban_account`) | `<failure …><text>Account is banned: …</text><account-disabled/></failure>` | `SaslError.not_authorized` (**wrong**) |

## Cause

`SaslModule.processFailure` (Martin 3.2.4) uses `stanza.findChild()?.name`, i.e. the **first** child of
`<failure/>`, as the condition. RFC 6120 §6.5 allows an optional `<text/>` element. ejabberd puts it first, so the
name is `text`. `SaslError(rawValue: "text")` is nil, and Martin falls back to `.not_authorized`. In addition,
`SaslError` has no `account-disabled` case at all.

## Workaround (isolated)

- `SaslFailureObserver` is attached as Martin's `streamLogger` and reads the raw `<failure/>` element.
- `SaslFailureCondition.classify` picks the defined condition, skipping `<text/>`.
- `AccountConnection.map` maps `account-disabled` to `TransportError.accountDisabled`.

Martin itself is **not modified**. Authentication and UI only see `TransportError` / `UserFacingError`.

## Regression tests

- `Tests/XMPPTransportTests/SaslFailureWorkaroundTests.swift`: classification, the observer on the real payload,
  mapping, and a **canary** that reproduces Martin's own expression. If the canary fails, Martin's parsing changed:
  re-check, and remove the workaround if it is fixed.
- `Tests/IntegrationTests` (CI job `ios-integration`): a banned account against a real ejabberd must surface as
  "account disabled".

## Removal when fixed upstream

Delete `SaslFailureWorkaround.swift` and the two marked lines in `AccountConnection.swift` (the `saslObserver`
property and the `streamLogger` assignment). Then map `SaslError.account_disabled` (or whatever Martin adds) in
`AccountConnection.map`. No change is needed in Authentication or UI.
