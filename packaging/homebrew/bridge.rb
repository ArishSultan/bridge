# A Homebrew cask for Bridge. Casks live in a tap (a repository named homebrew-<tap>), so copy
# this into one, for example ArishSultan/homebrew-tap as Casks/bridge.rb, and fill in the
# version and the .dmg's SHA-256 (from SHA256SUMS.txt) for each release. Then:
#
#   brew install --cask ArishSultan/tap/bridge
cask "bridge" do
  version "0.0.0"
  sha256 "0000000000000000000000000000000000000000000000000000000000000000"

  url "https://github.com/ArishSultan/bridge/releases/download/v#{version}/Bridge-#{version}-macos-arm64.dmg"
  name "Bridge"
  desc "Sandboxed terminals for your projects and coding agents"
  homepage "https://github.com/ArishSultan/bridge"

  livecheck do
    url :url
    strategy :github_latest
  end

  # Sparkle updates it in place.
  auto_updates true
  depends_on arch: :arm64
  depends_on macos: ">= :sequoia"

  app "Bridge.app"

  zap trash: [
    "~/.config/bridge",
    "~/Library/Application Support/Bridge",
    "~/Library/Caches/Bridge",
    "~/Library/Preferences/dev.arish.bridge.plist",
  ]
end
