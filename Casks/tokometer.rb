cask "tokometer" do
  version "0.5.0"
  sha256 "e6a6e24f40374aa07dc2f790c22b297a77740778dc9c04d05022f73dfc441ee0"

  url "https://github.com/dzeveckij/tokometer/releases/download/v#{version}/Tokometer-#{version}.zip"
  name "Tokometer"
  desc "Menu bar app showing tokens per second for Claude Code, Codex, Antigravity, OpenCode and Grok Build"
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
