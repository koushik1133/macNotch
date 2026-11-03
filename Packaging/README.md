# Packaging

| File | What it is |
|---|---|
| `PrivacyInfo.xcprivacy` | Privacy manifest. It declares no tracking, no collected data, and the required-reason APIs SparkV calls: UserDefaults, file timestamps and system boot time. `build.sh` copies it to `SparkV.app/Contents/Resources` (Sources/Labs/AppShell/INTEGRATION.md, step 3). Check it with `plutil -lint Packaging/PrivacyInfo.xcprivacy`. |
| `homebrew/sparkv.rb` | Homebrew cask template for a personal tap (`koushik1133/homebrew-sparkv`). It installs `SparkV.app` from the GitHub release zip. Uninstalling removes the optional Fan Control helper, and `--zap` also removes the settings, data and logs. |
| `release.sh` | Cuts a release. It bumps the version and build in Info.plist, runs `build.sh` and `Scripts/notarize.sh`, and keeps the debug symbols. It creates the GitHub release (a version with `-` becomes a pre-release) and updates the cask's version and sha256. Try it first with `DRY_RUN=1`. |

## First release through Homebrew

1. Create the public repo `github.com/koushik1133/homebrew-sparkv`, clone it next to this repo, and copy `homebrew/sparkv.rb` to `Casks/sparkv.rb`.
2. Run `DEVELOPER_ID="Developer ID Application: …" NOTARY_PROFILE=sparkv-notary ./Packaging/release.sh 1.1.0`.
3. Commit and push the tap, or rerun the release with `PUSH_TAP=1`.
4. People install SparkV with `brew install --cask koushik1133/sparkv/sparkv`, update it with `brew upgrade --cask sparkv`, and remove everything with `brew uninstall --zap --cask sparkv`.

Ship only notarized builds. Homebrew 5 removed `--no-quarantine`, and casks that fail Gatekeeper get disabled. Ad-hoc builds also lose their privacy permissions on every update.

## How SparkV finds updates

SparkV doesn't download or install updates itself, so the cask has no `auto_updates`. When the user turns on automatic checks or clicks Check for Updates, SparkV reads `api.github.com/repos/koushik1133/macNotch/releases`. It compares the newest release's tag (`v1.2.0`, `v1.3.0-beta.1`) with `CFBundleShortVersionString`, shows the release notes and opens the release page. Tag releases with the version, write the notes in Markdown, and attach `SparkV.dmg` and `SparkV.zip`.

## Uninstalling by hand

The steps are in SparkV under Settings › Advanced › Reset & Uninstall › Uninstall by hand. **Uninstall SparkV…** in the same place does it all for you. Everything goes to the Trash, so you can put it back.
