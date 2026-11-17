# VaultBar: PRD

A native macOS menu bar app for your Bitwarden-compatible password vault: search, copy, and live TOTP codes one click away, without opening a browser.

Working name: **VaultBar** (neutral; never use the Bitwarden name or logo in the app name, icon, bundle id or repo name). Public, MIT, `github.com/ahmadarif-lab/vaultbar`.

---

## 1. Problem

- The browser extension only lives inside Chrome; getting a password or a 2FA code for a native app, a terminal or a VPN client means opening Chrome first.
- The official clients only show TOTP codes on a paid plan, even though the authenticator key is the user's own data stored in their own vault.
- The official desktop app is a full window app, not a quick menu bar popover.

## 2. Goals (v1)

1. Menu bar popover: search the vault and copy a username, password or TOTP code in two keystrokes.
2. Live TOTP for every item that has an authenticator key, computed locally (RFC 6238), with a countdown ring.
3. Works with **Bitwarden cloud (US and EU)** and **self-hosted servers (Bitwarden self-hosted, Vaultwarden)**.
4. Unlock with Touch ID after the first master-password unlock; auto-lock on idle, sleep and screen lock.
5. Nothing secret ever written to disk in plain text; clipboard cleared automatically.

## 3. Non-goals (v1)

- Creating or editing items, folders, attachments, Sends, the generator, vault health. Those stay in the extension or web vault.
- Autofill into other apps or browsers.
- Implementing Bitwarden's crypto ourselves (see §6).
- Organizations/collections management (items from orgs are listed read-only if `bw` returns them).
- Windows/Linux.

## 4. Users and key flows

Single user, one vault, power user who lives in the menu bar.

**First run**
1. Choose server: Bitwarden.com (US), Bitwarden.eu, or Self-hosted (URL field).
2. Log in: email + master password (+ 2FA if the account has it; `bw login` handles the prompts: authenticator code, email code, or API key login via client id/secret).
3. Offer: enable Touch ID unlock, start at login.

**Daily use**
1. Click the menu bar icon (or global hotkey, default `⌃⌥⌘V`, configurable).
2. Type to search (name, username, URI). Arrow keys to move.
3. `↩` copies password, `⌘C` username, `⌘T` TOTP code. Click the code to copy it.
4. Popover closes; a small toast "Copied, clears in 30 s".

**Locked state**
- Popover shows a lock screen: Touch ID button + master password field.

## 5. Features

### 5.1 List and search
- Sections: **Favorites** (from vault favorites), **Authenticator** (all items with a TOTP key), **All items**.
- Filter chips: Folder, Type (Login, Card, Identity, Note), matching the extension's mental model.
- Fuzzy search over name, username, URIs, folder.
- Row: letter avatar, or favicon when enabled (see decision 3 in §11), name, username, copy buttons, TOTP code with countdown when present.

### 5.2 TOTP
- Parse the `login.totp` field in all forms:
  - Plain base32 secret (spaces allowed, any case).
  - `otpauth://totp/...?secret=&issuer=&algorithm=SHA1|SHA256|SHA512&digits=6|8&period=30`.
  - `steam://<secret>` (Steam Guard, 5 characters from the Steam alphabet).
- Code shown as `123 456`, ring countdown, next code previewed in the last 5 s.
- Pure Swift implementation with CryptoKit HMAC, unit-tested against the RFC 6238 test vectors.

### 5.3 Copy and clipboard
- Copy marks the pasteboard item as concealed/transient (`org.nspasteboard.ConcealedType`, `TransientType`) so clipboard managers skip it.
- Auto-clear after N seconds (default 30), only if the clipboard still holds our value.

### 5.4 Item detail (read-only)
- Click a row (or `→`) to see all fields: URIs (open in browser), notes, custom fields (hidden fields masked with reveal), card and identity fields.

### 5.5 Sync
- Sync on unlock, every 15 minutes while unlocked, and from a "Sync now" button. Show "Synced 2 min ago".

### 5.6 Lock
- Auto-lock after idle (default 15 min), on sleep, on screen lock, on fast user switch.
- Lock from the popover and from a hotkey.

### 5.7 Settings
- Server, account (log out), Touch ID on/off, auto-lock timeout, clipboard timeout, hotkey, start at login, favicons on/off, language (English default, Bahasa Indonesia), appearance follows system.

## 6. Architecture

### 6.1 Vault access: official `bw` CLI
- Requirement: `bitwarden-cli` (`brew install bitwarden-cli`); the app detects it and shows install instructions when missing.
- `bw config server <url>` per the chosen server; `bw login` / `bw unlock --raw` produce the session key.
- Run **`bw serve --hostname localhost --port <random>`** as a child process owned by the app; talk to its local REST API (`/list/object/items`, `/list/object/folders`, `/sync`, `/lock`, `/unlock`, `/status`).
  - Bind to localhost only, random port, kill on quit and on lock. Consider a per-launch secret: `bw serve` has no auth, so keep the port private and stop the server whenever the vault is locked.
- Why the CLI: login (incl. new-device verification and 2FA), KDF (PBKDF2/Argon2id), key derivation and cipher decryption stay in Bitwarden's own audited code. Reimplementing them is the riskiest part and is out of scope for v1.
- TOTP is computed in the app from the decrypted `login.totp`; the app never calls `bw get totp` (that path is gated on a paid plan).

### 6.2 Touch ID unlock
- After a successful master-password unlock (and only if the user opted in), store the master password in the Keychain behind biometrics; see decision 1 in §11.
- Re-enrolling fingerprints invalidates the item (BiometryCurrentSet), forcing a master-password unlock.

### 6.3 App structure (SwiftUI)
```
Sources/VaultBar/
  App/            VaultBarApp (MenuBarExtra), AppState (owns timers, bw process, lock state)
  Vault/          BWProcess (spawn/stop bw serve), VaultClient (REST), models (Item, Folder, Login…)
  TOTP/           TOTP.swift (RFC 6238 + otpauth + steam), tests
  Security/       Keychain, BiometricUnlock, Clipboard
  UI/             Popover, ItemRow, TOTPRing, ItemDetail, LockView, Settings window, themed components
  Resources/      Localizable (en, id), Info.plist, assets
Tests/
Scripts/          build_app.sh, package_release.sh (DMG + sha256)
```

### 6.4 Lessons from CSwapBar (MenuBarExtra `.window` pitfalls)
- `ScrollView` collapses to height 0 unless given an explicit frame.
- `.sheet` / `.confirmationDialog` never show (the popover closes first): use a separate `NSWindow` for login, settings and detail if needed.
- `.disabled()` dims the whole button content.
- Timers started in a popover `.task` die when the popover closes: TOTP refresh, sync and auto-lock timers live in `AppState.init`.
- Start at login via **SMAppService** (works with ad-hoc signing), not a LaunchAgent.

## 7. Security requirements

- No secret in UserDefaults, logs, crash reports or temp files. Logs in English, never containing item data.
- `bw serve` only on 127.0.0.1, stopped when locked or on quit; app quits it on crash via process group.
- Decrypted items held in memory only while unlocked; cleared on lock.
- Clipboard concealed + auto-clear.
- Hardened runtime on; App Sandbox off (needs to spawn `bw`), documented.
- Threat model section in the README: what the app protects against and what it does not (malware running as the same user can still reach `bw serve` while unlocked).

## 8. UI / polish standards

- Themed components, not stock widgets where they look out of place (search field, chips, rows, toasts), consistent in light and dark.
- English default, Bahasa Indonesia option; all code, logs and README in English (single README).
- Screenshots: small WebP from a **demo mode** with fake vault data (`--demo`); never real vault items.
- Neutral naming everywhere; icon is our own glyph.

## 9. Distribution

- Ad-hoc signed `.app` in a DMG, GitHub Releases, Homebrew cask `ahmadarif-lab/tap/vaultbar` (same flow as CSwapBar: bump version → `package_release.sh` → `gh release create` → update cask sha256).
- Cask postflight uses `/usr/bin/open` (launchctl fails inside the cask sandbox).
- Cask declares `depends_on formula: "bitwarden-cli"`.

## 10. Milestones

| | Scope | Done when |
|---|---|---|
| **M1** | Project skeleton, TOTP module + RFC tests, demo mode with fake items, popover list/search/copy | Demo mode usable; `swift test` green |
| **M2** | `bw` integration: server choice (US/EU/self-hosted), login, unlock, `bw serve` lifecycle, sync | Real vault listed against both bitwarden.com and a Vaultwarden instance |
| **M3** | Lock & security: Touch ID, auto-lock triggers, clipboard concealment/clear | Lock/unlock cycle verified; nothing secret on disk |
| **M4** | Detail view, settings window, hotkey, start at login, i18n en/id | Both languages and themes screenshot-checked |
| **M5** | README (with threat model), WebP screenshots, DMG, cask, v0.1.0 release | Installs via `brew install --cask` on a clean Mac |

## 11. Decisions (were open questions)

1. **What sits behind Touch ID: the master password, not the `bw` session key.**
   Stored in the Keychain with `kSecAccessControlBiometryCurrentSet` + `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`.
   Lock = `bw lock` + stop `bw serve`, so a locked app means a really locked vault (a stored session key would have to
   stay valid while "locked", and anyone holding it plus the CLI data file can decrypt the vault). Unlock = Touch ID →
   read the password → `bw unlock --passwordenv VB_PW --raw` with the password only in the child's environment, never in
   argv (visible in `ps`). Touch ID unlock is opt-in; without it every unlock asks for the master password.
2. **Hotkey default `⌃⌥⌘V`, configurable, can be turned off.** `⌥⌘V` is taken (Finder "Move item here"),
   `⌥Space`/`⌘Space` belong to Spotlight/Raycast/Alfred, `⌃⇧Space` is used by a similar Bitwarden launcher. Registered
   with Carbon `RegisterEventHotKey` (no Accessibility permission needed).
3. **Favicons off by default.** Rows show a coloured letter avatar. When turned on, icons come from the vault's own
   icon service (`https://icons.bitwarden.net/<domain>/icon.png` for cloud, `<server>/icons/<domain>/icon.png` for
   self-hosted/Vaultwarden), so domains are only ever sent to the server the user already trusts. Cached in memory only
   (a disk cache would leak the list of sites).
4. **Organization items included by default**, marked with the org name, with an "Organizations" filter chip and a
   setting to hide them. Everything is read-only in v1 anyway.
5. **Rename: "VaultBar" is taken in spirit.** No Homebrew cask uses it, but GitHub has several small `vaultbar` repos,
   one of them (`byhofman/vaultbar`) literally "a quick search bar for Bitwarden", which would confuse users and search.
   Proposed name: **Latchkey** (no exact GitHub repo or Homebrew cask found, neutral, reads as "the key you carry").
   Repo `ahmadarif-lab/latchkey`, bundle id `dev.ahmadarif.latchkey`, cask `latchkey`. Final call by the owner before
   the repo is created; rename this folder and file headings together.
