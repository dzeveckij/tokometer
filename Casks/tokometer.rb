cask "tokometer" do
  version "0.6.0"
  sha256 "7cd3e5a56ed2d28ee4c49cc06e272d8de7ad0d8205ddca0cb3db9ff0b3774630"

  url "https://github.com/dzeveckij/tokometer/releases/download/v#{version}/Tokometer-#{version}.zip"
  name "Tokometer"
  desc "Menu bar app showing tokens per second for Claude Code, Codex, Antigravity, OpenCode, Grok Build, pi and OMP"
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
