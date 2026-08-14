/// Where this device's long-term identity lives.
///
/// The X25519 private key is the whole of the app's authority: a machine that
/// has paired it will accept anything signed by it, forever, until someone runs
/// `bridle revoke`. So it goes in the Keychain with
/// `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` — readable by background
/// reconnects after the first unlock, never written to an iCloud or iTunes
/// backup, and not restorable onto a different device.

import Foundation
import Security

/// A Keychain operation that failed, carrying the raw OSStatus for diagnosis.
public struct KeychainError: Error, LocalizedError {
    public let status: OSStatus
    public let operation: String

    public var errorDescription: String? {
        "could not \(operation) the device identity (Keychain status \(status))"
    }
}

/// Small typed wrapper over the generic-password class.
public enum Keychain {
    static let service = "app.reins.identity"

    /// Read one item, or nil when it was never written.
    public static func read(_ account: String) throws -> Data? {
        var query = baseQuery(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainError(status: status, operation: "read") }
        return item as? Data
    }

    /// Write one item, replacing any previous value.
    public static func write(_ account: String, _ value: Data) throws {
        let query = baseQuery(account)
        let attributes: [String: Any] = [
            kSecValueData as String: value,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let updated = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updated == errSecSuccess { return }
        if updated != errSecItemNotFound { throw KeychainError(status: updated, operation: "update") }
        var insert = query
        insert.merge(attributes) { _, new in new }
        let added = SecItemAdd(insert as CFDictionary, nil)
        guard added == errSecSuccess else { throw KeychainError(status: added, operation: "store") }
    }

    /// Remove one item. Missing is success: unpairing twice is not an error.
    public static func delete(_ account: String) throws {
        let status = SecItemDelete(baseQuery(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError(status: status, operation: "remove")
        }
    }

    private static func baseQuery(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}

/// This device's Noise identity, created once and reused for every machine.
///
/// One identity across all machines, not one per machine: `bridle devices` then
/// shows "Ada’s iPhone" once per machine rather than a different opaque key each
/// time, and revoking on one machine says nothing to the others.
public enum DeviceIdentity {
    static let account = "device-static-x25519"

    /// Load the identity, generating and storing it on first launch.
    public static func load() throws -> StaticKeyPair {
        if let stored = try Keychain.read(account), stored.count == noiseKeyLength {
            return try StaticKeyPair(privateKey: stored)
        }
        let fresh = StaticKeyPair.generate()
        try Keychain.write(account, fresh.privateKey)
        return fresh
    }

    /// Forget the identity. Every machine will treat this device as new.
    public static func reset() throws {
        try Keychain.delete(account)
    }
}
