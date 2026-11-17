import Foundation

/// One row of the read-only item detail view. Built here (not in the UI) so
/// the field mapping is unit-tested.
public struct DetailField: Identifiable, Sendable, Equatable {
    public enum Kind: Sendable, Equatable { case text, secret, uri, multiline, totp }
    public let id: String
    /// A key into `Strings` (localised in the view) or a literal custom-field name.
    public let labelKey: String?
    public let literalLabel: String?
    public let value: String
    public let kind: Kind

    init(_ id: String, key: String? = nil, label: String? = nil, value: String, kind: Kind = .text) {
        self.id = id; self.labelKey = key; self.literalLabel = label; self.value = value; self.kind = kind
    }
}

public struct DetailSection: Identifiable, Sendable, Equatable {
    public let id: String
    public let titleKey: String?
    public let fields: [DetailField]
}

extension VaultEntry {
    public func detailSections() -> [DetailSection] {
        var sections: [DetailSection] = []
        func add(_ id: String, _ title: String?, _ fields: [DetailField]) {
            if !fields.isEmpty { sections.append(DetailSection(id: id, titleKey: title, fields: fields)) }
        }
        func f(_ id: String, _ key: String, _ value: String?, _ kind: DetailField.Kind = .text) -> DetailField? {
            guard let value, !value.isEmpty else { return nil }
            return DetailField(id, key: key, value: value, kind: kind)
        }

        switch item.type {
        case .login:
            var main = [f("username", "detail.username", item.login?.username),
                        f("password", "detail.password", item.login?.password, .secret)].compactMap { $0 }
            if totp != nil { main.append(DetailField("totp", key: "detail.code", value: "", kind: .totp)) }
            add("login", nil, main)
            add("uris", nil, uris.enumerated().map { DetailField("uri\($0.offset)", key: "detail.website", value: $0.element, kind: .uri) })
        case .card:
            let c = item.card
            let expiry = [c?.expMonth, c?.expYear].compactMap { $0?.nonEmpty }.joined(separator: " / ")
            add("card", "detail.card", [
                f("holder", "card.holder", c?.cardholderName), f("brand", "card.brand", c?.brand),
                f("number", "card.number", c?.number, .secret), f("expiry", "card.expiry", expiry),
                f("cvv", "card.code", c?.code, .secret),
            ].compactMap { $0 })
        case .identity:
            let i = item.identity
            let name = [i?.title, i?.firstName, i?.middleName, i?.lastName].compactMap { $0?.nonEmpty }.joined(separator: " ")
            let street = [i?.address1, i?.address2, i?.address3].compactMap { $0?.nonEmpty }.joined(separator: ", ")
            let place = [i?.city, i?.state, i?.postalCode, i?.country].compactMap { $0?.nonEmpty }.joined(separator: ", ")
            let address = [street, place].filter { !$0.isEmpty }.joined(separator: "\n")
            add("identity", "detail.identity", [
                f("name", "id.name", name), f("company", "id.company", i?.company), f("username", "id.username", i?.username),
                f("email", "id.email", i?.email), f("phone", "id.phone", i?.phone),
                f("address", "id.address", address, .multiline),
                f("ssn", "id.ssn", i?.ssn, .secret), f("passport", "id.passport", i?.passportNumber, .secret),
                f("license", "id.license", i?.licenseNumber, .secret),
            ].compactMap { $0 })
        case .secureNote:
            break
        }

        if let notes = item.notes?.nonEmpty {
            add("notes", nil, [DetailField("notes", key: "detail.notes", value: notes, kind: .multiline)])
        }

        let custom = (item.fields ?? []).enumerated().compactMap { (i, field) -> DetailField? in
            guard field.type != .linked else { return nil }
            let name = field.name?.nonEmpty ?? "—"
            let value = field.type == .boolean ? ((field.value == "true") ? "✓" : "✗") : (field.value ?? "")
            guard !value.isEmpty else { return nil }
            return DetailField("cf\(i)", label: name, value: value, kind: field.type == .hidden ? .secret : .text)
        }
        add("custom", "detail.customFields", custom)

        add("meta", nil, [f("folder", "detail.folder", folderName), f("org", "detail.organization", organizationName)].compactMap { $0 })
        return sections
    }
}
