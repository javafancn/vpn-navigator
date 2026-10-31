# Real application managed-connection acceptance

Build 29 extends the installed macOS matrix (14, 15, Intel 15, 26) beyond the
original-mode TLS fixture. All material operations use the shipped application,
authenticated production XPC, bundled OpenVPN, actual utun interfaces, and real
kernel routing commands. There is no mocked route command or trusted-path
override in the managed connection test.

## Required scenarios

- TCP and UDP, each with Original, Full VPN and China Direct: six combinations.
- An additional UDP China Direct connection with no server DNS push.
- An additional UDP China Direct connection using modern `dns server` pushes,
  in addition to traditional `dhcp-option DNS` coverage.
- Bootstrap the bundled rules through normal application loading, and connect
  with the default 60-second connection timeout (no extended test preference).
- Import an inline-certificate profile into an isolated profile library, persist
  custom exceptions and mode, then invoke the application's normal Connect action.
- ECDSA server certificate, TLS 1.2, AES-128-GCM, SHA256 and the optional Windows
  DNS compatibility directives used by common OpenVPN exports.
- Install 4,096 non-adjacent direct prefixes in China Direct, exceeding the
  previously reported failure point; inspect the actual durable journal.
- Query real default/VPN and direct-route destinations; remain connected across
  the five-second network watchdog rather than accepting a transient receipt.
- Switch Full VPN to China Direct and back in the same TLS session.
- Exchange scoped UDP payloads in both encrypted directions; verify real byte
  counters increase. Scope avoids same-host LOCAL/lo0 shortcuts without replacing
  local host routes.
- In managed modes, resolve a unique `.vpnnav.test` name through the macOS system resolver and
  fetch an 8 KB IPv4 HTTP response using ordinary curl (no resolver override).
  The provided resolver lies inside a direct country prefix; its exact route
  must still select the client utun. The no-DNS case must use the managed VPN
  fallback and load the same page. Actual encrypted counters must increase.
- Record application connection time before watchdog sleeps, mode switches and
  Quit cleanup, for each transport/mode. Large IPv4 gateway plans use the native
  Darwin routing socket; every mutation retains its fsynced begin/commit pair.
- Compare both IPv4 backends on the same 512 actual benchmarking routes with
  identical per-mutation fsync, verify exact kernel ownership, and roll back all
  prefixes. Report the installation timings without weakening durability.
- Request real application Quit; observe complete route/DNS cleanup, disappearance
  of the helper PID, preserved installation approval and on-demand relaunch.

## Performance regression gates (0.8.13 / Build 33)

Successful connection alone is insufficient. The same four installed-system
runners must also meet these deterministic local acceptance budgets:

- Initial application connection: Original and Full VPN below 5 seconds; China
  Direct with 4,096 real non-adjacent routes below 12 seconds. These timings
  exclude deliberate watchdog waits, live switches and Quit cleanup.
- Each managed connection resolves three fresh random names using ordinary
  system DNS and fetches HTTP through the real encrypted IPv4 path. Every first
  attempt must succeed; retries can no longer turn a slow failure into a pass.
  Name lookup must be below 2 seconds, curl total below 3 seconds, and process
  wall time below 4 seconds. Log name lookup, connect, first byte and total time
  independently, including preflight time outside the HTTP measurement.
- Each of the six TCP/UDP and mode combinations transfers three 8 MiB downloads
  and three 8 MiB uploads. A scoped TCP stream crosses both actual utun interfaces
  and the real encrypted OpenVPN transport; SHA-256 verifies every complete
  payload and management counters must account for at least 24 MiB each way.
- The median in each direction must exceed 16 Mbit/s on the isolated runner.
  Full VPN and China Direct must retain at least 50% of Original's median on
  the same runner and transport. This is a coarse CI regression bound, not
  acceptable proof of a 49% user-visible slowdown; sample values remain logged
  for review. No physical public-network throughput is inferred from loopback.
- The production DNS relay separately runs real UDP/TCP queries against healthy,
  blackholed and delayed primary resolvers. A healthy primary gets no duplicate
  backup query; a stalled primary's healthy same-group backup must answer in
  under 1.5 seconds, while all-failed domestic queries wait for that group to
  exhaust before VPN fallback. Foreign names must never reach domestic DNS.

The bulk stream verifies engine/mode overhead and data integrity. The IPv4
HTTP test verifies route-selected addressing and native DNS. Neither substitutes
for the other; neither measures a user's real VPN server or ISP. Their fixtures
and all certificates are synthetic and remain confined to disposable runners.

## Isolation and limitations

Only disposable GitHub macOS runners may execute these fixtures. A private PF
anchor sends the reserved documentation endpoint and temporary transport port
to a local synthetic TLS server; main PF rules and unrelated anchors remain
unchanged. The application still observes the physical route for that endpoint.
The fixture restores only its own PF enable reference and rules.

For IPv4 DNS/HTTP, the synthetic server pushes standard client-nat/iroute to a
non-local client alias. A server-utun-only PF redirect reaches disposable local
responders; return packets must re-enter server utun and the encrypted data path.
The client destination is never a local alias, avoiding Darwin's LOCAL/lo0
shortcut. Only the server's upstream relay binds to the physical interface to
retain CI controller DNS. Product route selection is unchanged. This is isolated
server-side forwarding, not proof of arbitrary public Internet availability.

The managed modes install real /1 routes. Explicit ordinary custom-direct rules
retain access to the CI controller's current network peers. No production
validation is bypassed. All test prefixes, certificates and identities are
synthetic; user configuration, credentials and private server information are
never uploaded to public CI.

This combination fixture uses protection off. Existing independent PF syntax,
activation and packet-blocking tests remain mandatory; this fixture does not
claim combined protection-on transport coverage. It proves native connection,
route application and cleanup on the isolated host, rather than the availability
of an arbitrary external VPN service, enterprise MFA, external DNS or physical
public-internet forwarding. Workflow results identify the exact tested commit.
