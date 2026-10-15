# VPN Navigator — Native macOS workspace UI

## Scope and visual language

The application uses a five-destination native macOS workspace:
**Connection Overview / Profiles / Routing & Rules / Diagnostics / Settings**.
The left sidebar uses a platform material with native selection, and content
areas use system material cards with subtle borders and restrained system-blue
accents. Dynamic colors follow light/dark mode. System materials are supported
on macOS 13+, without pretending to use macOS 26-only Liquid Glass APIs.

## Functional mapping

- **Overview**: active/selected profile, start/stop, profile switching
  confirmation, username/Keychain preferences, connected state, cumulative
  inbound/outbound bytes, cached China IPv4 route count.
- **Profiles**: local search, favorites/groups, metadata, source revision
  editing/history/recovery, export preview and deletion. Import is in toolbar.
- **Routing**: Original, Full VPN and China Direct, China IPv4 feed update,
  snapshot rollback, inactive APNIC IPv6 allocation preview.
- **Diagnostics**: IPv4 route observations and expected paths, physical
  interface, IPv6 default route safety and DNS resolver counts.
- **Settings**: privileged helper/agent, orphan-route recovery, verified
  app update and release notes; native Settings uses the same pane.
- The original menu-bar connection/traffic controls are retained.

## Explicit non-features

No synthetic latency/speed, per-app split rules, active PF kill switch,
IPv6 geographic routing or simulated connection success. The unsigned
development ZIP has no working privileged helper or OpenVPN binary.

## Acceptance

CI should run Swift build/tests and unsigned universal ad-hoc app packaging.
Manual UI acceptance on real Mac: light/dark, window resizing, keyboard
navigation, profile import/history and empty states. Actual VPN behavior
requires signed hardware testing.

## Second pass — reference fidelity

The window now uses a genuinely transparent NSWindow and an AppKit
NSVisualEffectView in behind-window blending mode, rather than tinting an
opaque NavigationSplitView. Five compact workspaces share blue selected
navigation, thin glass cards, soft highlights, native macOS typography and a
real-glass background that responds to the user's wallpaper. The dashboard
has a luminous connection control, fast profile selection and real counters.
Profiles are split into a search list and an editable glass detail pane.
Routing adopts side-by-side mode/data panels; diagnostics use side-by-side
route/health panes without inventing network measurements. On macOS 13,
these are native vibrancy materials, not macOS 26 Liquid Glass-only APIs.

## Menu bar

The system menu-bar control is now a native SwiftUI window-style popover
with live helper status, active profile, cumulative traffic (no fabricated
throughput), connect/disconnect, safe IPv4 refresh and main-window access.
It uses the same compact glass card language.
