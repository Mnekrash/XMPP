@testable import Domain
import Testing

struct MessageStatusTests {
    @Test(arguments: [
        (MessageStatus.sending, MessageStatus.sent, MessageStatus.sent),
        (.sent, .delivered, .delivered),
        (.delivered, .read, .read),
        (.sending, .read, .read),          // receipt overtakes the server ack
        (.read, .delivered, .read),        // never regresses
        (.delivered, .sent, .delivered),
        (.sending, .failed, .failed),
        (.sent, .failed, .sent),           // an acked message cannot fail
        (.failed, .sending, .sending),     // retry
        (.failed, .sent, .sent),           // late server ack after the failure timeout
        (.failed, .failed, .failed),
    ])
    func transitions(from current: MessageStatus, event: MessageStatus, expected: MessageStatus) {
        #expect(current.applying(event) == expected)
    }
}
