# Running live macOS acceptance checks

**Requires:** a disposable Mac, an OpenVPN test server and disposable credentials, a properly signed VPN Navigator installer, and permission from the network administrator.

After enabling the signed privileged helper and connecting a non-production profile, run the read-only diagnostics:

```sh
zsh scripts/inspect-live-network.sh
CN_TEST_IP=223.5.5.5 FOREIGN_TEST_IP=8.8.8.8 \
    zsh scripts/inspect-live-network.sh
```

Expected in China Direct: the mainland IP uses the physical `en*` interface and local gateway, while the non-China IP uses the OpenVPN `utun*` interface. Check your LAN/NAS/SMB and test both actual public egress addresses with endpoints you trust.

Also test corporate split DNS, IPv6, interruption, Wi-Fi changes, sleep/wake, helper crash recovery, and uninstall/upgrade. Explicit failures must leave the machine's own network usable or provide an actionable restoration path.

Do not upload real VPN profiles, passwords, private keys or private resolver domains to CI. This project does not claim production readiness until the checks in [QA.md](QA.md) are performed and recorded on actual hardware.

## New negative-path acceptance checks

Validate managed profile route collisions, server-pushed route behavior,
tunnel reconnecting, DNS resolver restoration, orphan PID recovery and
physical IPv6 emergence on an isolated test Mac. Root helper watchdog
polling does **not** ensure packet-level leak freedom between samples.
Runtime PF protection is implemented as a default-off experimental capability; physical packet capture and crash acceptance still gate a protection guarantee. IPv6 country routing is not in the current release scope.

