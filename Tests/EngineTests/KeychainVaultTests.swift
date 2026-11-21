import BelloCore
import Foundation
import Security
import Synchronization
import Testing

@testable import Engine

/// v1.0.0 review N23: replacing a Keychain value never deletes the old item before the new one is stored.
@Suite("Keychain vault")
struct KeychainVaultTests {
    /// A generic-password Keychain in memory, keyed by account, that can refuse adds and updates.
    final class FakeKeychain: Sendable {
        struct State {
            var items: [String: Data] = [:]
            var refuseWrites = false
        }

        let state = Mutex(State())

        static func account(_ query: CFDictionary) -> String {
            (query as NSDictionary)[kSecAttrAccount as String] as? String ?? ""
        }

        var calls: KeychainCalls {
            var calls = KeychainCalls()
            calls.add = { [self] query in
                state.withLock { state in
                    let account = Self.account(query)
                    if state.items[account] != nil { return errSecDuplicateItem }
                    if state.refuseWrites { return errSecInteractionNotAllowed }
                    state.items[account] = (query as NSDictionary)[kSecValueData as String] as? Data
                    return errSecSuccess
                }
            }
            calls.update = { [self] query, attributes in
                state.withLock { state in
                    let account = Self.account(query)
                    guard state.items[account] != nil else { return errSecItemNotFound }
                    if state.refuseWrites { return errSecInteractionNotAllowed }
                    state.items[account] = (attributes as NSDictionary)[kSecValueData as String] as? Data
                    return errSecSuccess
                }
            }
            calls.copy = { [self] query, result in
                state.withLock { state in
                    guard let data = state.items[Self.account(query)] else { return errSecItemNotFound }
                    result.pointee = data as CFData
                    return errSecSuccess
                }
            }
            calls.delete = { [self] query in
                state.withLock { $0.items.removeValue(forKey: Self.account(query)) == nil ? errSecItemNotFound : errSecSuccess }
            }
            return calls
        }
    }

    @Test func aRefusedReplacementKeepsThePreviousValue() throws {
        let keychain = FakeKeychain()
        let vault = KeychainSecretVault(service: "app.bellocode.tests", calls: keychain.calls)
        try vault.store(account: "bcs_1", label: "Token", value: SecretValue("first-value-123"))
        #expect(try vault.read(account: "bcs_1")?.utf8 == Data("first-value-123".utf8))

        keychain.state.withLock { $0.refuseWrites = true }
        #expect(throws: ExtrasError.self) { try vault.store(account: "bcs_1", label: "Token", value: SecretValue("second-value-456")) }
        #expect(try vault.read(account: "bcs_1")?.utf8 == Data("first-value-123".utf8), "the old value survives a refused rotation")

        keychain.state.withLock { $0.refuseWrites = false }
        try vault.store(account: "bcs_1", label: "Token", value: SecretValue("second-value-456"))
        #expect(try vault.read(account: "bcs_1")?.utf8 == Data("second-value-456".utf8), "an accepted replacement updates in place")
        try vault.delete(account: "bcs_1")
        #expect(try vault.read(account: "bcs_1") == nil)
    }
}
