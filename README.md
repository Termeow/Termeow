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

## SSH Agent authentication

Choose **SSH Agent** under **Authentication** in a session's editor. Leave **Agent Socket** empty to use the app process's `SSH_AUTH_SOCK`, or enter the Unix socket path provided by OpenSSH, 1Password, or Secretive (`~/...` is accepted). Click **Load Agent Keys**, compare the SHA-256 fingerprint, explicitly select a public key, and save. Load/unlock private keys in the agent itself; Termeow never imports them. **Copy Public Key** copies the public OpenSSH key, suitable for installing on a server you administer.

Supported identities are Ed25519, RSA (2048–8192 bits), and ECDSA P-256/P-384/P-521. RSA uses `rsa-sha2-512` by default; select **Use RSA SHA-256 instead of SHA-512** for a server that requires `rsa-sha2-256`. There is no automatic retry or RSA/SHA-1 fallback. Certificate and FIDO/security-key entries are shown as unsupported and cannot be selected.

Only the selected public key is offered, once, even if the agent contains many keys. Saved sessions keep the socket setting and public key, not a private key, passphrase, or agent unlock secret. Removing a key from the agent causes login to fail rather than trying another key. Changing the socket clears the selection. An empty socket setting is resolved again on each connection, so it can follow OpenSSH's socket after a restart; a GUI app does not inherit later changes made in a shell. For a third-party agent, use the socket path from that app's setup instructions.

Terminal and SFTP connections support agent authentication, including each hop of a mixed password/private-key/agent jump route. Host keys are verified before an authentication signature is requested. Approve requests in the agent within the session timeout (signing is capped at 120 seconds; key listing at ten seconds). Closing/cancelling a connection interrupts a pending request, and a waiting approval does not block unrelated terminal routes. As SFTP currently opens a separate SSH route, it can trigger a separate approval.

The client implements the public-identity and sign-request operations in the [SSH Agent protocol](https://www.rfc-editor.org/rfc/rfc9987.html). It checks the Unix socket peer's user ID, caps response sizes and key counts, and verifies returned signatures with the selected public key before sending them to SSH. It does not add/delete keys, unlock agents, run shell commands to discover agents, or forward an agent socket to a server. OpenSSH destination-constrained identities require the `session-bind@openssh.com` extension and are not supported; an agent rejection is never bypassed. See the official [1Password agent instructions](https://www.1password.dev/ssh/agent) and [Secretive setup](https://github.com/maxgoedjen/secretive) for their socket and approval settings. Their native approval dialogs have not been validated by the automated fixtures.

**Copy SSH Command** declines routes containing an agent identity: a generic `ssh -J` command cannot preserve Termeow's selected key/socket per hop. To use such a route outside Termeow, configure OpenSSH's `IdentityAgent`, a public `IdentityFile`, and `IdentitiesOnly yes` for each host. This does not change how password/private-key routes are copied.

### Agent integration tests

```bash
TERMEOW_AGENT_INTEGRATION_TESTS=1 swift test --filter SSHAgentIntegrationTests
```

These opt-in tests use macOS's `ssh-agent`, `ssh-add`, `ssh-keygen`, and `sshd` with generated ephemeral keys, a private temporary socket, and a loopback-only server. They never modify the user's normal agent, SSH configuration, or `authorized_keys`. They verify all supported signature algorithms against OpenSSH, PTY output, SFTP listing, agent/mixed-auth jumps, rejected host keys, missing/refused keys, concurrent connections, cancellation, and timeouts. The fixture disables `StrictModes` only for its own temporary `authorized_keys` underneath the shared `/tmp` parent; the private fixture directory remains mode `0700`. CI opts into these tests. Ordinary `swift test` still runs the protocol/validation tests without starting OpenSSH processes.

## Notes

- Passwords and key passphrases are stored in the Keychain service `cn.termeow.Termeow`. Session JSON never stores secrets.
- Passwords, Ed25519 private-key files, unencrypted RSA PEM files, and the SSH Agent identities above are supported. ECDSA private-key files, encrypted PEM files, and some RSA/OpenSSH file-format combinations remain unsupported.
- App Sandbox is off in this first slice so security-scoped key bookmarks from `NSOpenPanel` can work.
