#!/bin/zsh
# Read-only hardware acceptance test. Runs against an already connected,
# authorized VPN Navigator session. Does not print private DNS domains.
set -euo pipefail
[[ "$OSTYPE" == darwin* ]] || { echo "macOS is required" >&2; exit 2; }
CN_IP="${CN_TEST_IP:-223.5.5.5}"
WORLD_IP="${WORLD_TEST_IP:-8.8.8.8}"

route_value() {
  local target="$1" field="$2"
  /sbin/route -n get "$target" |
    /usr/bin/awk -v search="$field:" '$1 == search { print $2; exit }'
}
PHYSICAL_IF="$(route_value default interface)"
CN_IF="$(route_value "$CN_IP" interface)"
WORLD_IF="$(route_value "$WORLD_IP" interface)"
CN_GATEWAY="$(route_value "$CN_IP" gateway)"
DEFAULT_GATEWAY="$(route_value default gateway)"

[[ "$PHYSICAL_IF" == en<-> ]] || {
  echo "INCONCLUSIVE: default network interface is not a known en* physical interface" >&2
  exit 3
}
[[ "$CN_IF" == "$PHYSICAL_IF" && -n "$CN_GATEWAY" &&
   "$CN_GATEWAY" == "$DEFAULT_GATEWAY" ]] || {
  echo "FAIL: CN destination is not routed through the physical default gateway" >&2
  exit 1
}
[[ "$WORLD_IF" == utun<-> ]] || {
  echo "FAIL: foreign destination is not routed through an OpenVPN utun interface" >&2
  exit 1
}
# Current IPv4-only split mode must not claim protection while a native IPv6
# physical default is present; dynamic state changes need hardware testing.
/usr/sbin/netstat -rn -f inet6 | /usr/bin/awk '
  /^default[[:space:]]/ && $0 ~ /[[:space:]](en[0-9]+|bridge[0-9]+|pdp_ip[0-9]+)[[:space:]]/ {
    exposed=1
  }
  END { exit exposed ? 1 : 0 }
' || {
  echo "FAIL: IPv6 physical default route could bypass IPv4-only split" >&2
  exit 1
}
echo "PASS: selected CN IPv4 -> physical gateway; foreign IPv4 -> tunnel; no physical IPv6 default found."
echo "This test does not establish packet-level DNS/PF leak freedom, or verify VPN server egress identity."

