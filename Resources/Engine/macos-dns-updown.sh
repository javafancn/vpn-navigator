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

# Legacy DHCP options are data, never shell input. Modern --dns hooks run
# first in OpenVPN 2.7; keep them authoritative when both forms are present.
if [[ "${script_type:-}" == "up" || "${script_type:-}" == "down" ]]; then
    [[ "${dev:-}" =~ ^(utun|tun)[0-9]{1,4}$ ]] || exit 1
    VPNNAV_DNS_SOURCE=legacy
    if [[ "$script_type" == "down" && "${VPNNAV_JOURNALED_DNS:-0}" == "1" && "${1:-}" != "--check-dns-vars" ]]; then
        "${BASH_SOURCE[0]%/*}/VPNNavigatorHelper" --deactivate-dns "$dev" legacy || exit 1
        exit 0
    fi
    if [[ "$script_type" == "up" && "${1:-}" != "--check-dns-vars" ]]; then
        if "${BASH_SOURCE[0]%/*}/VPNNavigatorHelper" --legacy-dns-needed "$dev"; then :
        else
            result=$?
            [[ "$result" == "3" ]] && exit 0
            exit 1
        fi
    fi
    dns_index=0
    domain_index=0
    legacy_count=0
    while IFS= read -r legacy_key; do
        [[ "$legacy_key" =~ ^foreign_option_[0-9]+$ ]] || continue
        (( ++legacy_count <= 128 )) || exit 1
        read -r legacy_option legacy_kind legacy_value legacy_extra <<< "${!legacy_key}"
        [[ "$legacy_option" == "dhcp-option" ]] || continue
        case "$legacy_kind" in
            DNS|DNS6)
                [[ -z "$legacy_extra" && ${#legacy_value} -le 64 && "$legacy_value" =~ ^[0-9A-Fa-f:.]+$ ]] || exit 1
                (( ++dns_index <= 16 )) || exit 1
                printf -v "dns_server_1_address_${dns_index}" '%s' "$legacy_value"
                ;;
            DOMAIN|DOMAIN-SEARCH)
                [[ -z "$legacy_extra" && ${#legacy_value} -le 253 && "$legacy_value" =~ ^[A-Za-z0-9_.-]+$ ]] || exit 1
                (( ++domain_index <= 32 )) || exit 1
                printf -v "dns_search_domain_${domain_index}" '%s' "$legacy_value"
                ;;
        esac
    done < <(compgen -A variable foreign_option_)
    (( dns_index > 0 )) || exit 0
    [[ "$script_type" == "up" ]] && script_type=dns-up || script_type=dns-down
fi

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

# Modern OpenVPN DNS hooks use an isolated environment, so parent environment
# variables are not a reliable context channel. Read only the pinned service
# UUID from the protected journal through the typed root helper operation.
VPNNAV_PRIMARY_SERVICE_UUID="$("${BASH_SOURCE[0]%/*}/VPNNavigatorHelper" --dns-context "$dev")" || exit 1
[[ "$VPNNAV_PRIMARY_SERVICE_UUID" =~ ^[A-Fa-f0-9]{8}-[A-Fa-f0-9]{4}-[A-Fa-f0-9]{4}-[A-Fa-f0-9]{4}-[A-Fa-f0-9]{12}$ ]] || exit 1
VPNNAV_JOURNALED_DNS=1


# Lockfiles for a root DNS modifier must never live in a shared 1777
# directory. The helper created this root-owned 0700 runtime directory
# before launching OpenVPN. Refuse to run if it is not trustworthy.
lockdir=/var/run/vpn-navigator
[[ -d "$lockdir" && ! -L "$lockdir" ]] || exit 1
lockowner=$(/usr/bin/stat -f %u "$lockdir") || exit 1
lockmode=$(/usr/bin/stat -f %Lp "$lockdir") || exit 1
[[ "$lockowner" == "$EUID" && "$lockmode" =~ ^[0-7]{3,4}$ ]] || exit 1
(( (8#$lockmode & 0077) == 0 )) || exit 1

i=1
lockfile="${lockdir}/openvpn-dns-updown.lock"
while ! /usr/bin/shlock -f $lockfile -p $$; do
    if [ $((++i)) -gt 10 ]; then
        echo "dns-updown failed, could not acquire lock"
        exit 1
    fi
    sleep 0.2
done
trap "/bin/rm -f ${lockfile}" EXIT

itf_dns_key="State:/Network/Service/openvpn-${dev}/DNS"

function primary_dns_key {
    # The helper pins the service before OpenVPN starts. A Wi-Fi switch must
    # never make a down-hook restore this tunnel's DNS onto another service.
    local uuid="${VPNNAV_PRIMARY_SERVICE_UUID:-}"
    [[ "$uuid" =~ ^[A-Fa-f0-9]{8}-[A-Fa-f0-9]{4}-[A-Fa-f0-9]{4}-[A-Fa-f0-9]{4}-[A-Fa-f0-9]{12}$ ]] || return 1
    echo "Setup:/Network/Service/${uuid}/DNS"
}

function dns_backup_key {
    local key="$(echo "list State:/Network/Service/openvpn-.*/DnsBackup" | /usr/sbin/scutil | cut -d= -f2 | xargs)"
    if [[ "${key}" =~ no\ key ]]; then
        echo "State:/Network/Service/openvpn-${dev}/DnsBackup"
    else
        echo "${key}"
    fi
}

function property_value {
    local key="$1"
    local prop="$2"

    [ -n "${key}" -a -n "${prop}" ] || return

    local match_prop="${prop} : (.*)"
    local match_array_start="${prop} : <array>"
    local match_array_elem="[0-9]* : (.*)"
    local match_array_end="}"
    local in_array=false
    local values=""

    echo "show ${key}" | /usr/sbin/scutil | while read line; do
        if [ "${in_array}" = false ] && [[ "${line}" =~ "${match_array_start}" ]]; then
            in_array=true
        elif [ "${in_array}" = true ] && [[ "${line}" =~ ${match_array_elem} ]]; then
            values+="${BASH_REMATCH[1]} "
        elif [ "${in_array}" = true ] && [[ "${line}" =~ "${match_array_end}" ]]; then
            echo "${values}"
            break
        elif [[ "${line}" =~ ${match_prop} ]]; then
            echo "${BASH_REMATCH[1]}"
            break
        fi
    done
}

function only_standard_server_ports {
    local i=1
    while :; do
        local addr_var=dns_server_${n}_address_${i}
        [ -n "${!addr_var}" ] || return 0

        local port_var=dns_server_${n}_port_${i}
        [ -z "${!port_var}" -o "${!port_var}" = "53" ] || return 1

        i=$((i+1))
    done
}

function find_compat_profile {
    local n=1
    while :; do
        local addr_var=dns_server_${n}_address_1
        [ -n "${!addr_var}" ] || {
            echo "setting DNS failed, no compatible server profile"
            exit 1
        }

        # Skip server profiles which require DNSSEC,
        # secure transport or use a custom port
        local dnssec_var=dns_server_${n}_dnssec
        local transport_var=dns_server_${n}_transport
        [ -z "${!transport_var}" -o "${!transport_var}" = "plain" ] \
            && [ -z "${!dnssec_var}" -o "${!dnssec_var}" = "no" ] \
            && only_standard_server_ports && break

        n=$((n+1))
    done
    echo $n
}

function get_search_domains {
    property_value State:/Network/Global/DNS SearchDomains
}

function get_server_addresses {
    property_value "$(primary_dns_key)" ServerAddresses
}

function set_search_domains {
    [ -n "$1" ] || return
    local dns_key=$(primary_dns_key)
    local dns_backup_key="$(dns_backup_key)"
    local search_domains="${1}$(get_search_domains)"

    local cmds=""
    cmds+="get ${dns_key}\n"
    cmds+="d.add SearchDomains * ${search_domains}\n"
    cmds+="set ${dns_key}\n"

    if ! [[ "${dns_backup_key}" =~ ${dev}/ ]]; then
        # Add the domains to the backup in case the default goes down
        local existing="$(property_value ${dns_backup_key} SearchDomains)"
        cmds+="get ${dns_backup_key}\n"
        cmds+="d.add SearchDomains * ${search_domains} ${existing}\n"
        cmds+="set ${dns_backup_key}\n"
    fi

    echo -e "${cmds}" | /usr/sbin/scutil
}

function unset_search_domains {
    [ -n "$1" ] || return
    local dns_key=$(primary_dns_key)
    local dns_backup_key="$(dns_backup_key)"
    local search_domains="$(get_search_domains)"
    search_domains=$(echo $search_domains | sed -e "s/$1//")

    local cmds=""
    cmds+="get ${dns_key}\n"
    cmds+="d.add SearchDomains * ${search_domains}\n"
    cmds+="set ${dns_key}\n"

    if ! [[ "${dns_backup_key}" =~ ${dev}/ ]]; then
        # Remove the domains from the backup for when the default goes down
        search_domains="$(property_value ${dns_backup_key} SearchDomains)"
        search_domains=$(echo $search_domains | sed -e "s/$1//")
        cmds+="get ${dns_backup_key}\n"
        cmds+="d.add SearchDomains * ${search_domains}\n"
        cmds+="set ${dns_backup_key}\n"
    fi

    echo -e "${cmds}" | /usr/sbin/scutil
}

function addresses_string {
    local n=$1
    local i=1
    local addresses=""
    while :; do
        local addr_var=dns_server_${n}_address_${i}
        local addr="${!addr_var}"
        [ -n "$addr" ] || break
        addresses+="${addr} "
        i=$((i+1))
    done
    echo "$addresses"
}

function search_domains_string {
    local n=$1
    local i=1
    local search_domains=""
    while :; do
        domain_var=dns_search_domain_${i}
        [ -n "${!domain_var}" ] || break
        # Add as search domain, if it doesn't already exist
        [[ "$search_domains" =~ (^| )${!domain_var}( |$) ]] \
            || search_domains+="${!domain_var} "
        i=$((i+1))
    done
    echo "$search_domains"
}

function match_domains_string {
    local n=$1
    local i=1
    local match_domains=""
    while :; do
        domain_var=dns_server_${n}_resolve_domain_${i}
        [ -n "${!domain_var}" ] || break
        # Add as match domain, if it doesn't already exist
        [[ "$match_domains" =~ (^| )${!domain_var}( |$) ]] \
            || match_domains+="${!domain_var} "
        i=$((i+1))
    done
    echo "$match_domains"
}

function set_dns {
    primary_dns_key >/dev/null || { echo "missing pinned DNS service" >&2; exit 1; }
    local n="$(find_compat_profile)"
    local addresses="$(addresses_string $n)"
    local search_domains="$(search_domains_string $n)"
    local match_domains="$(match_domains_string $n)"

    if [ -n "$match_domains" ]; then
        local cmds=""
        cmds+="d.init\n"
        cmds+="d.add ServerAddresses * ${addresses}\n"
        cmds+="d.add SupplementalMatchDomains * ${match_domains}\n"
        cmds+="d.add SupplementalMatchDomainsNoSearch # 1\n"
        cmds+="add ${itf_dns_key}\n"
        echo -e "${cmds}" | /usr/sbin/scutil
        set_search_domains "$search_domains"
    else
        local dns_backup_key="$(dns_backup_key)"
        [[ "${dns_backup_key}" =~ ${dev}/ ]] || {
            echo "setting DNS failed, already redirecting to another tunnel"
            exit 1
        }

        local cmds=""
        cmds+="get $(primary_dns_key)\n"
        cmds+="set ${dns_backup_key}\n"
        cmds+="d.init\n"
        cmds+="d.add ServerAddresses * ${addresses}\n"
        cmds+="d.add SearchDomains * ${search_domains}\n"
        cmds+="d.add SearchOrder # 5000\n"
        cmds+="set $(primary_dns_key)\n"
        echo -e "${cmds}" | /usr/sbin/scutil
    fi

    /usr/bin/dscacheutil -flushcache
}

function unset_dns {
    primary_dns_key >/dev/null || { echo "missing pinned DNS service" >&2; exit 1; }
    local n="$(find_compat_profile)"
    local match_domains="$(match_domains_string $n)"

    if [ -n "$match_domains" ]; then
        local search_domains="$(search_domains_string $n)"
        echo "remove ${itf_dns_key}" | /usr/sbin/scutil
        unset_search_domains "$search_domains"
    else
        # Do not unset if this tunnel did not set/backup DNS before
        local dns_backup_key="$(dns_backup_key)"
        [[ "${dns_backup_key}" =~ ${dev}/ ]] || return

        local cmds=""
        local servers="$(get_server_addresses)"
        local addresses="$(addresses_string $n)"
        # Only restore backup if the server addresses match
        if [ "${servers}" = "${addresses}" ]; then
            cmds+="get ${dns_backup_key}\n"
            cmds+="set $(primary_dns_key)\n"
        else
            echo "not restoring global DNS configuration, server addresses have changed"
        fi
        cmds+="remove ${dns_backup_key}\n"
        echo -e "${cmds}" | /usr/sbin/scutil
    fi

    /usr/bin/dscacheutil -flushcache
}

if [ "$script_type" = "dns-up" ]; then
    set_dns
    # Record precisely the DNS values this trusted hook just applied. If the
    # helper crashed before CONNECTED, ownership is still available for recovery.
    "${BASH_SOURCE[0]%/*}/VPNNavigatorHelper" --commit-dns "$dev" "${VPNNAV_DNS_SOURCE:-modern}" || exit 1
else
    # The application journal restores exact DNS values after child exit in
    # every mode. Legacy/modern down-hooks must not partially restore them.
    if [[ "${VPNNAV_JOURNALED_DNS:-0}" == "1" ]]; then
        "${BASH_SOURCE[0]%/*}/VPNNavigatorHelper" --deactivate-dns "$dev" "${VPNNAV_DNS_SOURCE:-modern}" || exit 1
        exit 0
    fi
    unset_dns
fi

