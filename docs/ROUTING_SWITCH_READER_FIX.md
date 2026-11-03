# Retained route-reader backlog during mode changes

The installed 0.8.17 session history records successful China Direct / Full VPN
round trips followed by a failed session at 2026-11-03 10:20:04 +08:00. Helper
events record recovery at 10:20:12 and a successful connection at 10:20:21.
The old switch catch recorded only teardown events, without the initiating
failure's stage or errno. Consequently the exact cause of that historical
failure cannot be established from the surviving records.

## Reproduced defect

`RouteExecutor` retains a `KernelRouteReader` between mode changes. That routing
socket receives routing notifications even while it is idle. Installing China
Direct routes can fill its receive queue. Previously `vpn_routes_inspect` sent
its next RTM_GET before draining the stale notifications. If the synchronous
reply could not fit, consuming old messages afterwards did not recover that
reply: the ownership query timed out and the switch stopped the VPN.

This delivery mechanism follows Apple's
[routing-socket implementation](https://github.com/apple-oss-distributions/xnu/blob/main/bsd/net/rtsock.c):
normal route replies pass through `raw_input`. It is a plausible explanation
for the reported incident, rather than proof that no other failure occurred.

The reader now drains queued datagrams nonblockingly **before** sending a fresh
query. Draining and waiting share the original one-second monotonic deadline;
the reader still matches reply pid, sequence and type and validates exact
ownership before any deletion. No route mutation is retried or ownership check
weakened.

## Failure evidence

Switch failures now retain the `.route` category, a fixed stage name, and the
numeric kernel errno when available. These events survive explicit recovery
and subsequent reconnects. No address, profile, credential or raw error text is
added to the event log. Old events remain decodable; deduplication distinguishes
different stages and error numbers.

## Validation

- The new isolated datagram fixture fills the receive queue and synchronously
  attempts reply delivery during the production query's write. With the old
  reader it deterministically fails with errno 60 (ETIMEDOUT). With the fix,
  all five full-queue trials pass. The fixture changes no system routes.
- Existing native message/decoder tests still cover IPv4/IPv6 ownership,
  malformed replies, absent routes, sequence filtering and kernel errors.
- The helper's injected route suite checks both switching directions, PF stage
  ordering, durable failure metadata and legacy event compatibility.
- Python regression suite: 35 tests passed. Helper Debug and Release builds
  passed. The updated native reader also completed a real read-only query and
  matched `route -n get -net` for the same prefix.

These checks do not replace repeated mode changes using the updated installed
application. The user's running installation and active VPN were not replaced
or switched during this investigation.
