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
- [ ] Settings window
- [ ] About panel
- [ ] App icon and Asset Catalog
- [ ] `CFBundleShortVersionString` / `MARKETING_VERSION` for SemVer releases
- [ ] LICENSE
- [ ] View menu (sidebar / status bar / SFTP)
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
- [ ] Drag and drop sessions between groups
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
- [x] Private-key authentication (Ed25519, RSA)
- [x] Passphrase-protected keys for those algorithms
- [x] `NSOpenPanel` security-scoped key bookmark
- [x] Host-key prompt: Cancel / Connect Once / Trust and Save
- [x] Reject a changed host key unless the user accepts it
- [x] Same host-key policy on the SFTP connection
- [x] Connect timeout
- [x] Keep-alive (empty channel-data while `keepAliveSeconds > 0`)
- [x] Startup command after the PTY opens
- [x] Configurable `TERM` (default `xterm-256color`)
- [x] PTY resize
- [x] Mapped `SSHError` strings in the UI; details stay in `os.Logger`
- [x] UI state follows a dropped SSH session
- [ ] ECDSA user keys (code throws `unsupportedAlgorithm`; README still claims this path)
- [ ] Reliable RSA-only *host* keys (Citadel / SwiftNIO SSH limit)
- [ ] SSH Agent (`ssh-agent`, 1Password, Secretive)
- [ ] Keyboard-interactive / 2FA prompts
- [ ] Agent forwarding
- [ ] ProxyJump (saved session as jump host, including chains)
- [ ] ProxyCommand
- [ ] HTTP / SOCKS5 / system proxy
- [ ] Local (`-L`), remote (`-R`), and dynamic (`-D`) port forwarding
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
- [ ] User-picked font, size, and line height (now 13 pt system monospaced)
- [ ] Terminal color schemes (now one hardcoded dark scheme)
- [ ] Follow system / light / dark chrome *and* terminal palette
- [ ] OSC window title (delegate is empty)
- [ ] `⌘G` find next
- [ ] Clear screen shortcut
- [ ] Select all in the scrollback
- [ ] Encoding besides UTF-8 (GB18030 / GBK / Big5 / Shift_JIS)
- [ ] Locale / `LANG` on the SSH shell request
- [ ] Line-number and timestamp gutter
- [ ] Block / multi-range selection
- [ ] Mouse reporting beyond what SwiftTerm already does
- [ ] Bell (visual / sound)
- [ ] Scrollback size cap in Settings
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
- [ ] `⌘1`–`⌘9` jump to tab N
- [ ] Reorder tabs
- [ ] Pin tab / tab color
- [ ] Background-tab activity / dirty highlight
- [ ] Confirm `⌘W` while the tab is still connected
- [ ] Split panes (`PaneLayout` is still `.leaf` only)
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
