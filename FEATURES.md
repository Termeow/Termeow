# Feature checklist

Living product list for Termeow. Checked items ship on `develop`.

Termeow is a **native macOS SSH client**. This list is the product backlog for that app, not a port of another stack.

- `[x]` done and usable
- `[ ]` not done
- Partial work is split into a done line and an open line

Update this file in the same PR as the feature.

## App shell

- [x] Native macOS app (Swift / SwiftUI / AppKit, no Electron / Tauri / WebView)
- [x] Bundle ID `cn.termeow.Termeow`
- [x] NavigationSplitView workspace: session sidebar, tab bar, terminal, status bar
- [x] Collapsible session sidebar
- [x] English UI strings
- [x] Simplified Chinese localization (`zh-Hans`)
- [x] Help menu opens https://termeow.cn
- [x] Unit tests for session JSON, host keys, Keychain, SFTP paths, and the leftover `TerminalEngine`
- [x] GitHub Actions CI and Dependabot
- [x] GitHub Actions develop snapshot zip (ad-hoc, not notarized)
- [x] Settings window
- [ ] About panel
- [ ] App icon and Asset Catalog
- [ ] `CFBundleShortVersionString` / `MARKETING_VERSION` for SemVer releases
- [ ] LICENSE
- [x] View menu (sidebar / status bar / SFTP)
- [ ] Notifications (disconnect, long-running command)
- [ ] Single-instance / dock reopen behavior beyond the default SwiftUI window
- [ ] Menu bar extras / tray (reference only; not required for an SSH client)

## Sessions

- [x] Session profile: name, host, port, username
- [x] Create, edit, duplicate, delete
- [x] Confirm before deleting a session (closes its tabs, removes Keychain secret)
- [x] Inline rename
- [x] Double-click or Return to connect
- [x] Search by name, host, user, group, port
- [x] Groups: create, rename, delete (sessions move back to Sessions)
- [x] Move a session to a group, including a new group
- [x] New session can start already in a group
- [x] Favorites section and star toggle
- [x] Sort by name, host, or last used
- [x] Last-used timestamp
- [x] Expand / collapse groups
- [x] Empty and no-results states
- [x] Sidebar connection dots and open-tab count
- [x] Copy `ssh` command to the pasteboard
- [x] Session JSON omits secrets; passwords and key passphrases stay in Keychain
- [x] Persist sessions and empty groups (`SessionLibrary`)
- [x] Migrate the old bare profile-array JSON
- [ ] Nested groups
- [x] Drag sessions to reorder, Favorites, or an existing group
- [ ] Open in a new window
- [ ] Import `~/.ssh/config`
- [ ] Import Xshell / WinSCP / other session files
- [ ] Export / import Termeow session library (no secrets in the file)
- [ ] Recent-connections list separate from last-used sort
- [ ] Host-key manager (list / delete trusted keys, redact for screenshots)

## SSH

- [x] Interactive PTY session (Citadel / SwiftNIO SSH, not `/usr/bin/ssh`)
- [x] `SSHSession` protocol so the UI does not talk to Citadel
- [x] Password authentication
- [x] Private-key authentication (Ed25519 OpenSSH; RSA OpenSSH and unencrypted PEM)
- [x] Passphrase-protected OpenSSH keys (Ed25519 and RSA)
- [x] `NSOpenPanel` security-scoped key bookmark
- [x] Host-key prompt: Cancel / Connect Once / Trust and Save
- [x] Reject a changed host key unless the user accepts it
- [x] Same host-key policy on the SFTP connection
- [x] Configured timeout for each SSH handshake and for post-authentication setup (PTY/shell acknowledgements, or SFTP subsystem/version negotiation and initial directory lookup); cancellation closes pending connections
- [x] Keep-alive (empty channel-data while `keepAliveSeconds > 0`)
- [x] Connected state and startup command only after the server acknowledges both PTY and shell requests; immediate output is buffered during setup
- [x] Configurable `TERM` (default `xterm-256color`)
- [x] PTY resize
- [x] Mapped `SSHError` strings in the UI; details stay in `os.Logger`
- [x] UI state follows a dropped SSH session
- [ ] RSA SHA-2 negotiation (`rsa-sha2-512` / `rsa-sha2-256`) for every RSA private-key format
- [ ] ECDSA user keys (P-256, P-384, and P-521 in OpenSSH, SEC1, and PKCS#8 formats)
- [ ] Ed25519 user keys in PKCS#8 format
- [ ] Passphrase-protected PKCS#1, PKCS#8, and SEC1 PEM keys
- [ ] Reliable RSA-only *host* keys (Citadel / SwiftNIO SSH limit)
- [x] SSH Agent identities: `SSH_AUTH_SOCK` or a per-session Unix socket (OpenSSH, 1Password, Secretive protocol); explicit public-key selection and SHA-256 fingerprints; Ed25519, RSA SHA-2 (2048–8192 bits), and ECDSA P-256/P-384/P-521; terminal, SFTP, mixed-auth jump routes, and all TCP forwarding modes; bounded, cancellable requests, verified signatures, and rejection of late host-key approvals after disconnect. Third-party approval dialogs still need manual validation with those apps; security-key identities, destination constraints, and agent forwarding are separate work. For certificates, select the underlying plain agent key and a certificate file as described below.
- [ ] FIDO security-key identities (`ecdsa-sk`, `ed25519-sk`) through SSH Agent
- [x] OpenSSH v01 user certificates paired with an existing Ed25519/RSA private-key file or a selected Ed25519/RSA/ECDSA agent key; security-scoped certificate bookmarks re-read on reconnect, metadata/CA fingerprint/validity display and reload, bounded parsing and CA signature/key-match validation, RSA SHA-2 certificate authentication, terminal/SFTP/jump routes and server-controlled forwarding permissions. No plain-key/password fallback; principal mapping, CA trust, revocation, and restrictions remain server policy. Certificate issuance, automatic discovery, direct selection of certificate entries from an agent, and host certificates are not included.
- [ ] PuTTY `.ppk` private-key import or conversion
- [ ] Secure Enclave-backed P-256 identity
- [ ] `mldsa44-ed25519` user keys for post-quantum OpenSSH compatibility
- [ ] Keyboard-interactive / 2FA prompts
- [ ] Agent forwarding
- [x] ProxyJump (up to eight saved-session jump hosts, per-hop credentials and host-key checks, route validation, terminal and SFTP support)
- [ ] ProxyCommand
- [ ] HTTP / SOCKS5 / system proxy
- [x] Local (`-L`), remote (`-R`), and dynamic SOCKS5 CONNECT (`-D`) TCP forwarding, with saved rules, per-rule status/start/stop, loopback defaults, and connection-scoped cleanup
- [ ] Auto-reconnect with backoff
- [ ] Compression
- [ ] Extra environment variables (`AcceptEnv`)
- [ ] Connection diagnostics (DNS / TCP / auth / PTY step log)

## Terminal

- [x] SwiftTerm `TerminalView` (VT / xterm, 256 color, true color, alt screen, CJK, scrollback)
- [x] Keyboard input and macOS IME
- [x] Copy and paste (`⌘C` / `⌘V`)
- [x] Confirm a large or many-line paste
- [x] Find (`⌘F`): next, previous, case sensitive
- [x] Status bar: host:port, state, cols×rows, last error
- [x] User-picked font, size, and line height
- [x] Terminal color schemes
- [ ] Follow system / light / dark chrome *and* terminal palette
- [x] OSC window title
- [x] `⌘G` find next (`⌘⇧G` find previous)
- [x] Clear screen and scrollback (`⌘K`)
- [ ] Select all in the scrollback
- [ ] Encoding besides UTF-8 (GB18030 / GBK / Big5 / Shift_JIS)
- [ ] Locale / `LANG` on the SSH shell request
- [ ] Line-number and timestamp gutter
- [ ] Block / multi-range selection
- [ ] Mouse reporting beyond what SwiftTerm already does
- [x] Scrollback size cap in Settings
- [ ] Command suggestions from typed history
- [ ] Sender / snippet bar: send text or hex to one tab or all tabs
- [ ] Command palette

## Tabs and workspace

- [x] Multiple SSH tabs
- [x] Tab name and connection color
- [x] Close, close others, close to the right
- [x] Duplicate tab
- [x] Reconnect / disconnect from the tab menu
- [x] `⌘T` new tab, `⌘W` close, `⌘⇧[` / `⌘⇧]` previous / next
- [x] Restore open session IDs after relaunch (tabs stay disconnected)
- [x] Remember the selected session in the sidebar
- [ ] Restore and *reconnect* tabs
- [x] Remember the selected tab
- [x] `⌘1`–`⌘9` jump to tab N
- [x] Reorder tabs
- [ ] Pin tab / tab color
- [ ] Background-tab activity / dirty highlight
- [x] Confirm `⌘W` while the tab is still connected
- [x] Recursive tab groups with independent tab strips and empty split targets
- [x] Move existing sessions between groups without reconnecting using tab context menus
- [x] Native tab-strip hit testing and before/after insertion markers for adjacent tab reordering
- [x] Native per-tab close buttons and automatic split collapse when a group's final tab closes
- [x] Workspace-wide outer-edge split model preserving session identities and existing divider proportions
- [ ] Complete interactive validation of native cross-group dragging and edge-drop previews
- [x] Directional group focus, maximize/restore, merge all groups, and confirmed group closure
- [x] Resizable group dividers with persisted layout, proportions, and per-group selection
- [ ] Local shell tab (`/bin/zsh` — architecture only; not the product core)

## SFTP

SFTP is a **separate dual-pane window**, not a docked filer in the main chrome. It opens its **own** SSH connection (same profile and host-key policy, not multiplexed on the terminal session).

- [x] Open SFTP from the toolbar, Session menu, sidebar, or tab menu
- [x] Dual-pane local + remote browser
- [x] List, refresh, parent, home, typed path, back / forward
- [x] Filter by name; show / hide dotfiles
- [x] Upload and download files
- [x] Upload and download folders
- [x] Drag local files onto the remote pane
- [x] New folder, rename, delete (remote delete is permanent; local delete uses Trash)
- [x] Overwrite / merge confirmation
- [x] Transfer progress and cancel
- [x] Copy path; Reveal in Finder
- [x] Size, modified time, permissions column
- [x] Host-key prompt in the SFTP window
- [ ] Reuse the existing SSH connection (multiplex SFTP on the terminal client)
- [ ] Docked filer in the main window
- [ ] Jump the filer to the shell cwd (OSC 7 / remote `pwd`)
- [ ] Transfer queue with more than one job
- [ ] Resume interrupted transfers
- [ ] chmod / chown
- [ ] Remote file editor (open, save back, or watch an external editor)
- [ ] Dedicated SFTP-only session type (no terminal)
- [ ] Recursive remote delete of non-empty folders (now folders must be empty)

## Later (not next)

Do not start these until SSH, SFTP, Agent, and a first release are solid.

- [ ] FTP / FTPS
- [ ] Serial
- [ ] Telnet
- [ ] ZMODEM / XMODEM / YMODEM in the terminal
- [ ] Resource monitor, remote process manager, traceroute
- [ ] Session recording / asciinema export
- [ ] Plugin host
- [ ] In-app AI assistant
- [ ] Cloud sync (Gist or iCloud)
- [ ] Xshell-compatible URL / SSO launch
- [ ] Windows / Linux builds

## Ship

- [ ] Annotated `vMAJOR.MINOR.PATCH` on `main` (never on `develop`)
- [ ] GitHub Release notes
- [ ] Developer ID signing and Hardened Runtime
- [ ] Notarized `.dmg` (or equivalent)
- [ ] In-app or Sparkle update check
- [ ] App Sandbox with working key bookmarks (Sandbox is off on purpose today)
- [ ] Working https://termeow.cn (Help currently hits a 500)
- [ ] README: drop the ECDSA “main path” claim and the stale Metal-toolchain note
- [ ] Tests for host-key decisions, workspace restore, and the live `SSHTerminalView` path
