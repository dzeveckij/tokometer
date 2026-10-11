cask "tokometer" do
  version "0.3.0"
  sha256 "36ad50163b33407942e24b6047b6498ff5986719c6014cfe3ec98ed9a843a7f0"

  url "https://github.com/dzeveckij/tokometer/releases/download/v#{version}/Tokometer-#{version}.zip"
  name "Tokometer"
  desc "Menu bar app showing tokens per second for Claude Code, Codex and Antigravity"
  homepage "https://github.com/dzeveckij/tokometer"

  depends_on macos: :sonoma

  app "Tokometer.app"

  uninstall quit: "io.github.dzeveckij.tokometer"

  zap trash: [
    "~/Library/Application Support/Tokometer",
    "~/Library/Preferences/io.github.dzeveckij.tokometer.plist",
  ]

  caveats <<~EOS
    Tokometer is not notarized. If macOS refuses to open it, run:
      xattr -dr com.apple.quarantine #{appdir}/Tokometer.app
  EOS
end
