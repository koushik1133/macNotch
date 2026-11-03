# Homebrew cask for SparkV. Lives in a personal tap first:
#   github.com/koushik1133/homebrew-sparkv  →  Casks/sparkv.rb
# Users install with:
#   brew install --cask koushik1133/sparkv/sparkv
# Packaging/release.sh rewrites `version` and `sha256` on every release.
# Ship only notarized builds (Scripts/notarize.sh): Homebrew 5 dropped
# --no-quarantine and casks that fail Gatekeeper get disabled.
cask "sparkv" do
  version "1.0"
  sha256 "0000000000000000000000000000000000000000000000000000000000000000"

  url "https://github.com/koushik1133/macNotch/releases/download/v#{version}/SparkV.zip"
  name "SparkV"
  desc "Dynamic Island-style drawer around the MacBook notch"
  homepage "https://github.com/koushik1133/macNotch"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on arch: :arm64
  depends_on macos: ">= :sequoia"

  app "SparkV.app"

  # The Fan Control helper is optional and installed by the user from
  # SparkV; remove it with the app. Homebrew asks for the password itself.
  uninstall quit:      "com.sparkv.app",
            launchctl: "com.sparkv.fanhelper",
            delete:    [
              "/Library/LaunchDaemons/com.sparkv.fanhelper.plist",
              "/Library/PrivilegedHelperTools/com.sparkv.fanhelper",
            ]

  zap trash: [
    "~/Library/Application Support/NotchIsland",
    "~/Library/Application Support/SparkV",
    "~/Library/Caches/com.notchisland.app",
    "~/Library/Caches/com.sparkv.app",
    "~/Library/HTTPStorages/com.sparkv.app",
    "~/Library/HTTPStorages/com.sparkv.app.binarycookies",
    "~/Library/Logs/NotchIsland.log",
    "~/Library/Logs/SparkV*.log",
    "~/Library/Preferences/com.notchisland.app.plist",
    "~/Library/Preferences/com.sparkv.app.plist",
    "~/Library/Saved Application State/com.sparkv.app.savedState",
    "~/Library/WebKit/com.sparkv.app",
  ]

  caveats <<~EOS
    SparkV checks for updates only if you turn that on (Settings › General).
    Update with: brew upgrade --cask sparkv
    Privacy permissions stay listed in System Settings until you remove them:
      tccutil reset All com.sparkv.app
  EOS
end
