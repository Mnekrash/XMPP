import NotificationEnvelope
import UserNotifications

/// docs/04 §2.2: decrypt the envelope with the device key, resolve the display name locally, never show text.
/// Any failure (or the injected ones) leaves the APNs fallback "New message" in place.
final class NotificationService: UNNotificationServiceExtension {
    private var contentHandler: ((UNNotificationContent) -> Void)?
    private var bestAttempt: UNMutableNotificationContent?

    override func didReceive(_ request: UNNotificationRequest, withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        self.contentHandler = contentHandler
        bestAttempt = request.content.mutableCopy() as? UNMutableNotificationContent
        let started = Date()
        switch SharedStore.nseFailureMode {
        case "crash":
            SharedStore.log("injected crash", source: "NSE")
            fatalError("S2 failure injection")
        case "timeout":
            SharedStore.log("injected timeout: not calling the content handler", source: "NSE")
            return  // iOS calls serviceExtensionTimeWillExpire (~30 s)
        default:
            break
        }
        let text = NotificationText.decide(
            userInfo: request.content.userInfo,
            deviceKey: SharedStore.keychainGet("deviceKey"),
            displayName: { SharedStore.names()[$0] },
            groupTitle: { _ in nil })
        bestAttempt?.title = text.title
        bestAttempt?.body = text.body
        SharedStore.log("decided title=\(text.title == NotificationText.fallbackTitle ? "fallback" : "name") in "
                        + String(format: "%.0f ms", Date().timeIntervalSince(started) * 1000), source: "NSE")
        if let bestAttempt { contentHandler(bestAttempt) }
    }

    override func serviceExtensionTimeWillExpire() {
        SharedStore.log("time will expire → delivering fallback", source: "NSE")
        if let contentHandler, let bestAttempt { contentHandler(bestAttempt) }
    }
}
