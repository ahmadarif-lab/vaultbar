# Homebrew cask for the ahmadarif-lab/tap repository (Casks/vaultbar.rb).
# Release flow: bump the version in Resources/Info.plist -> Scripts/package_release.sh
# -> gh release create vX.Y.Z dist/VaultBar.dmg -> update version and sha256 below.
cask "vaultbar" do
  version "0.1.0"
  sha256 "REPLACE_WITH_SHA256_FROM_package_release.sh"

  url "https://github.com/ahmadarif-lab/vaultbar/releases/download/v#{version}/VaultBar.dmg"
  name "VaultBar"
  desc "Menu bar app for a Bitwarden-compatible vault: vault, generator and live 2FA codes"
  homepage "https://github.com/ahmadarif-lab/vaultbar"

  depends_on formula: "bitwarden-cli"
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
