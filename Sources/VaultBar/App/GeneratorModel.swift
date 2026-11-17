import Foundation
import Observation
import VaultKit

/// State of the Generator tab. Only the options persist (they are not secret);
/// the generated value lives in memory and is gone when the app quits or locks.
@MainActor @Observable
final class GeneratorModel {
    enum Mode: String, CaseIterable { case password, passphrase }

    private let defaults = UserDefaults.standard

    var mode: Mode { didSet { defaults.set(mode.rawValue, forKey: "gen.mode"); regenerate() } }
    var password: PasswordOptions { didSet { save(password, "gen.password"); regenerate() } }
    var passphrase: PassphraseOptions { didSet { save(passphrase, "gen.passphrase"); regenerate() } }
    private(set) var value = ""

    init() {
        let d = UserDefaults.standard
        mode = Mode(rawValue: d.string(forKey: "gen.mode") ?? "") ?? .password
        password = d.data(forKey: "gen.password").flatMap { try? JSONDecoder().decode(PasswordOptions.self, from: $0) } ?? PasswordOptions()
        passphrase = d.data(forKey: "gen.passphrase").flatMap { try? JSONDecoder().decode(PassphraseOptions.self, from: $0) } ?? PassphraseOptions()
        regenerate()
    }

    private func save<T: Encodable>(_ value: T, _ key: String) {
        defaults.set(try? JSONEncoder().encode(value), forKey: key)
    }

    func regenerate() {
        value = mode == .password ? PasswordGenerator.password(password) : PasswordGenerator.passphrase(passphrase)
    }

    /// A fresh password with the current options (used by the editor's generate button).
    func fresh() -> String {
        mode == .password ? PasswordGenerator.password(password) : PasswordGenerator.passphrase(passphrase)
    }

    var strength: PasswordStrength {
        PasswordGenerator.strength(bits: mode == .password ? PasswordGenerator.entropyBits(password) : PasswordGenerator.entropyBits(passphrase))
    }

    func clear() { value = "" }
}
