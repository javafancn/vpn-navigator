#!/bin/bash
#
# dns-updown - add/remove openvpn provided DNS information
#
# Copyright (C) 2025-2026 OpenVPN Inc <sales@openvpn.net>
#
# SPDX-License-Identifier: BSD-2-Clause
#
# Example env from openvpn (most are not applied):
#
#   dns_vars_file /tmp/openvpn_dvf_58b95c0c97b2db43afb5d745f986c53c.tmp
#
#      or
#
#   dev utun0
#   script_type dns-up
#   dns_search_domain_1 mycorp.in
#   dns_search_domain_2 eu.mycorp.com
#   dns_server_1_address_1 192.168.99.254
#   dns_server_1_address_2 fd00::99:53
#   dns_server_1_port_2 53
#   dns_server_1_resolve_domain_1 mycorp.in
#   dns_server_1_resolve_domain_2 eu.mycorp.com
#   dns_server_1_dnssec yes
#   dns_server_1_transport DoH
#   dns_server_1_sni dns.mycorp.in
#

# OpenVPN 2.7 writes DNS hook variables as plain NAME=value lines.
# NEVER source that file: DNS names can originate from a VPN server, and
# evaluating them as shell commands in a root hook is unacceptable.
load_dns_vars_file() {
    local path="${dns_vars_file:-}"
    [ -n "$path" ] || return 0
    [[ -f "$path" && ! -L "$path" ]] || return 1
    local size owner mode
    size=$(/usr/bin/stat -f %z "$path") || return 1
    owner=$(/usr/bin/stat -f %u "$path") || return 1
    mode=$(/usr/bin/stat -f %Lp "$path") || return 1
    [[ "$size" =~ ^[0-9]+$ && "$size" -le 65536 ]] || return 1
    [[ "$owner" == "$EUID" ]] || return 1
    [[ "$mode" =~ ^[0-7]{3,4}$ ]] || return 1
    (( (8#$mode & 0022) == 0 )) || return 1
    local row key value
    while IFS= read -r row || [[ -n "$row" ]]; do
        [[ -n "$row" ]] || continue
        [[ "$row" =~ ^([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]] || return 1
        key="${BASH_REMATCH[1]}"
        value="${BASH_REMATCH[2]}"
        case "$key" in
            dev|script_type|dns_search_domain_*|dns_server_*) ;;
            *) continue ;;
        esac
        # The DNS/scutil hook accepts only simple DNS/address/port tokens,
        # never whitespace, quotes, substitutions, shell metacharacters or
        # scutil command delimiters.
        [[ ${#value} -le 253 && "$value" =~ ^[A-Za-z0-9_.:/%+-]+$ ]] || return 1
        printf -v "$key" '%s' "$value"
    done < "$path"
}
load_dns_vars_file || { echo "invalid OpenVPN DNS variables" >&2; exit 1; }
# OpenVPN can alternatively supply DNS options as inherited environment
# variables. Validate this path too; data must never become scutil commands.
validate_dns_values() {
    local key value
    while IFS= read -r key; do
        case "$key" in
            dns_search_domain_*|dns_server_*)
                value="${!key}"
                [[ ${#value} -le 253 && "$value" =~ ^[A-Za-z0-9_.:/%+-]+$ ]] || return 1
                ;;
        esac
    done < <(compgen -A variable dns_)
}
validate_dns_values || { echo "invalid OpenVPN DNS value" >&2; exit 1; }
[[ "${dev:-}" =~ ^(utun|tun)[0-9]{1,4}$ ]] || {
    echo "invalid OpenVPN DNS device" >&2; exit 1;
}
[[ "${script_type:-}" == "dns-up" || "${script_type:-}" == "dns-down" ]] || {
    echo "invalid OpenVPN DNS hook phase" >&2; exit 1;
}
# Validation-only entry point: CI can exercise the hostile-input parser
# without applying DNS settings or obtaining root privileges.
if [[ "${1:-}" == "--check-dns-vars" ]]; then
    exit 0
fi

# A down-hook does not compete with the helper's compare-before-restore journal.
# OpenVPN may supply an isolated environment: all service context is read from
# the protected journal by the native operation, never inherited shell state.
[[ "$script_type" == "dns-down" ]] && exit 0

runtime=/var/run/vpn-navigator
[[ -d "$runtime" && ! -L "$runtime" ]] || exit 1
owner=$(/usr/bin/stat -f %u "$runtime") || exit 1
mode=$(/usr/bin/stat -f %Lp "$runtime") || exit 1
[[ "$owner" == "$EUID" && "$mode" =~ ^[0-7]{3,4}$ ]] || exit 1
(( (8#$mode & 0077) == 0 )) || exit 1

standard_ports() {
    local profile="$1" i=1 address port
    while (( i <= 16 )); do
        address="dns_server_${profile}_address_${i}"
        [[ -n "${!address}" ]] || return 0
        port="dns_server_${profile}_port_${i}"
        [[ -z "${!port}" || "${!port}" == "53" ]] || return 1
        i=$((i+1))
    done
}
profile=1
while (( profile <= 16 )); do
    address="dns_server_${profile}_address_1"
    [[ -n "${!address}" ]] || { echo "DNS application failed: no compatible resolver" >&2; exit 1; }
    transport="dns_server_${profile}_transport"
    dnssec="dns_server_${profile}_dnssec"
    if [[ -z "${!transport}" || "${!transport}" == "plain" ]] &&
       [[ -z "${!dnssec}" || "${!dnssec}" == "no" ]] && standard_ports "$profile"; then break; fi
    profile=$((profile+1))
done
(( profile <= 16 )) || exit 1
addresses=""
search=""
match=""
for ((i=1; i<=16; i++)); do
    key="dns_server_${profile}_address_${i}"
    [[ -n "${!key}" ]] || break
    addresses+="${!key} "
done
for ((i=1; i<=32; i++)); do
    key="dns_search_domain_${i}"
    [[ -n "${!key}" ]] || break
    search+="${!key} "
done
for ((i=1; i<=32; i++)); do
    key="dns_server_${profile}_resolve_domain_${i}"
    [[ -n "${!key}" ]] || break
    match+="${!key} "
done
if [[ -f "$runtime/ci-managed-trace" ]]; then echo "VPNNAV DNS adapter phase=$script_type profile=$profile"; fi
"${BASH_SOURCE[0]%/*}/VPNNavigatorHelper" --apply-dns "$dev" "$addresses" "$search" "$match" || exit 1
/usr/bin/dscacheutil -flushcache
