#!/bin/bash
# Native Ubuntu/systemd Snell v5/v6 public IPv4 profiles.
# Interface binding selects the route; a private service UID and narrowly
# scoped SNAT select the address when an interface has more than one IPv4.

SNELL_IP_CONF=/etc/snell
SNELL_IP_STATE=/etc/snell-ip-bindings
SNELL_IP_UNITS=/etc/systemd/system
SNELL_IP_BIN=/usr/local/bin
SNELL_IP_HELPER=/usr/local/lib/snell/ip-binding.sh
SNELL_IP_LOCK=/run/lock/snell-ip.lock

sip_error() { printf 'Error: %s\n' "$*" >&2; return 1; }
sip_id_valid() { [[ $1 == main || ( $1 =~ ^[1-9][0-9]{0,4}$ && $1 -le 65535 ) ]]; }
sip_service() { [[ $1 == main ]] && printf snell || printf 'snell-%s' "$1"; }
sip_conf() {
    if [[ $1 == main && ! -f $SNELL_IP_CONF/users/snell-main.conf ]]; then
        printf '%s/snell-server.conf\n' "$SNELL_IP_CONF"
    else
        printf '%s/users/snell-%s.conf\n' "$SNELL_IP_CONF" "$1"
    fi
}
sip_get() {
    awk -v key="$2" '
      {line=$0; sub(/^[ \t]+/, "", line); at=index(line,"=");
       if (!at) next; name=substr(line,1,at-1); sub(/[ \t]+$/, "", name);
       if (name==key) {value=substr(line,at+1); sub(/^[ \t]+/, "", value);
         sub(/[ \t\r]+$/, "", value); print value; exit}}
    ' "$1"
}
sip_ips() {
    local data
    data=$(ip -j -4 address show up) || return 1
    jq -r '
      def public:
        split(".") | map(tonumber) as $o |
        ($o|length)==4 and $o[0]>0 and $o[0]<224 and $o[0]!=10 and $o[0]!=127 and
        ([$o[0],$o[1]] != [169,254]) and ([$o[0],$o[1]] != [192,168]) and
        ([$o[0],$o[1],$o[2]] != [192,0,0]) and
        ([$o[0],$o[1],$o[2]] != [192,0,2]) and
        ([$o[0],$o[1],$o[2]] != [192,88,99]) and
        ([$o[0],$o[1],$o[2]] != [198,51,100]) and
        ([$o[0],$o[1],$o[2]] != [203,0,113]) and
        (($o[0]==100 and $o[1]>=64 and $o[1]<=127)|not) and
        (($o[0]==172 and $o[1]>=16 and $o[1]<=31)|not) and
        (($o[0]==198 and ($o[1]==18 or $o[1]==19))|not);
      [.[] | .ifname as $if | .addr_info[]? |
       select(.family=="inet" and .scope=="global" and (.local|public)) |
       [.local,$if]] | unique[] | @tsv
    ' <<<"$data"
}
sip_select() {
    local requested=${1:-} data address iface choice i
    local -a addresses=() interfaces=()
    data=$(sip_ips) || { sip_error 'Public-IP discovery failed; install iproute2 and jq.'; return 1; }
    while IFS=$'\t' read -r address iface; do
        [[ $address ]] || continue
        addresses+=("$address"); interfaces+=("$iface")
    done <<<"$data"
    if [[ ! $requested || $requested == auto ]]; then
        if [[ ${#addresses[@]} == 1 ]]; then
            requested=${addresses[0]}
        elif [[ -t 0 && ${#addresses[@]} -gt 1 && $requested != auto ]]; then
            printf '选择此配置的公网 IP / 接口 (监听及出口):\n'
            for i in "${!addresses[@]}"; do
                printf '%s) %s (%s)\n' "$((i+1))" "${addresses[$i]}" "${interfaces[$i]}"
            done
            while :; do
                read -rp '选择: ' choice || return 1
                if [[ $choice =~ ^[1-9][0-9]{0,4}$ ]] && ((choice<=${#addresses[@]})); then
                    requested=${addresses[$((choice-1))]}; break
                fi
            done
        else
            sip_error 'Specify --bind-ip with one of the addresses shown by snell ips.'; return 1
        fi
    fi
    SIP_ADDRESS='' SIP_INTERFACE=''
    for i in "${!addresses[@]}"; do
        [[ ${addresses[$i]} == "$requested" ]] || continue
        [[ ! $SIP_ADDRESS ]] || { sip_error 'Address exists on multiple interfaces.'; return 1; }
        SIP_ADDRESS=${addresses[$i]}; SIP_INTERFACE=${interfaces[$i]}
    done
    [[ $SIP_ADDRESS && $SIP_INTERFACE =~ ^[a-zA-Z0-9_.:-]{1,15}$ ]] || {
        sip_error 'Select a configured public IPv4 on an UP interface.'; return 1;
    }
}
sip_version() {
    local conf=$1 version binary output
    version=$(sip_get "$conf" '#version-choice')
    [[ $version != v4 ]] || { sip_error 'This profile uses v4; IP binding requires v5/v6.'; return 1; }
    if [[ $version != v5 && $version != v6 ]]; then
        binary=$SNELL_IP_BIN/snell-server
        output=$("$binary" --v 2>&1) || true
        case $output in *v6.*) version=v6;; *v5.*) version=v5;; *) version=unknown;; esac
    fi
    [[ $version == v5 || $version == v6 ]] || { sip_error 'IP profiles require Snell v5 or v6; no automatic protocol upgrade is performed.'; return 1; }
    printf '%s\n' "$version"
}
sip_binary() {
    local version=$1 output binary=$SNELL_IP_BIN/snell-server-$1
    if [[ ! -x $binary ]]; then binary=$SNELL_IP_BIN/snell-server; fi
    [[ -x $binary ]] || { sip_error "Install the $version channel first."; return 1; }
    output=$("$binary" --v 2>&1) || true
    [[ $output == *"$version."* ]] || { sip_error "Installed binary is not $version."; return 1; }
    printf '%s\n' "$binary"
}

# Preserve PSK, mode, obfuscation, DNS and all other sections verbatim.
sip_rewrite() {
    local conf=$1 address=$2 iface=$3 port=$4 version=$5
    awk -v ip="$address" -v iface="$iface" -v port="$port" -v version="$version" '
      function settings() {
        print "listen = " ip ":" port; print "egress-interface = " iface;
        if(version=="v6") print "dns-ip-preference = ipv4-only";
        else print "ipv6 = false";
      }
      BEGIN {print "#txehq-bind-ip = " ip; print "#txehq-bind-interface = " iface}
      /^[ \t]*#txehq-bind-(ip|interface)[ \t]*=/ {next}
      /^[ \t]*\[/ {
        if(server) settings(); server=($0 ~ /^[ \t]*\[snell-server\][ \t\r]*$/)
      }
      server && /^[ \t]*(listen|egress-interface|ipv6|dns-ip-preference)[ \t]*=/ {next}
      {print}
      END {if(server) settings()}
    ' "$conf"
}

sip_dns() {
    local conf=$1 dns resolver
    dns=$(sip_get "$conf" dns)
    if [[ ! $dns ]]; then
        for resolver in /run/systemd/resolve/resolv.conf /etc/resolv.conf; do
            [[ -f $resolver ]] || continue
            dns=$(awk '/^nameserver / && $2 !~ /^127\./ && $2 ~ /^[0-9.]+$/ {print $2; exit}' "$resolver")
            [[ ! $dns ]] || break
        done
        dns=${dns:-1.1.1.1}
    fi
    if [[ $dns == *127.* || $dns == *::1* || $dns == *localhost* ]]; then
        sip_error 'Use a DNS server reachable through the selected interface, not a loopback DNS stub.'
        return 1
    fi
    printf '%s\n' "$dns"
}

sip_rules() {
    local account_uid=$1 address=$2
    [[ $account_uid =~ ^[1-9][0-9]*$ && $address =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
    cat <<EOF
table ip snell_ip_${account_uid} {
  chain source {
    type nat hook postrouting priority 95; policy accept;
    meta skuid ${account_uid} counter snat to ${address}
  }
}
EOF
}
sip_apply_rules() {
    local account_uid=$1 address=$2 rules
    rules=$(mktemp)
    if nft list table ip "snell_ip_$account_uid" >/dev/null 2>&1; then
        printf 'delete table ip snell_ip_%s\n' "$account_uid" > "$rules"
    fi
    sip_rules "$account_uid" "$address" >> "$rules" || { rm -f "$rules"; return 1; }
    if ! nft -c -f "$rules" || ! nft -f "$rules"; then rm -f "$rules"; return 1; fi
    rm -f "$rules"
}
sip_drop_rules() {
    local account_uid=$1
    [[ $account_uid =~ ^[1-9][0-9]*$ ]] || return 1
    if nft list table ip "snell_ip_$account_uid" >/dev/null 2>&1; then
        nft delete table ip "snell_ip_$account_uid"
    fi
}
sip_dropin() {
    local profile=$1
    cat <<EOF
[Unit]
Wants=network-online.target
After=network-online.target nftables.service

[Service]
User=snell-ip-${profile}
Group=snell-ip-${profile}
AmbientCapabilities=
AmbientCapabilities=CAP_NET_BIND_SERVICE CAP_NET_RAW
CapabilityBoundingSet=
CapabilityBoundingSet=CAP_NET_BIND_SERVICE CAP_NET_RAW
RestrictAddressFamilies=
RestrictAddressFamilies=AF_UNIX AF_INET AF_NETLINK
ExecStartPre=+${SNELL_IP_HELPER} ensure ${profile}
EOF
}

# Invoked as root by ExecStartPre, including after reboot. No mutable metadata
# is sourced as shell code. Refuse a missing/renamed address rather than start
# an unbound server. The root-owned metadata is outside /etc/snell because the
# legacy manager recursively changes that directory's ownership.
sip_ensure() {
    local profile=$1 meta conf address iface account_uid user version
    sip_id_valid "$profile" || return 1
    meta=$SNELL_IP_STATE/$profile.json
    [[ -f $meta && ! -L $meta ]] || return 1
    conf=$(jq -er .config "$meta") || return 1
    [[ $conf == "$(sip_conf "$profile")" && ! -L $conf && $(realpath "$conf") == "$conf" ]] || return 1
    address=$(jq -er .ip "$meta") || return 1
    iface=$(jq -er .interface "$meta") || return 1
    account_uid=$(jq -er .uid "$meta") || return 1
    user=snell-ip-$profile
    [[ $(id -u "$user") == "$account_uid" ]] || return 1
    sip_select "$address" || return 1
    [[ $SIP_INTERFACE == "$iface" ]] || return 1
    [[ $(sip_get "$conf" listen) == "$address:"* && $(sip_get "$conf" egress-interface) == "$iface" ]] || return 1
    version=$(sip_version "$conf") || return 1
    if [[ $version == v6 ]]; then
        [[ $(sip_get "$conf" dns-ip-preference) == ipv4-only ]] || return 1
    else
        [[ $(sip_get "$conf" ipv6) == false ]] || return 1
    fi
    chown "$user:$user" "$conf" || return 1
    chmod 600 "$conf" || return 1
    sip_apply_rules "$account_uid" "$address"
}

sip_require() {
    local command
    [[ $EUID == 0 ]] || { sip_error 'Run as root.'; return 1; }
    for command in ip jq nft systemctl useradd getent flock; do
        command -v "$command" >/dev/null || { sip_error "Missing $command. On Ubuntu: apt-get install iproute2 jq nftables"; return 1; }
    done
}
sip_account() {
    local user=snell-ip-$1 entry
    if ! getent passwd "$user" >/dev/null; then
        useradd --system --user-group --no-create-home --home-dir /nonexistent \
            --shell /usr/sbin/nologin --comment 'txehq Snell IP profile' "$user" || return 1
    fi
    entry=$(getent passwd "$user") || return 1
    [[ $(cut -d: -f5 <<<"$entry") == 'txehq Snell IP profile' && $(id -u "$user") != 0 ]] || {
        sip_error 'The dedicated account name is already used by another account.'; return 1;
    }
    id -u "$user"
}
sip_check_direct_service() {
    local profile=$1 conf=$2 service namespace sockets command port binary output expected
    service=$(sip_service "$profile")
    systemctl cat "$service" >/dev/null || { sip_error 'Existing Snell service not found.'; return 1; }
    namespace=$(systemctl show -p NetworkNamespacePath --value "$service") || return 1
    sockets=$(systemctl show -p Sockets --value "$service") || return 1
    [[ ! $namespace && ! $sockets ]] || { sip_error 'Socket-activated/netns profiles are not supported by this migration.'; return 1; }
    if systemctl is-active --quiet "$service.socket" || systemctl is-enabled --quiet "$service.socket"; then
        sip_error 'Disable socket-activation egress mode before this migration.'; return 1
    fi
    command=$(systemctl show -p ExecStart --value "$service") || return 1
    [[ " $command " == *"-c $conf "* ]] || { sip_error 'Service uses a different config; no changes made.'; return 1; }
    if [[ $command =~ path=([^\ ;]+) ]]; then binary=${BASH_REMATCH[1]}; else return 1; fi
    [[ $binary == "$SNELL_IP_BIN/snell-server" || $binary == "$SNELL_IP_BIN/snell-server-v5" || $binary == "$SNELL_IP_BIN/snell-server-v6" ]] || {
        sip_error 'Service uses a custom binary; inspect it before migration.'; return 1;
    }
    expected=$(sip_version "$conf") || return 1
    output=$("$binary" --v 2>&1) || true
    [[ $output == *"$expected."* ]] || { sip_error 'Service binary does not match its v5/v6 profile.'; return 1; }
    [[ $(sip_get "$conf" listen) != 127.* && $(sip_get "$conf" listen) != '[::1]:'* ]] || {
        sip_error 'Loopback/ShadowTLS backends require a separate migration.'; return 1;
    }
    port=$(sip_get "$conf" listen); port=${port##*:}
    if [[ -f $SNELL_IP_UNITS/shadowtls-snell-$port.service ]]; then
        sip_error 'This profile has a ShadowTLS frontend; no changes made.'; return 1
    fi
}
sip_healthy() {
    systemctl restart "$1" || return 1
    sleep 2
    systemctl is-active --quiet "$1"
}

sip_bind() (
    set -e
    umask 077
    local profile=${1:-} address=${2:-} conf service port version account_uid backup stage drop meta dns was_active=false
    sip_id_valid "$profile" || { sip_error 'Use main or a profile port number.'; exit 1; }
    sip_require || exit 1
    exec 9>"$SNELL_IP_LOCK"
    flock -x 9
    conf=$(sip_conf "$profile"); service=$(sip_service "$profile")
    [[ -f $conf && ! -L $conf ]] || { sip_error 'Profile config not found.'; exit 1; }
    [[ $(grep -cE '^\[snell-server\][[:space:]]*$' "$conf") == 1 && $(sip_get "$conf" psk) ]] || {
        sip_error 'Expected one snell-server section with a PSK.'; exit 1;
    }
    version=$(sip_version "$conf") || exit 1
    dns=$(sip_dns "$conf") || exit 1
    sip_check_direct_service "$profile" "$conf" || exit 1
    if systemctl is-active --quiet "$service"; then was_active=true; fi
    sip_select "$address" || exit 1
    port=$(sip_get "$conf" listen); port=${port##*:}
    [[ $port =~ ^[1-9][0-9]{0,4}$ && $port -le 65535 ]] || exit 1
    mkdir -p "$SNELL_IP_STATE" "$SNELL_IP_STATE/backups"
    chmod 700 "$SNELL_IP_STATE" "$SNELL_IP_STATE/backups"
    backup=$(mktemp -d "$SNELL_IP_STATE/backups/$profile.XXXXXX")
    cp -a "$conf" "$backup/config"
    drop=$SNELL_IP_UNITS/$service.service.d/60-public-ip.conf
    meta=$SNELL_IP_STATE/$profile.json
    [[ ! -f $drop ]] || cp -a "$drop" "$backup/dropin"
    [[ ! -f $meta ]] || cp -a "$meta" "$backup/metadata"
    printf 'Backup: %s\n' "$backup"
    stage=$(mktemp -d "$SNELL_IP_STATE/.stage.XXXXXX")
    trap 'rm -rf "$stage"' EXIT
    account_uid=$(sip_account "$profile") || exit 1
    sip_rewrite "$conf" "$SIP_ADDRESS" "$SIP_INTERFACE" "$port" "$version" > "$stage/config"
    if [[ ! $(sip_get "$conf" dns) ]]; then
        # Installer profiles use a single section. Insert DNS in that section,
        # rather than sending resolver traffic to an unreachable loopback stub.
        sed -i '/^\[snell-server\]$/a dns = '"$dns" "$stage/config"
    fi
    jq -n --arg config "$conf" --arg ip "$SIP_ADDRESS" --arg interface "$SIP_INTERFACE" \
        --argjson uid "$account_uid" '{config:$config,ip:$ip,interface:$interface,uid:$uid}' > "$stage/metadata"
    sip_dropin "$profile" > "$stage/dropin"
    mkdir -p "${SNELL_IP_HELPER%/*}"
    if [[ $(realpath "${BASH_SOURCE[0]}") != "$SNELL_IP_HELPER" ]]; then
        install -m 755 "${BASH_SOURCE[0]}" "$SNELL_IP_HELPER"
    fi
    # shellcheck disable=SC2329
    rollback() {
        trap - ERR INT TERM
        systemctl stop "$service" || true
        cp -a "$backup/config" "$conf"
        if [[ -f $backup/dropin ]]; then cp -a "$backup/dropin" "$drop"; else rm -f "$drop"; fi
        if [[ -f $backup/metadata ]]; then
            cp -a "$backup/metadata" "$meta"
        else
            rm -f "$meta"
            sip_drop_rules "$account_uid" || true
        fi
        systemctl daemon-reload
        if [[ $was_active == true ]]; then
            sip_healthy "$service" || sip_error 'Config restored, but the service still needs attention.'
        fi
        sip_error "Migration failed; original profile restored. Backup: $backup"
        exit 1
    }
    trap rollback ERR INT TERM
    systemctl stop "$service"
    # Write via cat to preserve the config pathname/permissions until ensure.
    cat "$stage/config" > "$conf"
    mv "$stage/metadata" "$meta"
    mkdir -p "${drop%/*}"
    mv "$stage/dropin" "$drop"
    systemctl daemon-reload
    sip_ensure "$profile"
    sip_healthy "$service"
    trap - ERR INT TERM
    printf 'Migrated %s: %s:%s -> exit %s (%s). PSK and protocol settings preserved.\n' \
        "$profile" "$SIP_ADDRESS" "$port" "$SIP_ADDRESS" "$SIP_INTERFACE"
)

sip_port_free() {
    local port=$1 conf listen sockets
    [[ $port =~ ^[1-9][0-9]{0,4}$ && $port -le 65535 ]] || return 1
    for conf in "$SNELL_IP_CONF"/users/*.conf "$SNELL_IP_CONF"/snell-server.conf; do
        [[ -f $conf ]] || continue
        listen=$(sip_get "$conf" listen)
        [[ ${listen##*:} != "$port" ]] || return 1
    done
    sockets=$(ss -H -lntu) || return 1
    ! awk '{print $5}' <<<"$sockets" | grep -qE ":${port}$"
}
sip_export() {
    local profile=$1 conf address port psk version mode
    sip_id_valid "$profile" || return 1
    conf=$(sip_conf "$profile")
    address=$(sip_get "$conf" '#txehq-bind-ip')
    [[ $address ]] || { sip_error 'This profile has not been bound to a public IP.'; return 1; }
    port=$(sip_get "$conf" listen); port=${port##*:}
    psk=$(sip_get "$conf" psk); version=$(sip_version "$conf") || return 1
    printf 'Snell-%s-%s = snell, %s, %s, psk = %s, version = %s' "$profile" "$address" "$address" "$port" "$psk" "${version#v}"
    if [[ $version == v6 ]]; then mode=$(sip_get "$conf" mode); printf ', mode = %s' "${mode:-default}"; fi
    printf ', reuse = true, tfo = true\n'
}
sip_cleanup() {
    local profile=$1 meta service account_uid
    sip_id_valid "$profile" || return 1
    service=$(sip_service "$profile"); meta=$SNELL_IP_STATE/$profile.json
    # Never remove source rules from a running profile.
    if systemctl is-active --quiet "$service"; then sip_error 'Stop this profile before cleanup.'; return 1; fi
    if [[ -f $meta ]]; then
        account_uid=$(jq -er .uid "$meta") || return 1
        sip_drop_rules "$account_uid" || return 1
        rm -f "$meta"
    fi
    rm -f "$SNELL_IP_UNITS/$service.service.d/60-public-ip.conf"
    rm -rf "$SNELL_IP_STATE/backups/$profile."*
    # Retain the locked service account so its UID cannot be reused accidentally.
}
sip_run_bind_child() { bash "${BASH_SOURCE[0]}" bind-ip "$@"; }
sip_add() (
    set -e
    umask 077
    local address='' port=auto version='' conf binary psk service option dns attempt
    while [[ $# -gt 0 ]]; do
        option=$1
        [[ $# -ge 2 ]] || { sip_error 'Options require a value.'; exit 1; }
        case $option in
            --bind-ip) address=$2;; --port) port=$2;; --version) version=$2;;
            *) sip_error "Unknown option: $option"; exit 1;;
        esac
        shift 2
    done
    sip_require || exit 1
    exec 8>"$SNELL_IP_LOCK"
    flock -x 8
    command -v ss >/dev/null; command -v openssl >/dev/null
    sip_select "$address" || exit 1
    address=$SIP_ADDRESS
    [[ $version ]] || version=$(sip_version "$(sip_conf main)")
    [[ $version == v5 || $version == v6 ]] || { sip_error 'Choose v5 or v6.'; exit 1; }
    binary=$(sip_binary "$version") || exit 1
    if [[ $port == auto ]]; then
        for ((attempt=0; attempt<100; attempt++)); do
            port=$(shuf -i 10000-65000 -n 1)
            if sip_port_free "$port"; then break; fi
        done
    fi
    sip_port_free "$port" || { sip_error 'Port is already used; choose another port.'; exit 1; }
    conf=$(sip_conf "$port"); service=$(sip_service "$port")
    [[ ! -e $SNELL_IP_UNITS/$service.service ]] || { sip_error 'Service already exists.'; exit 1; }
    [[ ! -e $SNELL_IP_STATE/$port.json ]] || { sip_error 'Binding metadata already exists; inspect the old profile first.'; exit 1; }
    mkdir -p "$SNELL_IP_CONF/users"
    psk=$(openssl rand -hex 24)
    dns=$(sip_dns "$(sip_conf main)")
    # shellcheck disable=SC2329
    cleanup_new() {
        trap - ERR INT TERM
        systemctl stop "$service" || true
        systemctl disable "$service" || true
        if ! sip_cleanup "$port"; then
            sip_error 'Could not clean up source rules; retaining the profile for inspection.'
            exit 1
        fi
        rm -f "$conf" "$SNELL_IP_UNITS/$service.service"
        systemctl daemon-reload
        exit 1
    }
    trap cleanup_new ERR INT TERM
    {
        printf '#version-choice = %s\n[snell-server]\nlisten = %s:%s\npsk = %s\n' "$version" "$address" "$port" "$psk"
        if [[ $version == v6 ]]; then printf 'mode = default\ndns-ip-preference = ipv4-only\n'; else printf 'ipv6 = false\n'; fi
        printf 'dns = %s\n' "$dns"
    } > "$conf"
    cat > "$SNELL_IP_UNITS/$service.service" <<EOF
[Unit]
Description=Snell profile ${port}
After=network-online.target
[Service]
Type=simple
User=nobody
NoNewPrivileges=yes
PrivateTmp=yes
ProtectSystem=strict
ProtectHome=yes
ExecStart=${binary} -c ${conf}
Restart=on-failure
RestartSec=2
[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    flock -u 8
    exec 8>&-
    # No listener is started before bind-ip has installed its source rules.
    if ! sip_run_bind_child "$port" "$address"; then
        cleanup_new
    fi
    systemctl enable "$service"
    trap - ERR INT TERM
    printf 'Created profile. Allow TCP %s' "$port"
    [[ $version != v5 ]] || printf ' and UDP %s (Snell v5 QUIC)' "$port"
    printf ' through your firewall.\n'
    sip_export "$port"
)
sip_menu() {
    local choice profile address
    printf '1) 列出公网 IP\n2) 迁移现有配置 (保留 PSK/端口)\n3) 新建配置 (新 PSK)\n4) 显示客户端配置\n'
    read -rp '选择: ' choice || return 1
    case $choice in
        1) sip_ips;;
        2) read -rp '配置 (main 或现有端口): ' profile || return 1
           sip_select '' || return 1; address=$SIP_ADDRESS; sip_bind "$profile" "$address";;
        3) sip_add;;
        4) read -rp '配置 (main 或端口): ' profile || return 1; sip_export "$profile";;
        *) return 1;;
    esac
}
sip_main() {
    local action=${1:-ip-menu}; shift || true
    case $action in
        ips) sip_ips;;
        bind-ip) [[ $# == 2 ]] || { sip_error 'Usage: snell bind-ip main|PORT IP'; return 1; }; sip_bind "$@";;
        add) sip_add "$@";;
        profile) [[ $# == 1 ]] && sip_export "$1";;
        ensure) [[ $EUID == 0 && $# == 1 ]] && sip_ensure "$1";;
        cleanup) [[ $EUID == 0 && $# == 1 ]] && sip_cleanup "$1";;
        ip-menu) sip_menu;;
        *) sip_error 'Commands: ips, bind-ip main|PORT IP, add [--bind-ip IP] [--port PORT] [--version v5|v6], profile main|PORT';;
    esac
}
if [[ ${BASH_SOURCE[0]} == "$0" ]]; then sip_main "$@"; fi
