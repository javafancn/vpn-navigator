# VPN Navigator

**English** | [简体中文](README.zh-CN.md)

> English is the default README language. Most linked development and acceptance documents are currently written in Chinese.

A native macOS OpenVPN client with profile management, Original / Global VPN / Mainland China Direct routing, menu bar controls, and network diagnostics.

Supports managed IPv4/IPv6 dual-stack routing, IPv6 server endpoints, dual-stack China routing rules, and custom IPv6 split tunneling. See [Dual-stack support](docs/DUAL_STACK.md).

Closing the main window keeps the VPN and background services running and hides the Dock icon. Choose **Open Main Window** in the menu bar to restore the window and Dock icon; choose **Quit** to exit completely. The menu bar displays the navigation logo and VPN tunnel download/upload rates, sampled approximately once per second while connected, with automatic B/s, KB/s, and MB/s units. Missing or stale samples display **—**. These rates measure the VPN tunnel, not all traffic on your Mac.

Current development version: **0.8.11**. Three build channels are available: development preview, local test, and Developer ID distribution. Local-test builds include the engine and use administrator approval to pin code identity without a paid developer certificate. Real-network and user-Mac installation acceptance are still required. Production distribution requires signing, notarization, and release acceptance.

## Implemented features

- Five native workspaces, translucent glass that reveals the desktop, menu bar controls, a single main window, and session cleanup before quitting.
- Main-window shortcuts: ⌘1–5 to switch workspaces, ⌘F to search profiles, Return to enter the list, and ↑↓ to select. Supports VoiceOver status labels, keyboard focus, and the system Increase Contrast setting. See **Help → Keyboard & Accessibility** and [Keyboard and accessibility](docs/KEYBOARD_AND_ACCESSIBILITY.md).
- A translucent Quick Open panel with metadata search and keyboard navigation, ⇧⌘P, a menu bar entry, and an optional global shortcut with visible conflicts and retry support. Switching an active VPN requires confirmation; credentials are entered in the main window.
- `.ovpn` import, multi-word search, all/favorite/group filters, name/import-time sorting, reusable groups, notes, safe editing, and version restoration. Imported originals are retained in the profile library, and adjacent certificate material is embedded into the runtime copy.
- Import through Finder **Open With**, opening files on the Dock icon, and window drag and drop. Confirms filenames, queues requests while busy, deduplicates inputs, and reuses batch results and cancellation.
- Encrypted profile-library backups and restore previews, including original files, self-contained material, metadata, and history. Restored profiles receive new IDs and are added without replacing existing profiles. See [Encrypted backup and migration](docs/ENCRYPTED_BACKUP.md).
- Local profile health and embedded X.509 validity checks, opt-in certificate-expiry reminders, and a profile update wizard with preview and confirmation. Updates preserve settings and history, reject stale confirmations, recover from interruptions, and isolate old credentials when identity changes. See [Profile health and updates](docs/PROFILE_HEALTH_AND_UPDATES.md).
- Portable self-contained profile export, independent route previews, private atomic saves, and batch import with per-file results, progress, and cancellation. Individual failures do not discard successful imports.
- Username/password authentication with optional Keychain storage and prompts for missing credentials; encrypted private-key passphrases, SCRV1/password-concatenated static OTP, and CRV1 dynamic challenges during initial authentication. Challenge input is used only for that authentication attempt.
- Authenticated XPC, code-signature and permission checks, managed OpenVPN child processes, a Unix management socket, cancellable connections, and 20–180-second connection/authentication deadlines.
- Per-profile custom IPv4/IPv6 direct/VPN rules with enable/disable controls and conflict detection. Regional rules, mode switches, and safe reconnects preserve the current session policy. VPN exceptions are removed from both physical routes and PF direct-access tables.
- Route explanations distinguish offline previews from verified interfaces/gateways in the current session. One-click troubleshooting checks the helper, profile, rules, IPv6, DNS, TCP, and routes, with suggested actions. Checks are user-triggered, cancellable, and bounded by a 30-second overall deadline.
- Three routing policies, with rule/global switching inside the same tunnel. The main window and menu bar show the helper-verified actual mode. Mainland China IPv4/IPv6 direct routes follow the tunnel's actual address families; other default traffic uses the VPN. Includes endpoint pinning, LAN protection, route transaction journals, validation, live updates, and rollback after process exit is confirmed.
- Write-ahead DNS records tied to the original physical network service and trusted DNS-hook checkpoints. Restoration occurs only while current values still belong to this app; conflicts retain recovery evidence.
- **Experimental PF disconnect protection, off by default**: an independent anchor, reference token, interface-bound states, IPv4/IPv6 physical-egress policy, and retained protection after failures. Incompatible host PF configurations are rejected; the main ruleset is not replaced.
- Optional safe reconnect in managed modes: after PF verification, confirms cleanup of the old child process, DNS, and routes before starting another session while protection remains active. Limited to three attempts per ten minutes.
- A verifiable offline seed of IPv4 regional rules, downloads with official-source fallback and streaming size limits, local import, daily updates, and snapshot restoration.
- Real TCP port probes, system DNS queries, traceroute limited to eight hops, and three ICMP latency/loss probes, with cancellation and deadlines.
- Manual public IPv4/IPv6 egress checks using fixed HTTPS services, separate ephemeral requests, and bounded responses. Actual VPN peer and read-only session routes help distinguish matching egress, direct traffic, and unverifiable results. Results remain in the current window and do not constitute DNS or all-traffic leak testing. See [Public egress checks](docs/PUBLIC_EGRESS.md).
- Private, bounded failure-category logs and redacted diagnostic exports. Reports exclude raw engine output, addresses, domains, profiles, and credentials.
- Session quality and connection history: rates sampled over real intervals and a connection/reconnect/route-switch timeline. Local retention defaults to seven days, with 30/90-day options, pause, and confirmed clearing. Sleep or observation gaps do not inflate connected duration. Raw reports and credentials are not retained. See [Connection history](docs/CONNECTION_HISTORY.md).
- First-use checks, connection preferences, launch at login, and upgrade/uninstall preparation. Maintenance also disables launch at login, keeps profiles by default, and verifies Keychain cleanup when deletion is explicitly selected.
- macOS 13-targeted engines built from checksum-verified OpenVPN/OpenSSL sources; installers for both architectures, automatic version extraction, update-package architecture filtering, minimum-OS audits, signing/notarization, and an optional Draft Release workflow.

The application supports Simplified Chinese and English and follows the system language by default. Save a choice under **Settings & Maintenance → Interface Language**; it takes effect on the next launch without interrupting the current VPN. See [Language and localization](docs/LOCALIZATION.md). The README's default language does not change this application behavior.

Two optional Windows DNS hints commonly found in cross-platform profiles are accepted: `ignore-unknown-option block-outside-dns` and `setenv opt block-outside-dns`. Only these exact targets are allowed, without opening generic environment variables or ignore lists. On macOS, OpenVPN handles them as optional directives; accepting them does not enable DNS leak protection. See the [Windows-specific options in the OpenVPN 2.7 manual](https://openvpn.net/community-docs/community-articles/openvpn-2-7-manual/).

Profile filtering, sorting, and reusable groups are described in [Profile library management](docs/PROFILE_LIBRARY.md).

Private local index backups and confirmed recovery after corruption are described in [Profile index recovery](docs/PROFILE_INDEX_RECOVERY.md).

For custom rules, route explanations, and one-click troubleshooting, see [Routing tools](docs/ROUTING_TOOLS.md).

Installed DNS hooks use a trusted working directory and a whitespace-free command, fixing engine startup failures caused by spaces in the application installation path.

OpenVPN startup uses the configured connection deadline, including cold launches. Early engine exits report a bounded, redacted failure category and exit status instead of a generic management-socket timeout. See [Startup diagnostics](docs/OPENVPN_STARTUP.md).

## Smart connection and live traffic

Opt-in automatic connection can run at application launch, wake, or network recovery. Choose the last successful or a fixed profile, restrict eligible networks, and pause at any time. Manual disconnects and connection failures pause automatic connection. Local status notifications can report failures only or all changes. Both features are off by default. See [Smart connection and status notifications](docs/SMART_CONNECTION.md).

The home screen shows the last 60 seconds of actual tunnel download/upload traffic, current rates, and cumulative transfer totals. The connection card shows observed connected duration, verified actual routing, IPv4/dual-stack status, and PF protection. The protection toggle is editable only while idle with no pending recovery and applies to the next managed connection. Recovery and one-click troubleshooting are available from the home screen. Graphs do not bridge interruptions or invent samples; stale samples are not displayed as live rates. PF status does not establish that DNS leak acceptance has passed.

Choosing **Quit** or pressing **Cmd-Q** disconnects the VPN, verifies network recovery, and then stops the helper process and current scheduled rule-update job. Installation approval and preferences remain available for the next launch. Closing the window keeps the application in the menu bar. Full removal still uses the uninstall entry under **Upgrade & Uninstall Preparation**.

## Build and install

Requires macOS 13+ and Swift 5.9+:

```sh
swift test
zsh scripts/build-app.sh
```

Builds without `OPENVPN_BIN` are UI-only. For local VPN connections, use a [local-test installer](docs/LOCAL_TEST_INSTALLATION.md), which verifies pinned code identity approved by an administrator. Production distribution uses a Developer ID-signed installer. Both channels require protected application components and a background helper. End users do not need Homebrew.

### Download Intel or Apple Silicon installers

1. Open [Build macOS installers (Intel + Apple Silicon)](https://github.com/javafancn/vpn-navigator/actions/workflows/package-installers.yml).
2. Select **Run workflow → main** and wait for both architecture jobs to succeed.
3. Download the matching artifact from the run summary or **Artifacts** section:

| Mac | Artifact name |
| --- | --- |
| Apple Silicon (M-series) | `VPN-Navigator-<version>-Apple-Silicon-arm64-Local-Test` |
| Intel | `VPN-Navigator-<version>-Intel-x86_64-Local-Test` |

Each artifact includes the complete engine and application installer, uninstaller, SHA-256 checksums, and installation instructions. Relevant application/build changes on `main` trigger packaging automatically. Artifacts are retained for 30 days; rerun the workflow if they expire. This workflow uses the local-test channel and requires no paid signing certificate. Builds are ad-hoc signed and not notarized; the production notarization workflow is separate.

Before updating an installed connection-capable build, complete **Upgrade & Uninstall Preparation** in the existing app. When upgrading from 0.8.3 or earlier, close the maintenance sheet after preparation succeeds, explicitly quit the old app, and then open the new installer. Normal Quit preserves installation approval and does not replace full uninstall preparation. See [Local installation, updates, and removal](docs/LOCAL_TEST_INSTALLATION.md) for the full procedure.

For source-built engines and signed distribution, see [Installation and release](docs/INSTALL_AND_RELEASE.md) and [Manual signing workflow](docs/SIGNED_RELEASE_WORKFLOW.md).

## Security scope

Disconnect protection is an explicitly enabled experimental feature for IPv4/IPv6 endpoints and Global/China Direct modes. It integrates an independent anchor into compatible system PF layouts. Enabling, rebuilding, tightening, or removing protection resets existing network connections, including other VPNs. Unknown PF layouts are rejected. Full physical-network leak acceptance remains incomplete; static rules and loopback tests cannot establish zero leakage.

Managed single-stack sessions must also meet protection requirements for the address family not carried by the tunnel; see the dual-stack documentation. In-session CRV1 reauthentication, SAML/browser authentication, TAP, arbitrary scripts/plugins, and hardware PKCS11 are outside the current support scope. Unsupported profiles or authentication must fail explicitly.

Recovery handles only DNS, routes, and PF resources whose ownership by this app can be confirmed. Live or reused orphan PIDs are not blindly terminated, and ambiguous transactions are not deleted by guesswork.

## Validation and release gates

Automation includes core tests, macOS 14/15/26 and Intel builds, dual-architecture UI packages, loopback probes, synthetic-service DNS restoration, PF syntax checks, actual PF blocking/unblocking of one loopback port, and source-engine/minimum-OS checks. Installed-system checks also exercise real application Quit, helper shutdown, retained approval/registration, and subsequent on-demand startup. Pass/fail status is determined by the Actions results for the specific commit.

Further acceptance on user Macs and actual servers must record privileged-helper authorization, real TLS/MFA, domestic/international egress and DNS captures, IPv6, network switching, sleep/wake, daemon crashes, long-running sessions, and installation/update/removal. See the [Full QA checklist](docs/QA.md), [Product readiness record](docs/PRODUCT_READINESS_2026_10_17.md), and [Authentication and maintenance completion](docs/AUTH_AND_MAINTENANCE_2026_10_18.md).

## Data and licenses

Profiles may contain private keys and are stored in private local directories by default. Do not commit real `.ovpn` profiles, passwords, private keys, or signing certificates.

The initial regional rules come from [misakaio/chnroutes2](https://github.com/misakaio/chnroutes2). Their CC BY-SA 2.0 attribution, source, and snapshot blob SHA are retained; see [Regional rule provenance](Resources/Rules/README.md). Source-build/signing workflows collect the original OpenVPN/OpenSSL licenses and corresponding source archives for distribution with the application. Review the actual dependencies and notices before distributing.
