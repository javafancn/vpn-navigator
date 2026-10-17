# VPN Navigator 0.1.0 — UI-only developer test

This CI artifact is a macOS 13+ universal (Apple Silicon + Intel) **UI-only**
developer build. The ZIP is produced by macOS `ditto`, preserving the app
bundle and executable permissions. All nested tools and the outer app are
**ad-hoc signed** for local integrity checks, **not Developer ID signed**
and **not Apple notarized**.

It has **no bundled OpenVPN CLI**, so connection, helper installation,
routing, DNS hooks and leak protection cannot be tested with this archive.

## Installation on a test Mac

1. Download the artifact **from the GitHub Actions run of this repository**.
2. Extract the inner `VPN-Navigator-0.1.0-macOS-Universal-UI-Test.zip`
   and copy `VPN Navigator.app` to `/Applications`.
3. Verify the inner ZIP against the adjacent `.sha256` file before trusting
   its contents (`shasum -a 256 -c ...sha256` from the same directory).
4. Try opening the app normally or via Finder's Open context menu.

macOS Gatekeeper may display "is damaged and can't be opened" solely
because a downloaded **non-notarized** app is quarantined. If you
deliberately trust this exact repository CI build and its matching digest,
you can opt into a *per-app-only* quarantine removal for local UI testing:

```sh
xattr -dr com.apple.quarantine "/Applications/VPN Navigator.app"
open "/Applications/VPN Navigator.app"
```

This weakens Gatekeeper checks **only for this development app**, not
the entire Mac. Never run this for unknown downloads or for an app whose
checksum is wrong. To restore the normal distribution experience, a
Developer ID signed and notarized app is required.

**This package is not a VPN client suitable for real traffic or security testing.**
