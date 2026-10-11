cask "tokometer" do
  version "0.4.0"
  sha256 "e7564b61c518707de65d75c910d363224736e9779c30bdcbb5a25d108e647c3b"

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
