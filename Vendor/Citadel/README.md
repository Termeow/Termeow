# Citadel compatibility fixes

This runtime-only source copy is based on [Citadel 0.12.1](https://github.com/orlandos-nl/Citadel/tree/ae8562f895de06ccb86fdb1cbb65fd99c8976e12), commit `ae8562f895de06ccb86fdb1cbb65fd99c8976e12`. The upstream MIT license and the C sources' license notices are retained. Examples and upstream tests are omitted; Termeow's tests exercise the integration. Transitive dependencies remain managed by SwiftPM and the root lockfile.

The upstream APIs have several limitations affecting SSH agents and connection setup:

- The non-waiting overload replaces the inbound channel registry and drops algorithm/protocol settings. Remote forwarding can appear to listen but reject every incoming channel.
- The settings-based overload always uses a ten-second authentication timer, regardless of the configured timeout, and does not promptly finish that timer on disconnect.
- PTY/shell setup returns after writing the requests instead of waiting for the server's acknowledgements. Environment acknowledgements can also prematurely start an in-shell command.
- The SFTP setup timer completes before version negotiation, leaving a missing VERSION reply unbounded. Subsystem write completion is also mistaken for acknowledgement.

Local runtime changes:

- `Sources/Citadel/Client.swift` and `Sources/Citadel/ClientSession.swift`: preserve initialization settings/handlers, honor the configured handshake deadline, and complete pending authentication on channel closure.
- `Sources/Citadel/ChannelSetup.swift` (added): event-loop-confined setup deadline/cancellation and serialized request acknowledgement tracking, with child-channel cleanup on failure.
- `Sources/Citadel/TTY/Client/TTY.swift`: wait for requested environment, PTY, shell, and exec acknowledgements; buffer early output; apply one setup-only deadline; preserve the original operation error on close.
- `Sources/Citadel/SFTP/Client/SFTPClient.swift`: include channel opening, subsystem acknowledgement, and VERSION in a cancellable setup deadline. Termeow additionally bounds the initial REALPATH using the session timeout.

Termeow uses the settings-based API and only returns an authenticated connection. No success event is synthesized and no host-key or agent approval is bypassed.

This copy makes clean CI and Xcode builds reproducible without modifying SwiftPM caches or publishing an unrequested fork. When upgrading Citadel, compare the files listed above and rerun `TERMEOW_AGENT_INTEGRATION_TESTS=1 swift test`, including delayed approvals, channel-setup failures/timeouts, cancellation, PTY/SFTP, and forwarding through agent jump routes. Return to the upstream package once it contains equivalent fixes.
