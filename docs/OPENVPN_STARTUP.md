# OpenVPN startup and control-channel diagnostics

0.8.10 / Build 30 removes the independent five-second control-channel cutoff.
Cold startup, management attachment and TLS/authentication share the configured
monotonic connection deadline. Cancellation is checked every 50 ms while waiting
for the root-authenticated Unix peer. Root peer checks, private socket permissions
and descriptor ownership are unchanged. Listener/initialization errors propagate
immediately rather than being swallowed and reclassified as a timeout.

The helper drains startup output independently of its serial session queue. When
the child exits before attaching, it reports a predefined failure category plus
the exit status, after a bounded wait for the last pipe bytes. Partial lines are
bounded to 8 KB; overlong/invalid lines are discarded, and source text is never
persisted or included in the error. Configuration, certificate/key and existing
TLS/transport/cipher categories remain distinct. This does not relax certificate,
TLS, configuration validation or network recovery ownership checks.

Native CI covers a child attaching after 6.2 seconds (the previous five-second
loop would fail), cancellation, deadline expiry, options/certificate/unknown
early exits including unterminated output, and immediate listener failure. These
use the production waiter with real root-owned child processes and Unix sockets.
The DEBUG-only fixture entry is absent from shipped release helpers.

Installed integration also imports synthetic profiles through the real app and
launches bundled OpenVPN with an invalid TLS-version value in Original, Full VPN
and China Direct. Each must produce a classified error, preserve no child/socket/
route marker and need no network recovery. Each is followed by the existing real
TLS/utun, system DNS, IPv4 HTTP, mode switching and actual Quit acceptance.

A management-channel error alone does not identify the user's original engine
failure. CI isolates the startup behaviors and validates synthetic servers; it
does not claim access to private VPN servers or real user credentials.
