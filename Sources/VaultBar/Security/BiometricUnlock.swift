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
    private static let account = "master-password"
    private static let modeKey = "biometricMode"
    private static let stateKey = "biometricDomainState"

    static var isAvailable: Bool {
        let ctx = LAContext()
        var error: NSError?
        return ctx.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error)
    }

    static var hasStoredPassword: Bool {
        var q = baseQuery(strict: UserDefaults.standard.string(forKey: modeKey) == "strict")
        q[kSecReturnData as String] = false
        let ctx = LAContext()
        ctx.interactionNotAllowed = true // existence check must never prompt
        q[kSecUseAuthenticationContext as String] = ctx
        let status = SecItemCopyMatching(q as CFDictionary, nil)
        return status == errSecSuccess || status == errSecInteractionNotAllowed
    }

    private static func baseQuery(strict: Bool) -> [String: Any] {
        var q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        if strict { q[kSecUseDataProtectionKeychain as String] = true }
        return q
    }

    // MARK: Store

    static func store(password: String) throws {
        remove()
        let data = Data(password.utf8)

        var acError: Unmanaged<CFError>?
        if let acl = SecAccessControlCreateWithFlags(
            nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly, .biometryCurrentSet, &acError
        ) {
            var q = baseQuery(strict: true)
            q[kSecValueData as String] = data
            q[kSecAttrAccessControl as String] = acl
            if SecItemAdd(q as CFDictionary, nil) == errSecSuccess {
                UserDefaults.standard.set("strict", forKey: modeKey)
                return
            }
        }

        // Fallback: gated mode.
        let ctx = LAContext()
        var error: NSError?
        guard ctx.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else { throw Failure.unavailable }
        var q = baseQuery(strict: false)
        q[kSecValueData as String] = data
        q[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        guard SecItemAdd(q as CFDictionary, nil) == errSecSuccess else { throw Failure.failed }
        UserDefaults.standard.set("gated", forKey: modeKey)
        UserDefaults.standard.set(ctx.evaluatedPolicyDomainState?.base64EncodedString(), forKey: stateKey)
    }

    // MARK: Retrieve

    static func retrieve(reason: String) async throws -> String {
        let strict = UserDefaults.standard.string(forKey: modeKey) == "strict"
        let ctx = LAContext()
        ctx.localizedReason = reason
        var error: NSError?
        guard ctx.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else { throw Failure.unavailable }

        if !strict {
            // Fingerprint set changed since enrolment: drop the stored password.
            let saved = UserDefaults.standard.string(forKey: stateKey)
            let now = ctx.evaluatedPolicyDomainState?.base64EncodedString()
            if saved != now {
                remove()
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

        var q = baseQuery(strict: strict)
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
            remove()
            throw Failure.invalidated
        default: throw Failure.failed
        }
    }

    static func remove() {
        for strict in [true, false] { SecItemDelete(baseQuery(strict: strict) as CFDictionary) }
        UserDefaults.standard.removeObject(forKey: modeKey)
        UserDefaults.standard.removeObject(forKey: stateKey)
    }
}
