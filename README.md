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

The build uses a [runtime-only Citadel compatibility copy](Vendor/Citadel/README.md) with targeted handshake, channel-setup, and inbound-channel fixes. It preserves remote forwarding with agent authentication, honors per-session approval timeouts, and waits for actual PTY/shell/subsystem acknowledgements. Clean builds require no edits to SwiftPM caches; other dependency versions remain pinned in `Package.resolved`.

The session timeout applies to each SSH handshake and, separately, to destination setup after authentication. Terminal setup must receive both PTY and shell acknowledgements before reporting connected or sending a startup command. SFTP setup has one budget covering channel creation, subsystem acknowledgement, version negotiation, and the initial home-directory lookup. Timeout or cancellation closes an incomplete connection; setup timers do not limit the lifetime of an established terminal or file transfer.

`swift test --filter SSHChannelSetupTests` runs isolated loopback protocol fixtures covering missing/rejected/delayed replies, disconnects, cancellation, immediate output, and reconnects. These tests do not start a shell or use external credentials.

A daily job (00:00 Asia/Shanghai) publishes an ad-hoc signed zip on the [nightly pre-release](https://github.com/Termeow/Termeow/releases/tag/nightly). You can also run **Develop snapshot** by hand. That is a trial build, not a SemVer release, and it is not notarized. Unzip, then right-click `Termeow.app` and choose Open.

## Jump hosts (ProxyJump)

Save a session for the jump host with its own authentication settings. In the destination session editor, choose that session under **Jump Host → Connect via**. The preview lists the route from the outermost jump to the destination. A jump session may itself use another saved jump, up to eight jump hosts in total. Choose **Direct Connection** to remove the dependency explicitly.

Both the terminal and SFTP use this route. Each hop authenticates separately and verifies its own host key. Passwords and key passphrases stay in Keychain; private keys are read locally and are never copied to a jump host. The jump server must permit SSH TCP forwarding to the next server. Hostnames after the first hop are resolved from the preceding server, so destinations can use private DNS names or addresses that your Mac cannot reach directly.

Cycles, missing jump sessions, and invalid connection settings block the connection instead of falling back to a direct connection. Deleting a jump session leaves dependent sessions blocked until you choose another jump or explicitly select **Direct Connection**. Saved-session changes apply to subsequent connections; existing connections keep their original route. Startup commands, terminal settings, and SFTP operations apply only to the destination, not the jump hosts.

**Copy SSH Command** includes the equivalent `-J` route, usernames, and ports. The copied command uses OpenSSH's own credential/configuration handling; it cannot read Termeow's Keychain or key bookmarks. This feature does not import `~/.ssh/config`, execute `ProxyCommand`, forward an SSH agent, or share transports between terminal and SFTP windows.

### Opt-in integration tests

The regular `swift test` suite validates routes, backward-compatible session storage, and setup deadlines without an external server. To exercise real PTY output, SFTP listing, rejection, cancellation, and timeout behavior against a test server, supply `TERMEOW_SSH_TEST_HOST`, `TERMEOW_SSH_TEST_USER`, and `TERMEOW_SSH_TEST_PASSWORD` through your test environment, then run:

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

Supported identities are Ed25519, RSA (2048–8192 bits), and ECDSA P-256/P-384/P-521. RSA uses `rsa-sha2-512` by default; select **Use RSA SHA-256 instead of SHA-512** for a server that requires `rsa-sha2-256`. There is no automatic retry or RSA/SHA-1 fallback. Certificate entries cannot be selected directly: select their underlying plain key and pair it with a certificate file below. FIDO/security-key entries remain unsupported.

Only the selected public key is offered, once, even if the agent contains many keys. Saved sessions keep the socket setting and public key, not a private key, passphrase, or agent unlock secret. Removing a key from the agent causes login to fail rather than trying another key. Changing the socket clears the selection. An empty socket setting is resolved again on each connection, so it can follow OpenSSH's socket after a restart; a GUI app does not inherit later changes made in a shell. For a third-party agent, use the socket path from that app's setup instructions.

Terminal and SFTP connections support agent authentication, including each hop of a mixed password/private-key/agent jump route. Local, remote, and SOCKS forwarding remain available on agent-authenticated terminal routes. Host keys are verified before an authentication signature is requested. Approve requests in the agent within the session timeout (signing is capped at 120 seconds; key listing at ten seconds). Closing/cancelling a connection interrupts a pending request, discards late host-key approval, and a waiting approval does not block unrelated terminal routes. As SFTP currently opens a separate SSH route, it can trigger a separate approval.

The client implements the public-identity and sign-request operations in the [SSH Agent protocol](https://www.rfc-editor.org/rfc/rfc9987.html). It checks the Unix socket peer's user ID, caps response sizes and key counts, and verifies returned signatures with the selected public key before sending them to SSH. It does not add/delete keys, unlock agents, run shell commands to discover agents, or forward an agent socket to a server. OpenSSH destination-constrained identities require the `session-bind@openssh.com` extension and are not supported; an agent rejection is never bypassed. See the official [1Password agent instructions](https://www.1password.dev/ssh/agent) and [Secretive setup](https://github.com/maxgoedjen/secretive) for their socket and approval settings. Their native approval dialogs have not been validated by the automated fixtures.

**Copy SSH Command** declines routes containing an agent identity or an enabled user certificate: a generic `ssh -J` command cannot preserve Termeow's selected key/socket/certificate per hop. To use such a route outside Termeow, configure OpenSSH's `IdentityAgent`, `IdentityFile`, `CertificateFile`, and `IdentitiesOnly yes` as appropriate for each host. This does not change how password/private-key routes without certificates are copied.

### Agent integration tests

```bash
TERMEOW_AGENT_INTEGRATION_TESTS=1 swift test --filter SSHAgentIntegrationTests
```

These opt-in tests use macOS's `ssh-agent`, `ssh-add`, `ssh-keygen`, and `sshd` with generated ephemeral keys, a private temporary socket, and a loopback-only server. They never modify the user's normal agent, SSH configuration, or `authorized_keys`. They verify all supported signature algorithms against OpenSSH, PTY output, SFTP listing, multi-hop agent/mixed-auth routes, all forwarding modes with actual data transfer, rejected host keys, missing/refused keys, concurrent connections, terminal/SFTP cancellation, and approvals lasting longer than ten seconds on direct and jump routes. The fixture disables `StrictModes` only for its own temporary `authorized_keys` underneath the shared `/tmp` parent; the private fixture directory remains mode `0700`. CI opts into these tests. Ordinary `swift test` still runs the protocol/validation tests without starting OpenSSH processes.

## OpenSSH user certificates

User certificates let a server authorize a CA-signed user key instead of installing every individual public key. They are SSH certificates, not X.509/TLS certificates, and are separate from the server host key checked by the connection prompt. Your administrator must configure server-side CA trust and issue the certificate; Termeow does not issue certificates or change the server's policy. See the [OpenSSH certificate overview](https://man.openbsd.org/ssh-keygen#CERTIFICATES) and [CertificateFile configuration](https://man.openbsd.org/ssh_config#CertificateFile).

In the session editor, choose **Private Key** or **SSH Agent** and configure the matching signing key. Enable **Use OpenSSH User Certificate**, choose its `-cert.pub` file, review the key/CA fingerprints and validity period, then save. The editor displays the certificate ID, serial, principals, critical option names, and permission extension names. **Reload Certificate** refreshes this preview after renewal; every new connection also reads the file again automatically. **Remove Certificate** explicitly restores ordinary key authentication. Switching to password authentication disables the certificate.

Supported v01 subject keys are Ed25519, RSA (2048–8192 bits), and ECDSA P-256/P-384/P-521. Private-key files retain their existing format support: Ed25519/RSA OpenSSH, including passphrases, and unencrypted RSA PKCS#1/PKCS#8 PEM. ECDSA certificate subjects require an agent. Supported CA signatures are Ed25519, RSA SHA-2 (2048–8192 bits), and those three ECDSA curves. RSA private-key certificates use SHA-512; agent certificates honor the session's SHA-512/SHA-256 choice. RSA/SHA-1, FIDO, host certificates, automatic certificate discovery, and directly selecting a certificate identity from an agent are not supported.

Termeow preserves the original signed bytes, validates certificate integrity and validity against the Mac's clock, and checks that the certificate matches the signing key before requesting a signature. Files are bounded (64 KiB decoded certificate, 128 KiB text) and must be regular files. Only a security-scoped file bookmark and display name are persisted, not certificate/private-key bytes. Renewing the file at the same location takes effect on reconnect; a moved or inaccessible file may need to be selected again. An established connection is not automatically disconnected when its certificate expires.

A valid CA signature proves integrity, not that the target server trusts the CA. Principal-to-account mapping, CA trust/revocation, critical options, and permissions remain the server's responsibility under the [OpenSSH certificate protocol](https://datatracker.ietf.org/doc/draft-ietf-sshm-cert/). A certificate principal need not equal the login username when the server provides a mapping. The client does not execute certificate commands locally or remove restrictions. An enabled certificate never falls back to an ordinary key or password if parsing, validity, key matching, or server authorization fails.

Certificates work on terminal and SFTP connections, including each hop of a mixed-authentication jump route. Each hop chooses its own certificate. Port forwarding works only when the server and certificate permit it: a certificate without `permit-port-forwarding` can reject a jump route or tunnel, and one without `permit-pty` cannot open an interactive terminal. SFTP uses a separate connection and can require another agent approval. Third-party agents that enforce additional destination binding remain unsupported as described above.

### Certificate integration tests

```bash
swift test --filter SSHUserCertificateTests
TERMEOW_CERTIFICATE_INTEGRATION_TESTS=1 swift test --filter SSHCertificateIntegrationTests
```

The opt-in suite generates temporary CA and user keys and starts a loopback-only OpenSSH server. It checks supported subject/CA algorithms and both agent RSA digests; encrypted/private-key formats; terminal/SFTP across mixed certificate jumps; renewal and mismatched/expired keys; cancellation; server principal mapping; rejection without plain-key fallback; and enforcement of forced commands, unknown critical options, PTY, and all TCP forwarding permissions. It never changes the user's agent, SSH configuration, or trusted CAs. `TERMEOW_AGENT_INTEGRATION_TESTS=1 swift test` also enables this suite for CI.

## Notes

- Passwords and key passphrases are stored in the Keychain service `cn.termeow.Termeow`. Session JSON never stores secrets.
- Passwords, Ed25519/RSA OpenSSH private-key files (including passphrases), unencrypted RSA PEM files, the SSH Agent identities, and user certificates above are supported. ECDSA/Ed25519 PKCS#8 private-key files, ECDSA OpenSSH/SEC1 files, and encrypted PEM files remain unsupported. RSA/OpenSSH without a user certificate still uses Citadel's legacy RSA signature path; complete SHA-2 negotiation for every plain private-key format remains on the roadmap.
- App Sandbox is off in this first slice so security-scoped key bookmarks from `NSOpenPanel` can work.
