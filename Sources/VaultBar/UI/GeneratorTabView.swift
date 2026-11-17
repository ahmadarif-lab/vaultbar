import SwiftUI
import VaultKit

struct GeneratorTabView: View {
    let state: AppState

    var body: some View {
        let g = state.generator
        VStack(spacing: 0) {
            ScreenHeader(state: state, title: t("tab.generator"), showsAccount: false) { EmptyView() }
            ScrollView(showsIndicators: false) {
                VStack(spacing: 10) {
                    valueCard(g)
                    SegmentedChoice(
                        options: [(GeneratorModel.Mode.password, t("gen.password")), (.passphrase, t("gen.passphrase"))],
                        selection: Binding(get: { g.mode }, set: { g.mode = $0 })
                    )
                    Card {
                        FieldLabel(t("gen.options").uppercased())
                        if g.mode == .password { passwordOptions(g) } else { passphraseOptions(g) }
                    }
                }
                .padding(.horizontal, 14).padding(.bottom, 14)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: Value

    private func colored(_ value: String) -> AttributedString {
        var out = AttributedString()
        for ch in value {
            var piece = AttributedString(String(ch))
            switch PasswordGenerator.charClass(ch) {
            case .letter: piece.foregroundColor = Theme.textPrimary
            case .digit: piece.foregroundColor = Theme.digit
            case .symbol: piece.foregroundColor = Theme.symbol
            }
            out += piece
        }
        return out
    }

    private func strengthColor(_ s: PasswordStrength) -> Color {
        switch s {
        case .weak: return Theme.danger
        case .fair: return Theme.warning
        case .good: return Theme.accent
        case .strong: return Color(nsColor: NSColor(hex: 0x2F9E6B))
        }
    }

    private func strengthName(_ s: PasswordStrength) -> String {
        switch s {
        case .weak: return t("gen.strength.weak")
        case .fair: return t("gen.strength.fair")
        case .good: return t("gen.strength.good")
        case .strong: return t("gen.strength.strong")
        }
    }

    private func valueCard(_ g: GeneratorModel) -> some View {
        Card {
            Text(colored(g.value))
                .font(.system(size: 16, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                let s = g.strength
                HStack(spacing: 5) {
                    Circle().fill(strengthColor(s)).frame(width: 7, height: 7)
                    Text(strengthName(s)).font(.system(size: 12, weight: .medium)).foregroundStyle(strengthColor(s))
                }
                Spacer()
                Button { g.regenerate() } label: {
                    HStack(spacing: 5) { Image(systemName: "arrow.clockwise"); Text(t("gen.regenerate")) }
                }.buttonStyle(SecondaryButtonStyle()).handCursor()
                Button { state.copyValue(g.value, missingKey: "toast.copied") } label: {
                    HStack(spacing: 5) { Image(systemName: "doc.on.doc"); Text(t("gen.copy")) }
                }
                .buttonStyle(CompactPrimaryStyle()).handCursor()
            }
        }
    }

    // MARK: Options

    private func passwordOptions(_ g: GeneratorModel) -> some View {
        let lengthBinding = Binding(get: { Double(g.password.length) }, set: { g.password.length = Int($0.rounded()) })
        return VStack(alignment: .leading, spacing: 11) {
            HStack {
                Text(t("gen.length")).font(.system(size: 13)).foregroundStyle(Theme.textPrimary)
                Spacer()
                Text("\(g.password.length)").font(.system(size: 13, weight: .semibold, design: .monospaced)).foregroundStyle(Theme.textPrimary)
            }
            Slider(value: lengthBinding, in: Double(PasswordGenerator.lengthRange.lowerBound)...Double(PasswordGenerator.lengthRange.upperBound))
                .tint(Theme.accent)
            CheckRow(title: t("gen.uppercase"), isOn: Binding(get: { g.password.uppercase }, set: { g.password.uppercase = $0 }), mono: true)
            CheckRow(title: t("gen.lowercase"), isOn: Binding(get: { g.password.lowercase }, set: { g.password.lowercase = $0 }), mono: true)
            CheckRow(title: t("gen.numbers"), isOn: Binding(get: { g.password.numbers }, set: { g.password.numbers = $0 }), mono: true)
            CheckRow(title: t("gen.special"), isOn: Binding(get: { g.password.special }, set: { g.password.special = $0 }), mono: true)
            Divider().overlay(Theme.stroke)
            NumberStepper(title: t("gen.minNumbers"), value: Binding(get: { g.password.minNumbers }, set: { g.password.minNumbers = $0 }), range: 0...10)
            NumberStepper(title: t("gen.minSpecial"), value: Binding(get: { g.password.minSpecial }, set: { g.password.minSpecial = $0 }), range: 0...10)
            CheckRow(title: t("gen.ambiguous"), isOn: Binding(get: { g.password.avoidAmbiguous }, set: { g.password.avoidAmbiguous = $0 }))
        }
    }

    private func passphraseOptions(_ g: GeneratorModel) -> some View {
        VStack(alignment: .leading, spacing: 11) {
            NumberStepper(title: t("gen.words"), value: Binding(get: { g.passphrase.words }, set: { g.passphrase.words = $0 }), range: PasswordGenerator.wordsRange)
            HStack {
                Text(t("gen.separator")).font(.system(size: 13)).foregroundStyle(Theme.textPrimary)
                Spacer()
                TextField("", text: Binding(get: { g.passphrase.separator }, set: { g.passphrase.separator = String($0.prefix(1)) }))
                    .textFieldStyle(.plain).multilineTextAlignment(.center)
                    .font(.system(size: 13, design: .monospaced)).foregroundStyle(Theme.textPrimary)
                    .frame(width: 40, height: 28)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Theme.background))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.stroke))
            }
            CheckRow(title: t("gen.capitalize"), isOn: Binding(get: { g.passphrase.capitalize }, set: { g.passphrase.capitalize = $0 }))
            CheckRow(title: t("gen.includeNumber"), isOn: Binding(get: { g.passphrase.includeNumber }, set: { g.passphrase.includeNumber = $0 }))
        }
    }
}

struct CompactPrimaryStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.onAccent)
            .padding(.horizontal, 14).frame(height: 30)
            .background(RoundedRectangle(cornerRadius: 9).fill(Theme.accent.opacity(configuration.isPressed ? 0.8 : 1)))
    }
}
