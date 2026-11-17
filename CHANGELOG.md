# Changelog

## 0.1.0

First release.

- Native Bitwarden client, no `bw` CLI: login (master password, API key), two-step verification
  (authenticator, e-mail, YubiKey, new-device code), sync, offline unlock, multiple accounts.
  Works with bitwarden.com, bitwarden.eu, self-hosted Bitwarden and Vaultwarden.
- Vault: fuzzy search, filters, favorites, copy, edit, clone, delete (to trash), add logins, cards,
  identities and notes, folder management, import and export of Bitwarden `.json`.
- 2FA tab with live TOTP codes, and scanning of setup QR codes from the screen, a file or the clipboard.
- Password and passphrase generator.
- Auto-type of username, password or 2FA code into the app in front, with suggested logins for the
  current app or site.
- Touch ID unlock, auto-lock, lock when closed, clipboard auto-clear, global hotkey, start at login.
- Light, dark or system theme; English and Bahasa Indonesia.
