# The template for Casks/tapeup.rb in kkyrian/homebrew-tap. scripts/release.sh
# fills in the version and sha256 and commits it there.
cask "tapeup" do
  version "0.0.0"
  sha256 "0000000000000000000000000000000000000000000000000000000000000000"

  url "https://github.com/kkyrian/tapeup/releases/download/v#{version}/TapeUp.dmg"
  name "TapeUp"
  desc "Meeting recorder for Mac, built for you and your AI agent"
  homepage "https://github.com/kkyrian/tapeup"

  livecheck do
    url :url
    strategy :github_latest
  end

  # TapeUp updates itself through Sparkle.
  auto_updates true
  depends_on arch: :arm64
  depends_on macos: ">= :sequoia"

  app "TapeUp.app"

  # Recordings in ~/TapeUp are the user's and stay.
  zap trash: [
    "~/Library/Application Support/TapeUp",
    "~/Library/Caches/io.github.kkyrian.TapeUp",
    "~/Library/HTTPStorages/io.github.kkyrian.TapeUp",
    "~/Library/Preferences/io.github.kkyrian.TapeUp.plist",
  ]

  caveats <<~EOS
    TapeUp is not notarized by Apple, so macOS stops it the first time.
    Open it once, then click Open Anyway in
    System Settings > Privacy & Security.
  EOS
end
