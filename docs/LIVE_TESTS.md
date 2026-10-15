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
