import SwiftUI
import VaultKit

/// Text input with a label above it, in the app's themed style.
struct FormInput: View {
    let label: String
    @Binding var text: String
    var placeholder = ""
    var secure = false
    var mono = false
    var autofocus = false
    /// Optional small button inside the field's right edge (e.g. scan a QR code).
    var accessory: (symbol: String, help: String, action: () -> Void)?
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            FieldLabel(label)
            HStack(spacing: 2) {
                Group {
                    if secure { SecureField(placeholder, text: $text) } else { TextField(placeholder, text: $text) }
                }
                .focused($focused)
                .onAppear {
                    guard autofocus else { return }
                    // The popover hands focus to its first field when it appears; claim it after that.
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(120))
                        focused = true
                    }
                }
                .textFieldStyle(.plain)
                .font(.system(size: 13, design: mono ? .monospaced : .default))
                .foregroundStyle(Theme.textPrimary)
                if let accessory { IconButton(systemName: accessory.symbol, help: accessory.help, action: accessory.action) }
            }
            .padding(.leading, 9).padding(.trailing, accessory == nil ? 9 : 3).frame(height: 30)
            .background(RoundedRectangle(cornerRadius: 8).fill(Theme.background))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(focused ? Theme.accent : Theme.stroke, lineWidth: focused ? 1.5 : 1))
        }
    }
}

struct ItemEditorView: View {
    let state: AppState
    @State private var revealPassword = false

    private var draft: ItemDraft { state.editor ?? ItemDraft() }

    private func bind<T>(_ kp: WritableKeyPath<ItemDraft, T>) -> Binding<T> {
        Binding(get: { state.editor?[keyPath: kp] ?? ItemDraft()[keyPath: kp] }, set: { state.editor?[keyPath: kp] = $0 })
    }

    /// Optional model strings are edited as plain text; empty means nil.
    private func bindText(_ kp: WritableKeyPath<ItemDraft, String?>) -> Binding<String> {
        Binding(get: { state.editor?[keyPath: kp] ?? "" }, set: { state.editor?[keyPath: kp] = $0.isEmpty ? nil : $0 })
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            // Always visible: this used to sit at the bottom of a long form, where a failed save went unnoticed.
            if let error = state.editorError {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.danger)
                    Text(error).font(.system(size: 12.5)).foregroundStyle(Theme.textPrimary).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 9).fill(Theme.danger.opacity(0.14)))
                .overlay(RoundedRectangle(cornerRadius: 9).stroke(Theme.danger.opacity(0.5)))
                .padding(.horizontal, 14).padding(.bottom, 8)
            }
            ScrollView(showsIndicators: false) {
                VStack(spacing: 10) {
                    if draft.isNew && !state.editorFocusesKey { typeCard }
                    mainCard
                    switch draft.type {
                    case .login: websitesCard
                    case .card: cardCard
                    case .identity: identityCard
                    case .secureNote: EmptyView()
                    }
                    notesCard
                    customFieldsCard
                    if draft.organizationId != nil {
                        Text(t("edit.orgNote")).font(.system(size: 11.5)).foregroundStyle(Theme.textSecondary)
                    }
                }
                .padding(.horizontal, 14).padding(.bottom, 16)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var header: some View {
        HStack {
            Button(t("edit.cancel")) { state.cancelEditor() }
                .buttonStyle(.plain).handCursor().font(.system(size: 13.5, weight: .medium)).foregroundStyle(Theme.accent)
            Spacer()
            Text(draft.isNew ? t("edit.newTitle") : t("edit.editTitle"))
                .font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.textPrimary)
            Spacer()
            Button(state.isSaving ? t("edit.saving") : t("edit.save")) { Task { await state.saveEditor() } }
                .buttonStyle(CompactPrimaryStyle()).handCursor().disabled(state.isSaving)
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
    }

    private var typeCard: some View {
        Card {
            FieldLabel(t("edit.itemType"))
            SegmentedChoice(options: [(ItemType.login, t("type.login")), (.card, t("type.card")),
                                      (.identity, t("type.identity")), (.secureNote, t("type.note"))],
                            selection: bind(\.type))
        }
    }

    private var mainCard: some View {
        Card {
            FormInput(label: t("edit.name"), text: bind(\.name), autofocus: draft.isNew && !state.editorFocusesKey)
            if draft.type == .login {
                FormInput(label: t("edit.username"), text: bind(\.username))
                passwordInput
                FormInput(label: t("edit.totp"), text: bind(\.totp), placeholder: t("edit.totpHint"), mono: true, autofocus: state.editorFocusesKey,
                          accessory: ("qrcode.viewfinder", t("qr.scan"), { ItemMenu.popUpQRChoices(state: state) }))
                    .onChange(of: draft.totp) { _, _ in state.authenticatorKeyChanged() }
            }
            folderPicker
            CheckRow(title: t("edit.favorite"), isOn: bind(\.favorite))
        }
    }

    private var passwordInput: some View {
        VStack(alignment: .leading, spacing: 4) {
            FieldLabel(t("edit.password"))
            HStack(spacing: 2) {
                Group {
                    if revealPassword { TextField("", text: bind(\.password)) } else { SecureField("", text: bind(\.password)) }
                }
                .textFieldStyle(.plain).font(.system(size: 13, design: .monospaced)).foregroundStyle(Theme.textPrimary)
                IconButton(systemName: revealPassword ? "eye.slash" : "eye", help: revealPassword ? t("detail.hide") : t("detail.reveal")) { revealPassword.toggle() }
                IconButton(systemName: "wand.and.stars", help: t("edit.generate")) {
                    state.editor?.password = state.generator.fresh()
                    revealPassword = true
                }
            }
            .padding(.leading, 9).padding(.trailing, 3).frame(height: 30)
            .background(RoundedRectangle(cornerRadius: 8).fill(Theme.background))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.stroke))
        }
    }

    private var folderPicker: some View {
        VStack(alignment: .leading, spacing: 4) {
            FieldLabel(t("edit.folder"))
            Menu {
                Button(t("filter.noFolder")) { state.editor?.folderId = nil }
                Divider()
                ForEach(state.folders, id: \.id) { f in Button(f.name) { state.editor?.folderId = f.id } }
            } label: {
                SelectChip(icon: "folder", title: state.folders.first { $0.id == draft.folderId }?.name ?? t("filter.noFolder"), active: false)
            }
            .menuStyle(.button).buttonStyle(.plain).handCursor().menuIndicator(.hidden)
        }
    }

    private var websitesCard: some View {
        Card {
            ForEach(draft.uris.indices, id: \.self) { i in
                HStack(alignment: .bottom, spacing: 4) {
                    FormInput(label: t("edit.website"), text: Binding(
                        get: { state.editor?.uris.indices.contains(i) == true ? state.editor!.uris[i] : "" },
                        set: { if state.editor?.uris.indices.contains(i) == true { state.editor?.uris[i] = $0 } }
                    ), placeholder: "https://", mono: true)
                    if draft.uris.count > 1 {
                        IconButton(systemName: "minus.circle", tint: Theme.danger) { state.editor?.uris.remove(at: i) }
                    }
                }
            }
            Button { state.editor?.uris.append("") } label: {
                Label(t("edit.addWebsite"), systemImage: "plus").font(.system(size: 12.5, weight: .medium))
            }.buttonStyle(.plain).handCursor().foregroundStyle(Theme.accent)
        }
    }

    private var cardCard: some View {
        Card {
            FormInput(label: t("card.holder"), text: bindText(\.card.cardholderName))
            FormInput(label: t("card.brand"), text: bindText(\.card.brand))
            FormInput(label: t("card.number"), text: bindText(\.card.number), mono: true)
            HStack(spacing: 8) {
                FormInput(label: t("edit.expMonth"), text: bindText(\.card.expMonth), placeholder: "MM", mono: true)
                FormInput(label: t("edit.expYear"), text: bindText(\.card.expYear), placeholder: "YYYY", mono: true)
            }
            FormInput(label: t("card.code"), text: bindText(\.card.code), secure: true, mono: true)
        }
    }

    private var identityCard: some View {
        let fields: [(String, WritableKeyPath<ItemDraft, String?>)] = [
            ("id.title", \.identity.title), ("id.first", \.identity.firstName), ("id.middle", \.identity.middleName),
            ("id.last", \.identity.lastName), ("id.username", \.identity.username), ("id.company", \.identity.company),
            ("id.email", \.identity.email), ("id.phone", \.identity.phone), ("id.address1", \.identity.address1),
            ("id.address2", \.identity.address2), ("id.address3", \.identity.address3), ("id.city", \.identity.city),
            ("id.state", \.identity.state), ("id.zip", \.identity.postalCode), ("id.country", \.identity.country),
            ("id.ssn", \.identity.ssn), ("id.passport", \.identity.passportNumber), ("id.license", \.identity.licenseNumber),
        ]
        return Card {
            ForEach(fields.indices, id: \.self) { i in
                FormInput(label: t(fields[i].0), text: bindText(fields[i].1))
            }
        }
    }

    private var notesCard: some View {
        Card {
            FieldLabel(t("edit.notes"))
            TextEditor(text: bind(\.notes))
                .font(.system(size: 13)).foregroundStyle(Theme.textPrimary)
                .scrollContentBackground(.hidden)
                .padding(4).frame(height: 84)
                .background(RoundedRectangle(cornerRadius: 8).fill(Theme.background))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.stroke))
        }
    }

    private var customFieldsCard: some View {
        Card {
            FieldLabel(t("detail.customFields").uppercased())
            ForEach(draft.fields.indices, id: \.self) { i in
                VStack(spacing: 6) {
                    HStack(spacing: 6) {
                        FormInput(label: t("edit.fieldName"), text: fieldBinding(i, \.name))
                        IconButton(systemName: "minus.circle", tint: Theme.danger) { state.editor?.fields.remove(at: i) }
                    }
                    FormInput(label: t("edit.fieldValue"), text: fieldBinding(i, \.value), secure: draft.fields[i].type == .hidden)
                    CheckRow(title: t("edit.fieldHidden"), isOn: Binding(
                        get: { state.editor?.fields.indices.contains(i) == true && state.editor!.fields[i].type == .hidden },
                        set: { if state.editor?.fields.indices.contains(i) == true { state.editor?.fields[i].type = $0 ? .hidden : .text } }))
                }
                if i < draft.fields.count - 1 { Divider().overlay(Theme.stroke) }
            }
            Button { state.editor?.fields.append(CustomField(name: "", value: "", type: .text)) } label: {
                Label(t("edit.addField"), systemImage: "plus").font(.system(size: 12.5, weight: .medium))
            }.buttonStyle(.plain).handCursor().foregroundStyle(Theme.accent)
        }
    }

    private func fieldBinding(_ i: Int, _ kp: WritableKeyPath<CustomField, String?>) -> Binding<String> {
        Binding(
            get: { state.editor?.fields.indices.contains(i) == true ? (state.editor!.fields[i][keyPath: kp] ?? "") : "" },
            set: { if state.editor?.fields.indices.contains(i) == true { state.editor?.fields[i][keyPath: kp] = $0 } }
        )
    }
}
