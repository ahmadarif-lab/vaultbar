# Homebrew cask for the ahmadarif-lab/tap repository (Casks/vaultbar.rb).
# Release flow: bump the version in Resources/Info.plist -> Scripts/package_release.sh
# -> gh release create vX.Y.Z dist/VaultBar.dmg dist/VaultBar.pkg -> update version and the DMG sha256 below.
cask "vaultbar" do
  version "0.1.0"
  sha256 "006ef8ca0e93e5253f4912c1dae88e7225265e4d7cb50a2ddf520256c652c4a5"

  url "https://github.com/ahmadarif-lab/vaultbar/releases/download/v#{version}/VaultBar.dmg"
  name "VaultBar"
  desc "Menu bar app for a Bitwarden-compatible vault: vault, generator and live 2FA codes"
  homepage "https://github.com/ahmadarif-lab/vaultbar"

  depends_on macos: ">= :sonoma"

  app "VaultBar.app"

  # Ad-hoc signed, not notarized: clear quarantine so the first launch is not blocked.
  postflight do
    system_command "/usr/bin/xattr", args: ["-dr", "com.apple.quarantine", "#{appdir}/VaultBar.app"]
    # launchctl fails inside the cask sandbox; /usr/bin/open works.
    system_command "/usr/bin/open", args: ["#{appdir}/VaultBar.app"]
  end

  zap trash: [
    "~/Library/Application Support/VaultBar",
    "~/Library/Preferences/dev.ahmadarif.vaultbar.plist",
  ]
end
