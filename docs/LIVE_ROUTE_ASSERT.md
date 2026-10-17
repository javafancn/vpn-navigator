# Hardware route acceptance script

From a **signed installed app** connected to a disposable OpenVPN test
server in Mainland China Direct mode, run:

```zsh
zsh scripts/live-route-assert.sh
CN_TEST_IP=223.5.5.5 WORLD_TEST_IP=8.8.8.8 \
  zsh scripts/live-route-assert.sh
```

It checks the current macOS routing decisions for two sample IPv4
destinations against the system physical gateway and the OpenVPN utun,
and refuses to pass if a physical IPv6 default is visible. It does **not**
modify network state or print private resolver domains.

**Important limitations:** specific destinations might have conflicting
enterprise/static routes; a two-address route test cannot prove all
country routes are correct, that packets use the intended external exit,
that DNS requests are leak-free, or that PF guard protection exists.
Complete the remaining cases in docs/QA.md on physical hardware.
