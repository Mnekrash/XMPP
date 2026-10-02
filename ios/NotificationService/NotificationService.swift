import UserNotifications

/// Notification Service Extension. See docs/04-push.md §2.
///
/// SKELETON (preview level 0): delivers the push unchanged. The APNs payload always carries a
/// complete generic alert ("New message"), which is the mandatory fallback. Level 1
/// (decrypting the sender and resolving the display name locally) comes after spike S2.
final class NotificationService: UNNotificationServiceExtension {
    override func didReceive(
        _ request: UNNotificationRequest,
        withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void
    ) {
        contentHandler(request.content)
    }

    override func serviceExtensionTimeWillExpire() {
        // Nothing is pending: didReceive delivers synchronously.
    }
}
