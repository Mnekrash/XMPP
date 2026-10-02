import Foundation
import Security

/// State shared between the app and the NSE: Keychain (device key, push node/secret) and an App Group file
/// (contact names, NSE log, failure-injection switch). Spike-level code.
enum SharedStore {
    static var appGroup: String { Bundle.main.object(forInfoDictionaryKey: "SpikeAppGroup") as? String ?? "" }
    static var keychainGroup: String { Bundle.main.object(forInfoDictionaryKey: "SpikeKeychainGroup") as? String ?? "" }

    // MARK: Keychain (AfterFirstUnlockThisDeviceOnly, shared access group)

    static func keychainSet(_ data: Data, account: String) {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "pushspike",
                                   kSecAttrAccount as String: account, kSecAttrAccessGroup as String: keychainGroup]
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
    }

    static func keychainGet(_ account: String) -> Data? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "pushspike",
                                kSecAttrAccount as String: account, kSecAttrAccessGroup as String: keychainGroup,
                                kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var out: CFTypeRef?
        return SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess ? out as? Data : nil
    }

    static func keychainDelete(_ account: String) {
        SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "pushspike",
                       kSecAttrAccount as String: account, kSecAttrAccessGroup as String: keychainGroup] as CFDictionary)
    }

    // MARK: App Group files

    static var container: URL? { FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup) }

    static func names() -> [String: String] {
        guard let url = container?.appendingPathComponent("names.json"), let data = try? Data(contentsOf: url) else { return [:] }
        return (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
    }

    static func saveNames(_ names: [String: String]) {
        guard let url = container?.appendingPathComponent("names.json") else { return }
        try? JSONEncoder().encode(names).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    /// "none" | "timeout" | "crash" — failure injection for the NSE fallback test.
    static var nseFailureMode: String {
        get { (try? String(contentsOf: container!.appendingPathComponent("nse-mode.txt"), encoding: .utf8)) ?? "none" }
        set { try? newValue.write(to: container!.appendingPathComponent("nse-mode.txt"), atomically: true, encoding: .utf8) }
    }

    static func log(_ line: String, source: String) {
        guard let url = container?.appendingPathComponent("spike-log.txt") else { return }
        let entry = "\(ISO8601DateFormatter().string(from: Date())) [\(source)] \(line)\n"
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data(entry.utf8))
            try? handle.close()
        } else {
            try? Data(entry.utf8).write(to: url)
        }
    }

    static func readLog() -> String {
        guard let url = container?.appendingPathComponent("spike-log.txt") else { return "" }
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }
}
