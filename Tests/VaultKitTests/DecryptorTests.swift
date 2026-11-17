import XCTest
@testable import VaultKit

final class DecryptorTests: XCTestCase {
    private func enc(_ s: String, _ k: VaultKey) -> String { try! EncString.encrypt(s, with: k) }

    func testPersonalItemWithPerItemKey() throws {
        let userKey = VaultKey.random(), itemKey = VaultKey.random()
        let dec = VaultDecryptor(userKey: userKey, encryptedPrivateKey: nil, organizations: [])
        let cipher: [String: Any] = [
            "id": "c1", "type": 1, "favorite": true,
            "key": try EncString.encrypt(itemKey.bytes, with: userKey), // cipher key, wrapped by the user key
            "name": enc("Keyed item", itemKey),
            "login": ["username": enc("u", itemKey), "password": enc("p", itemKey), "uris": [["uri": enc("https://k.test", itemKey), "match": NSNull()]]],
            "fields": [["name": enc("f", itemKey), "value": enc("v", itemKey), "type": 1]],
        ]
        let item = try dec.item(from: cipher)
        XCTAssertEqual(item.name, "Keyed item")
        XCTAssertEqual(item.login?.password, "p")
        XCTAssertEqual(item.login?.uris?.first?.uri, "https://k.test")
        XCTAssertEqual(item.fields?.first?.type, .hidden)
        // The user key alone must not decrypt it.
        XCTAssertThrowsError(try VaultDecryptor(userKey: userKey, encryptedPrivateKey: nil, organizations: [])
            .item(from: cipher.merging(["key": NSNull(), "name": enc("x", itemKey)]) { $1 }))
    }

    func testOrganizationItemUsesTheUnwrappedOrgKey() throws {
        let userKey = VaultKey.random(), orgKey = VaultKey.random()
        var error: Unmanaged<CFError>?
        let priv = SecKeyCreateRandomKey([kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits: 2048] as CFDictionary, &error)!
        let pkcs1 = SecKeyCopyExternalRepresentation(priv, &error)! as Data
        let wrappedOrgKey = SecKeyCreateEncryptedData(SecKeyCopyPublicKey(priv)!, .rsaEncryptionOAEPSHA1, orgKey.bytes as CFData, &error)! as Data
        let encPrivate = try EncString.encrypt(TestDER.wrapPKCS8(pkcs1), with: userKey)

        let dec = VaultDecryptor(userKey: userKey, encryptedPrivateKey: encPrivate,
                                 organizations: [["id": "org1", "name": "Acme", "key": "4.\(wrappedOrgKey.base64EncodedString())"]])
        XCTAssertEqual(dec.orgKeys["org1"], orgKey)

        let sync: [String: Any] = [
            "profile": ["organizations": [["id": "org1", "name": "Acme"]]],
            "folders": [["id": "f1", "name": enc("Work", userKey)]],
            "ciphers": [
                ["id": "o1", "type": 1, "organizationId": "org1", "name": enc("Shared login", orgKey), "login": ["password": enc("shared-pw", orgKey)]],
                ["id": "p1", "type": 2, "name": enc("My note", userKey), "notes": enc("body", userKey), "folderId": "f1"],
                ["id": "gone", "type": 1, "name": enc("Trashed", userKey), "deletedDate": "2026-01-01T00:00:00Z"],
                ["id": "bad", "type": 1, "organizationId": "unknown-org", "name": enc("No key", userKey)],
            ],
        ]
        let result = dec.snapshot(from: sync)
        XCTAssertEqual(Set(result.snapshot.items.map(\.name)), ["Shared login", "My note"])
        XCTAssertEqual(result.snapshot.items.first { $0.id == "o1" }?.login?.password, "shared-pw")
        XCTAssertEqual(result.skipped, 1, "an item whose org key is missing is skipped, not fatal")
        XCTAssertEqual(result.snapshot.folders.first?.name, "Work")
        XCTAssertEqual(result.snapshot.organizations.first?.name, "Acme")
    }

    func testTokenErrorClassification() throws {
        func classify(_ json: String, _ status: Int = 400) -> VaultError { BitwardenAPI.classifyTokenError(data: Data(json.utf8), status: status) }
        XCTAssertEqual(classify(#"{"error":"invalid_grant","error_description":"invalid_username_or_password"}"#), .invalidPassword)
        XCTAssertEqual(classify(#"{"error":"invalid_grant","error_description":"Two factor required.","TwoFactorProviders":[0,1],"TwoFactorProviders2":{"1":{"Email":"a***@x.com"}}}"#),
                       .twoFactor(TwoFactorChallenge(providers: [.authenticator, .email], emailHint: "a***@x.com")))
        XCTAssertEqual(classify(#"{"error":"invalid_grant","error_description":"Two-step token is invalid. Try again."}"#), .invalidTwoFactorCode)
        XCTAssertEqual(classify(#"{"ErrorModel":{"Message":"New device verification required."}}"#), .newDeviceVerification)
        XCTAssertEqual(classify(#"{"error":"invalid_grant","HCaptcha_SiteKey":"abc"}"#), .captchaRequired)
        XCTAssertEqual(classify(#"{"ErrorModel":{"Message":"Too many login requests"}}"#, 429), .server("Too many login requests"))
        XCTAssertEqual(classify("not json", 500), .server("HTTP 500"))
    }

    func testEndpointsForEachServerKind() {
        XCTAssertEqual(Endpoints(server: .bitwardenUS).api.absoluteString, "https://api.bitwarden.com")
        XCTAssertEqual(Endpoints(server: .bitwardenEU).identity.absoluteString, "https://identity.bitwarden.eu")
        let own = Endpoints(server: .selfHosted("https://vault.example.com/"))
        XCTAssertEqual(own.api.absoluteString, "https://vault.example.com/api")
        XCTAssertEqual(own.identity.absoluteString, "https://vault.example.com/identity")
    }

    func testJSONNormalisationHandlesPascalCase() throws {
        let obj = try JSONUtil.parseObject(Data(#"{"Ciphers":[{"Id":"1","Login":{"Username":"x"}}],"Profile":{"Id":"u"}}"#.utf8))
        XCTAssertEqual(((obj["ciphers"] as? [[String: Any]])?.first?["id"]) as? String, "1")
        XCTAssertEqual((obj["profile"] as? [String: Any])?["id"] as? String, "u")
    }
}

/// Every request must carry the client headers the cloud insists on.
final class HeaderTests: XCTestCase {
    final class Capture: URLProtocol, @unchecked Sendable {
        nonisolated(unsafe) static var seen: [URLRequest] = []
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            Self.seen.append(request)
            let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(#"{"kdf":0,"kdfIterations":600000,"access_token":"t","expires_in":3600}"#.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}
    }

    func testPreloginTokenAndSyncSendClientHeaders() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [Capture.self]
        Capture.seen = []
        let api = BitwardenAPI(server: .bitwardenUS, device: DeviceInfo(identifier: "dev"), session: URLSession(configuration: config))
        _ = try await api.prelogin(email: "a@b.c")
        _ = try await api.token(TokenGrant(.refresh("r")))
        _ = try await api.sync(accessToken: "t")
        XCTAssertEqual(Capture.seen.count, 3)
        for req in Capture.seen {
            XCTAssertEqual(req.value(forHTTPHeaderField: "Bitwarden-Client-Version"), ClientIdentity.version, req.url!.path)
            XCTAssertEqual(req.value(forHTTPHeaderField: "Bitwarden-Client-Name"), ClientIdentity.name, req.url!.path)
        }
    }
}

final class CipherRequestBodyTests: XCTestCase {
    /// Shaped like a real cloud response (keys only; values are placeholders).
    private let response: [String: Any] = [
        "object": "cipherDetails", "id": "abc", "type": 1, "organizationId": NSNull(), "folderId": "f",
        "edit": true, "viewPassword": true, "permissions": ["delete": true], "organizationUseTotp": true,
        "data": #"{"Name":"2.old","Totp":"2.old","Username":"2.old"}"#, // legacy blob: must not be sent back
        "name": "2.n", "notes": NSNull(), "favorite": false, "reprompt": 0, "key": "2.k",
        "revisionDate": "2026-01-01T00:00:00Z", "creationDate": "2026-01-01T00:00:00Z", "deletedDate": NSNull(), "archivedDate": NSNull(),
        "collectionIds": [], "attachments": [["id": "a1", "fileName": "2.x"]], "passwordHistory": [["password": "2.p", "lastUsedDate": "2026-01-01T00:00:00Z", "extra": 1]],
        "login": ["uri": "2.legacy", "uris": [["uri": "2.u", "match": NSNull(), "uriChecksum": "2.c", "extra": 1]], "username": "2.u", "password": "2.p",
                  "totp": "2.t", "passwordRevisionDate": NSNull(), "autofillOnPageLoad": NSNull(), "fido2Credentials": [], "extra": 1],
        "secureNote": NSNull(), "card": NSNull(), "identity": NSNull(), "sshKey": NSNull(), "bankAccount": NSNull(), "driversLicense": NSNull(), "passport": NSNull(),
        "fields": [["name": "2.f", "value": "2.v", "type": 1, "linkedId": NSNull(), "extra": 1]],
    ]

    func testDropsLegacyDataAndResponseOnlyKeys() throws {
        let body = CipherRequestBody.make(from: response)
        for gone in ["data", "object", "id", "edit", "viewPassword", "permissions", "organizationUseTotp", "revisionDate", "creationDate",
                     "deletedDate", "collectionIds", "attachments", "secureNote", "card", "identity", "sshKey", "bankAccount", "driversLicense", "passport"] {
            XCTAssertNil(body[gone], "\(gone) must not be sent")
        }
        XCTAssertEqual(body["name"] as? String, "2.n")
        XCTAssertEqual(body["key"] as? String, "2.k", "the per-item key is kept")
        let login = try XCTUnwrap(body["login"] as? [String: Any])
        XCTAssertNil(login["uri"], "the legacy single `uri` is not part of the request")
        XCTAssertNil(login["extra"])
        XCTAssertEqual(login["totp"] as? String, "2.t")
        XCTAssertNil(((login["uris"] as? [[String: Any]])?.first)?["extra"])
        XCTAssertEqual(((login["uris"] as? [[String: Any]])?.first)?["uriChecksum"] as? String, "2.c")
        XCTAssertNil(((body["fields"] as? [[String: Any]])?.first)?["extra"])
        XCTAssertNil(((body["passwordHistory"] as? [[String: Any]])?.first)?["extra"])
    }

    func testEditedValuesWinAndNothingStaleSurvives() throws {
        var d = ItemDraft(type: .login); d.name = "N"; d.totp = ""   // user cleared the key
        d.username = "u"; d.password = "p"; d.uris = ["https://a.test"]
        let merged = try d.json(merging: response, totpInField: false) { "enc(\($0))" }
        let body = CipherRequestBody.make(from: merged)
        XCTAssertNil(body["data"], "a stale `data` would make the server keep the old key")
        XCTAssertTrue((body["login"] as? [String: Any])?["totp"] is NSNull, "the cleared key is sent as null")
        XCTAssertEqual((body["login"] as? [String: Any])?["username"] as? String, "enc(u)")
        XCTAssertNil((body["login"] as? [String: Any])?["uri"])
    }

    func testOtherTypesKeepTheirOwnObject() {
        let card = CipherRequestBody.make(from: ["type": 3, "name": "n", "card": ["number": "x", "extra": 1], "login": NSNull(), "data": "{}"])
        XCTAssertNotNil(card["card"]); XCTAssertNil(card["login"]); XCTAssertNil(card["data"])
        let note = CipherRequestBody.make(from: ["type": 2, "name": "n", "secureNote": ["type": 0], "card": NSNull()])
        XCTAssertNotNil(note["secureNote"]); XCTAssertNil(note["card"])
    }
}
