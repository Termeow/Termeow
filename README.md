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

## Port forwarding

In the session editor, expand **Port Forwarding**, add a rule, and choose its type. Rules with **Start on connect** enabled begin after the destination terminal opens. Right-click that tab and choose **Port Forwarding…**, or click **Tunnels** in the status bar, to see listener state, connection count, and errors, and to start or stop individual rules.

| Mode | Listening side | Destination reached from |
| --- | --- | --- |
| Local (`-L`) | This Mac | The destination SSH server |
| Remote (`-R`) | The destination SSH server | This Mac |
| Dynamic (`-D`) | This Mac, as a SOCKS5 CONNECT proxy | The destination SSH server; domain names are resolved there |

For example, a local rule listening on `127.0.0.1:8080` and targeting `127.0.0.1:80` reaches the SSH server's loopback web service from your Mac. A remote rule listening on `127.0.0.1:9000` and targeting `127.0.0.1:3000` lets the SSH server reach a development service on your Mac. Other applications can use a dynamic rule at `127.0.0.1:1080` as a SOCKS5 proxy; select remote/proxy DNS resolution in those applications.

Listeners default to `127.0.0.1`. A non-loopback bind may expose a service or an **unauthenticated** SOCKS proxy to other computers; the editor warns before you save such a rule. Listen addresses must be literal IPv4 or IPv6 addresses. Remote binding is also subject to the SSH server's `GatewayPorts`, `AllowTcpForwarding`, and destination/listener restrictions. Termeow does not change server policy, your firewall, or the system proxy.

Rules belong to one terminal connection, including when it uses ProxyJump. Jump sessions' own rules and separate SFTP windows do not create listeners. Stopping a rule closes its forwarded connections but keeps the terminal open; disconnecting or closing the tab removes all its listeners and streams. A remote stop waits for cancellation acknowledgement; if that fails or takes more than five seconds, SSH closes to avoid leaving a remote listener in an unknown state. Failed rules do not prevent other rules or the terminal from working, except when an unacknowledged remote operation requires this safety shutdown.

Saved edits apply after reconnecting. Opening another tab with the same listening port can cause a bind conflict: inspect the error in its forwarding panel and change the port or stop the original rule. **Copy SSH Command** includes enabled forwarding rules as `-L`, `-R`, and `-D` arguments.

Current limits: 32 rules per session, 128 concurrent streams per rule, ten seconds to negotiate a forwarded connection, and fixed nonzero listen ports. This is TCP forwarding with SOCKS5 no-auth CONNECT (IPv4, IPv6, and domain destinations), not SOCKS4, SOCKS5 BIND/UDP, Unix-domain forwarding, or a standalone forwarding-only connection. Data streams use backpressure and preserve responses after an input half-close. See the [OpenSSH forwarding options](https://man.openbsd.org/ssh) and [SOCKS5 specification](https://www.rfc-editor.org/rfc/rfc1928).

The opt-in `PortForwardLiveTests` suite uses the same environment as `ProxyJumpLiveTests`. It temporarily creates **loopback-only** listeners on the authorized SSH server and this Mac, transfers test data through local/remote/SOCKS5 routes (also through a jump), and verifies conflicts, independent stop/restart, pending-connection cleanup, and terminal lifecycle behavior. It makes no persistent remote configuration or file changes.

## Notes

- Passwords and key passphrases are stored in the Keychain service `cn.termeow.Termeow`. Session JSON never stores secrets.
- Passwords, Ed25519 keys, and unencrypted RSA PEM keys are supported. ECDSA user keys, encrypted PEM keys, and some RSA/OpenSSH compatibility combinations remain unsupported.
- App Sandbox is off in this first slice so security-scoped key bookmarks from `NSOpenPanel` can work.
