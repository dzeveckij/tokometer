cask "tokometer" do
  version "0.3.1"
  sha256 "2d037a4aeeaf6d878ef6cbbc9cf1f01014559cec13c0e95c7970252bb5e54a89"

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
