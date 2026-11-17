import Foundation

public enum AutoTypeMode: Sendable {
    /// Username, Tab, password.
    case login
    case username
    case password
    case code
}

public enum AutoTypeStep: Equatable, Sendable {
    case text(String)
    case tab
    case enter
}

/// What "Auto-type" sends to the app that has focus, as plain steps (the app turns them into key events).
public enum AutoTypePlan {
    /// `pressEnter` adds a final Return after a login, a password or a code, but never after a lone username.
    public static func steps(username: String?, password: String?, code: String?, mode: AutoTypeMode, pressEnter: Bool) -> [AutoTypeStep] {
        let user = username.flatMap { $0.isEmpty ? nil : $0 }
        let pass = password.flatMap { $0.isEmpty ? nil : $0 }
        let otp = code.flatMap { $0.isEmpty ? nil : $0 }
        var steps: [AutoTypeStep] = []
        switch mode {
        case .login:
            if let user { steps.append(.text(user)) }
            if user != nil, pass != nil { steps.append(.tab) }
            if let pass { steps.append(.text(pass)) }
        case .username:
            if let user { steps.append(.text(user)) }
        case .password:
            if let pass { steps.append(.text(pass)) }
        case .code:
            if let otp { steps.append(.text(otp)) }
        }
        if pressEnter, mode != .username, !steps.isEmpty { steps.append(.enter) }
        return steps
    }

    /// Splits `text` into pieces of at most `maxUnits` UTF-16 units without cutting a character
    /// (emoji and accented letters stay whole). A keyboard event carries only a few characters.
    public static func chunks(of text: String, maxUnits: Int = 16) -> [String] {
        var result: [String] = []
        var current = ""
        var units = 0
        for character in text {
            let size = String(character).utf16.count
            if units + size > maxUnits, !current.isEmpty {
                result.append(current)
                current = ""
                units = 0
            }
            current.append(character)
            units += size
        }
        if !current.isEmpty { result.append(current) }
        return result
    }
}
