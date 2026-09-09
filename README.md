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

## Jump hosts (ProxyJump)

Save a session for the jump host with its own authentication settings. In the destination session editor, choose that session under **Jump Host → Connect via**. The preview lists the route from the outermost jump to the destination. A jump session may itself use another saved jump, up to eight jump hosts in total. Choose **Direct Connection** to remove the dependency explicitly.

Both the terminal and SFTP use this route. Each hop authenticates separately and verifies its own host key. Passwords and key passphrases stay in Keychain; private keys are read locally and are never copied to a jump host. The jump server must permit SSH TCP forwarding to the next server. Hostnames after the first hop are resolved from the preceding server, so destinations can use private DNS names or addresses that your Mac cannot reach directly.

Cycles, missing jump sessions, and invalid connection settings block the connection instead of falling back to a direct connection. Deleting a jump session leaves dependent sessions blocked until you choose another jump or explicitly select **Direct Connection**. Saved-session changes apply to subsequent connections; existing connections keep their original route. Startup commands, terminal settings, and SFTP operations apply only to the destination, not the jump hosts.

**Copy SSH Command** includes the equivalent `-J` route, usernames, and ports. The copied command uses OpenSSH's own credential/configuration handling; it cannot read Termeow's Keychain or key bookmarks. This feature does not import `~/.ssh/config`, execute `ProxyCommand`, forward an SSH agent, or share transports between terminal and SFTP windows.

### Opt-in integration tests

The regular `swift test` suite validates routes and backward-compatible session storage without a server. To exercise real PTY output, SFTP listing, rejection, cancellation, and timeout behavior, supply `TERMEOW_SSH_TEST_HOST`, `TERMEOW_SSH_TEST_USER`, and `TERMEOW_SSH_TEST_PASSWORD` through your test environment, then run:

```bash
swift test --filter ProxyJumpLiveTests
```

Only use an authorized disposable server. These tests open direct, one-jump, and two-jump connections to that server (forwarded hops use its `127.0.0.1`), print a fixed terminal marker, and read its home directory listing. They do not write remote files or persist host-key decisions. `TERMEOW_SSH_TEST_PORT` defaults to `22`; the same port must be reachable on the server's loopback interface. Never put credentials in committed files or CI logs.

## Notes

- Passwords and key passphrases are stored in the Keychain service `cn.termeow.Termeow`. Session JSON never stores secrets.
- Passwords, Ed25519 keys, and unencrypted RSA PEM keys are supported. ECDSA user keys, encrypted PEM keys, and some RSA/OpenSSH compatibility combinations remain unsupported.
- App Sandbox is off in this first slice so security-scoped key bookmarks from `NSOpenPanel` can work.
