@testable import Networking
import Testing

struct ServerConfigTests {
    private func validInfo() -> [String: Any] {
        [
            "MessengerXMPPDomain": "chat.example.com",
            "MessengerXMPPHost": "chat.example.com",
            "MessengerXMPPPort": "5223",
            "MessengerMUCDomain": "groups.chat.example.com",
            "MessengerPushComponentJID": "push.chat.example.com",
            "MessengerAppGroup": "group.com.Example.messenger",
        ]
    }

    @Test func loadsValidConfiguration() throws {
        let config = try ServerConfig(infoDictionary: validInfo())
        #expect(config.xmppDomain == "chat.example.com")
        #expect(config.xmppPort == 5223)
        #expect(config.appGroupID == "group.com.Example.messenger") // case preserved
    }

    @Test func reportsMissingKey() {
        var info = validInfo()
        info["MessengerXMPPDomain"] = nil
        #expect(throws: ServerConfig.LoadError.missing(key: "MessengerXMPPDomain")) {
            try ServerConfig(infoDictionary: info)
        }
    }

    @Test(arguments: ["", "localhost", "https://chat.example.com", "chat example.com", ".example.com"])
    func rejectsInvalidHost(_ host: String) {
        var info = validInfo()
        info["MessengerXMPPHost"] = host
        #expect(throws: ServerConfig.LoadError.invalid(key: "MessengerXMPPHost")) {
            try ServerConfig(infoDictionary: info)
        }
    }

    @Test(arguments: ["0", "70000", "abc", ""])
    func rejectsInvalidPort(_ port: String) {
        var info = validInfo()
        info["MessengerXMPPPort"] = port
        #expect(throws: ServerConfig.LoadError.invalid(key: "MessengerXMPPPort")) {
            try ServerConfig(infoDictionary: info)
        }
    }
}
