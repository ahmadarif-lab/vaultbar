import Foundation
import LocalAuthentication
import Security

/// Touch ID unlock: the master password, not a session key, sits behind the
/// biometric prompt (PRD decision 1).
///
/// Two storage modes, chosen automatically:
///  * `strict`: a Keychain item whose access control is
///    `.biometryCurrentSet` + `WhenUnlockedThisDeviceOnly`, so macOS itself
///    gates the read and a changed fingerprint set invalidates it. This needs
///    a signed app with Keychain entitlements.
///  * `gated`: what an ad-hoc signed app can do (the strict call fails with
///    errSecMissingEntitlement, -34018). A plain this-device-only Keychain
///    item, read only after a Touch ID prompt inside the app, and discarded if
///    the enrolled-fingerprint state changes (`evaluatedPolicyDomainState`),
///    which reproduces the "re-enrolling invalidates it" behaviour.
enum BiometricUnlock {
    enum Failure: Error { case unavailable, cancelled, invalidated, notStored, failed }

    private static let service = "dev.ahmadarif.vaultbar"

    static let demoSlot = "demo"

    /// One Keychain item per slot: one per account, plus "demo" for demo mode, so a
    /// throwaway demo "password" can never be mistaken for a real master password.
    private struct Ids {
        let account: String, modeKey: String, stateKey: String
        init(slot: String) {
            account = "pw-\(slot)"
            modeKey = "biometricMode.\(slot)"
            stateKey = "biometricDomainState.\(slot)"
        }
    }

    static var isAvailable: Bool {
        let ctx = LAContext()
        var error: NSError?
        return ctx.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error)
    }

    static func hasStoredPassword(slot: String) -> Bool {
        let ids = Ids(slot: slot)
        var q = baseQuery(strict: UserDefaults.standard.string(forKey: ids.modeKey) == "strict", ids: ids)
        q[kSecReturnData as String] = false
        let ctx = LAContext()
        ctx.interactionNotAllowed = true // existence check must never prompt
        q[kSecUseAuthenticationContext as String] = ctx
        let status = SecItemCopyMatching(q as CFDictionary, nil)
        return status == errSecSuccess || status == errSecInteractionNotAllowed
    }

    private static func baseQuery(strict: Bool, ids: Ids) -> [String: Any] {
        var q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: ids.account,
        ]
        if strict { q[kSecUseDataProtectionKeychain as String] = true }
        return q
    }

    // MARK: Store

    static func store(password: String, slot: String) throws {
        let ids = Ids(slot: slot)
        remove(slot: slot)
        let data = Data(password.utf8)

        var acError: Unmanaged<CFError>?
        if let acl = SecAccessControlCreateWithFlags(
            nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly, .biometryCurrentSet, &acError
        ) {
            var q = baseQuery(strict: true, ids: ids)
            q[kSecValueData as String] = data
            q[kSecAttrAccessControl as String] = acl
            if SecItemAdd(q as CFDictionary, nil) == errSecSuccess {
                UserDefaults.standard.set("strict", forKey: ids.modeKey)
                return
            }
        }

        // Fallback: gated mode.
        let ctx = LAContext()
        var error: NSError?
        guard ctx.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else { throw Failure.unavailable }
        var q = baseQuery(strict: false, ids: ids)
        q[kSecValueData as String] = data
        q[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        guard SecItemAdd(q as CFDictionary, nil) == errSecSuccess else { throw Failure.failed }
        UserDefaults.standard.set("gated", forKey: ids.modeKey)
        UserDefaults.standard.set(ctx.evaluatedPolicyDomainState?.base64EncodedString(), forKey: ids.stateKey)
    }

    // MARK: Retrieve

    static func retrieve(reason: String, slot: String) async throws -> String {
        let ids = Ids(slot: slot)
        let strict = UserDefaults.standard.string(forKey: ids.modeKey) == "strict"
        let ctx = LAContext()
        ctx.localizedReason = reason
        var error: NSError?
        guard ctx.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else { throw Failure.unavailable }

        if !strict {
            // Fingerprint set changed since enrolment: drop the stored password.
            let saved = UserDefaults.standard.string(forKey: ids.stateKey)
            let now = ctx.evaluatedPolicyDomainState?.base64EncodedString()
            if saved != now {
                remove(slot: slot)
                throw Failure.invalidated
            }
            do {
                _ = try await ctx.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: reason)
            } catch let e as LAError where e.code == .userCancel || e.code == .appCancel || e.code == .systemCancel {
                throw Failure.cancelled
            } catch {
                throw Failure.failed
            }
        }

        var q = baseQuery(strict: strict, ids: ids)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        if strict { q[kSecUseAuthenticationContext as String] = ctx }

        // The strict read blocks on the Touch ID prompt; keep it off the main actor.
        let result: (OSStatus, Data?) = await Task.detached {
            var out: CFTypeRef?
            let status = SecItemCopyMatching(q as CFDictionary, &out)
            return (status, out as? Data)
        }.value

        switch result.0 {
        case errSecSuccess:
            guard let data = result.1, let password = String(data: data, encoding: .utf8) else { throw Failure.failed }
            return password
        case errSecItemNotFound: throw Failure.notStored
        case errSecUserCanceled: throw Failure.cancelled
        case errSecAuthFailed: // strict item invalidated by a fingerprint change
            remove(slot: slot)
            throw Failure.invalidated
        default: throw Failure.failed
        }
    }

    static func remove(slot: String) {
        let ids = Ids(slot: slot)
        for strict in [true, false] { SecItemDelete(baseQuery(strict: strict, ids: ids) as CFDictionary) }
        UserDefaults.standard.removeObject(forKey: ids.modeKey)
        UserDefaults.standard.removeObject(forKey: ids.stateKey)
    }
}
