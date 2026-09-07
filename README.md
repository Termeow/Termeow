# Termeow

Native macOS SSH terminal client.

- Site: https://termeow.cn
- Source: https://github.com/Termeow/Termeow
- Agent guide: [AGENTS.md](AGENTS.md)
- Feature checklist: [FEATURES.md](FEATURES.md)

## References

Feature ideas are drawn from these clients. Termeow stays a native macOS app and does not copy their source, UI, or assets.

- [WindTerm](https://github.com/kingToolbox/WindTerm)
- [EdgeTerm](https://github.com/miskin-lee/EdgeTerm)
- [VelaShell](https://github.com/joesdu/VelaShell)

## Requirements

- macOS 15 or later
- Xcode 16 or later
- On Xcode 26, install the Metal toolchain once (`xcodebuild -downloadComponent MetalToolchain`) so SwiftTerm's shader resource can compile

## Develop

Open `Termeow.xcodeproj` and run the **Termeow** scheme.

```bash
swift test
xcodebuild -project Termeow.xcodeproj -scheme Termeow -destination 'platform=macOS' -skipPackagePluginValidation build
```

Land work through pull requests into `develop`. Do not push `develop` or `main` directly.

A daily job (00:00 Asia/Shanghai) publishes an ad-hoc signed zip on the [nightly pre-release](https://github.com/Termeow/Termeow/releases/tag/nightly). You can also run **Develop snapshot** by hand. That is a trial build, not a SemVer release, and it is not notarized. Unzip, then right-click `Termeow.app` and choose Open.

## Notes

- Passwords and key passphrases are stored in the Keychain service `cn.termeow.Termeow`. Session JSON never stores secrets.
- Passwords, Ed25519 keys, and unencrypted RSA PEM keys are supported. ECDSA user keys, encrypted PEM keys, and some RSA/OpenSSH compatibility combinations remain unsupported.
- App Sandbox is off in this first slice so security-scoped key bookmarks from `NSOpenPanel` can work.
