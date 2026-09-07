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

## Notes

- Passwords and key passphrases are stored in the Keychain service `cn.termeow.Termeow`. Session JSON never stores secrets.
- Password and Ed25519/ECDSA user keys are the main path. Some RSA-only host keys or encrypted private keys may fail; the app reports `unsupportedAlgorithm` instead of pretending the session connected.
- App Sandbox is off in this first slice so security-scoped key bookmarks from `NSOpenPanel` can work.
