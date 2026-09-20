import Foundation
import Security

// Where the device is, and the secret that gets in.
//
// The daemon has no discovery — no mDNS, no Bonjour — so the host is typed in. The
// token is a pre-shared secret of at least 16 characters; the daemon refuses to
// start a TCP listener without one, and refuses a short one, because three guesses
// per connection is only a bound if guessing is hopeless (docs/daemon.md).

struct EngineSettings: Equatable, Sendable {

    /// The daemon's default. `tcp_port: 0` lets the kernel choose, and then
    /// `engine.status.control.tcp_port` reports what it picked.
    static let defaultPort: UInt16 = 47810

    /// The daemon's own floor, repeated here so the app can say so before a
    /// connection is attempted rather than after it is refused.
    static let minimumTokenLength = 16

    var host: String = ""
    var port: UInt16 = defaultPort
    var token: String = ""

    var isComplete: Bool {
        !host.trimmingCharacters(in: .whitespaces).isEmpty
            && token.count >= Self.minimumTokenLength
    }

    /// What is missing, in words, or nil when nothing is.
    var whatIsMissing: String? {
        if host.trimmingCharacters(in: .whitespaces).isEmpty {
            return "The device needs a host name or address."
        }
        if token.isEmpty {
            return "The device needs the token from its namchaind.json."
        }
        if token.count < Self.minimumTokenLength {
            return "The token is \(token.count) characters; the device refuses anything under "
                 + "\(Self.minimumTokenLength)."
        }
        return nil
    }
}

// MARK: - Storage

/// Host and port in preferences, token in the keychain.
///
/// The wire is plaintext and the token travels in it, so the keychain is not
/// pretending to make this secret in transit — it keeps it off disk in the clear,
/// which is the part that is this app's business.
enum EngineSettingsStore {

    private static let hostKey = "engine.host"
    private static let portKey = "engine.port"
    private static let service = "namchain.control"

    static func load() -> EngineSettings {
        let defaults = UserDefaults.standard
        let port = defaults.object(forKey: portKey) as? Int
        return EngineSettings(
            host: defaults.string(forKey: hostKey) ?? "",
            port: port.flatMap { UInt16(exactly: $0) } ?? EngineSettings.defaultPort,
            token: (try? readToken()) ?? "")
    }

    /// Returns the keychain's complaint, if it had one. The caller shows it rather
    /// than letting a token silently fail to save.
    @discardableResult
    static func save(_ settings: EngineSettings) -> String? {
        let defaults = UserDefaults.standard
        defaults.set(settings.host, forKey: hostKey)
        defaults.set(Int(settings.port), forKey: portKey)
        do {
            try writeToken(settings.token)
            return nil
        } catch {
            return "The token could not be saved to the keychain (\(error))."
        }
    }

    // MARK: Keychain

    private struct KeychainError: Error, CustomStringConvertible {
        var status: OSStatus
        var description: String {
            SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
        }
    }

    private static func query(_ account: String = "token") -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    private static func readToken() throws -> String {
        var item = query()
        item[kSecReturnData as String] = true
        item[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(item as CFDictionary, &result)
        if status == errSecItemNotFound { return "" }
        guard status == errSecSuccess, let data = result as? Data else {
            throw KeychainError(status: status)
        }
        return String(decoding: data, as: UTF8.self)
    }

    private static func writeToken(_ token: String) throws {
        guard !token.isEmpty else {
            let status = SecItemDelete(query() as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw KeychainError(status: status)
            }
            return
        }

        let data = Data(token.utf8)
        let update = SecItemUpdate(query() as CFDictionary,
                                   [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else { throw KeychainError(status: update) }

        var item = query()
        item[kSecValueData as String] = data
        // The device is on the LAN and the app may reconnect on launch, so the token
        // has to be readable without the screen being unlocked first.
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let add = SecItemAdd(item as CFDictionary, nil)
        guard add == errSecSuccess else { throw KeychainError(status: add) }
    }
}
