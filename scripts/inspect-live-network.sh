#!/bin/zsh
set -euo pipefail
[[ "$OSTYPE" == darwin* ]] || { echo "macOS required"; exit 2; }
for address in "${CN_TEST_IP:-223.5.5.5}" "${FOREIGN_TEST_IP:-8.8.8.8}"; do
  echo "== IPv4 route to $address =="
  /sbin/route -n get "$address" | /usr/bin/grep -E 'route to:|destination:|mask:|gateway:|interface:' || true
done
echo "== Physical default route =="
/sbin/route -n get default | /usr/bin/grep -E 'gateway:|interface:' || true
echo "== IPv6 route =="
/sbin/route -n get -inet6 2606:4700:4700::1111 | /usr/bin/grep -E 'gateway:|interface:' || true
echo "== Local DNS resolver summary =="
/usr/sbin/scutil --dns | /usr/bin/grep -E '^resolver|nameserver|if_index|flags' | /usr/bin/head -n 80 || true
echo "Read-only diagnostics complete. Avoid sharing private DNS output."
