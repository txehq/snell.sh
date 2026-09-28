#!/usr/bin/env bash
set -e
repo=$(cd "$(dirname "$0")/.." && pwd)
. "$repo/ip-binding.sh"
scratch=$(mktemp -d "$repo/.ip-test.XXXXXX")
trap 'rm -rf "$scratch"' EXIT
SNELL_IP_CONF=$scratch/etc/snell
SNELL_IP_STATE=$scratch/etc/bindings
SNELL_IP_UNITS=$scratch/units
SNELL_IP_BIN=$scratch/bin
SNELL_IP_HELPER=$scratch/lib/ip-binding.sh
SNELL_IP_LOCK=$scratch/lock
mkdir -p "$SNELL_IP_CONF/users" "$SNELL_IP_UNITS" "$SNELL_IP_BIN" "$scratch/rules"
for version in v5 v6; do
    printf '#!/bin/sh\necho "Snell %s.0.1"\n' "$version" > "$SNELL_IP_BIN/snell-server-$version"
    chmod +x "$SNELL_IP_BIN/snell-server-$version"
done
ln -s snell-server-v5 "$SNELL_IP_BIN/snell-server"
cat > "$SNELL_IP_CONF/users/snell-main.conf" <<'EOF'
#version-choice = v5
[snell-server]
listen = 0.0.0.0:6160
psk = original-PSK=with-equals
dns = 8.8.8.8,1.1.1.1
ipv6 = true
EOF
cp "$SNELL_IP_CONF/users/snell-main.conf" "$scratch/original"
printf 'active\n' > "$scratch/service-state"
IP_FIXTURE='[{"ifname":"ens3","addr_info":[
 {"family":"inet","scope":"global","local":"74.219.23.240"},
 {"family":"inet","scope":"global","local":"74.219.23.237"},
 {"family":"inet","scope":"global","local":"172.18.0.1"},
 {"family":"inet","scope":"global","local":"100.64.1.1"},
 {"family":"inet","scope":"global","local":"192.0.2.1"}]}]'
ip() { printf '%s\n' "$IP_FIXTURE"; }
flock() { :; }
chown() { :; }
sleep() { :; }
ss() { printf '%s\n' "${SOCKETS:-}"; }
id() {
    [[ $1 == -u ]] || return 1
    if [[ $2 == snell-ip-main ]]; then printf '41001\n'; else printf '%s\n' "$((41000+${2##*-}))"; fi
}
sip_require() { :; }
sip_account() { id -u "snell-ip-$1"; }
sip_run_bind_child() { sip_bind "$@"; }
sip_apply_rules() { sip_rules "$1" "$2" > "$scratch/rules/$1"; }
sip_drop_rules() { rm -f "$scratch/rules/$1"; }
systemctl() {
    local service=${*: -1} profile config state version
    profile=${service#snell-}
    [[ $service != snell ]] || profile=main
    if [[ $profile == main ]]; then state=$scratch/service-state; else state=$scratch/state-$service; fi
    config=$(sip_conf "$profile")
    case $1 in
        cat) printf 'unit\n';;
        show)
            case $3 in
                NetworkNamespacePath) printf '%s\n' "${TEST_NETNS:-}";;
                Sockets) printf '%s\n' "${TEST_SOCKETS:-}";;
                ExecStart)
                    version=$(sip_version "$config")
                    printf '{ path=%s/snell-server-%s ; argv[]=%s/snell-server-%s -c %s ; }\n' "$SNELL_IP_BIN" "$version" "$SNELL_IP_BIN" "$version" "$config";;
            esac;;
        is-active)
            [[ ${*: -1} != *.socket && $(cat "$state" 2>/dev/null) == active ]];;
        is-enabled) return 1;;
        stop) printf 'inactive\n' > "$state";;
        restart)
            if [[ -f $scratch/fail-restart ]]; then rm "$scratch/fail-restart"; return 1; fi
            if [[ -f $SNELL_IP_STATE/$profile.json ]]; then sip_ensure "$profile" || return 1; fi
            printf 'active\n' > "$state";;
        daemon-reload|enable|disable) :;;
        *) printf 'Unexpected systemctl: %s\n' "$*" >&2; return 1;;
    esac
}
run() { local name=$1; shift; ( "$@" ); printf 'PASS: %s\n' "$name"; }
failure() {
    # A separate subshell keeps errexit/ERR enabled inside mutation functions.
    set +e
    ( "$@" ) > "$scratch/failure.log" 2>&1
    local result=$?
    set -e
    [[ $result != 0 ]]
}
discovery() {
    [[ $(sip_ips | wc -l | tr -d ' ') == 2 ]]
    sip_select 74.219.23.237
    [[ $SIP_INTERFACE == ens3 && $SIP_ADDRESS == 74.219.23.237 ]]
    failure sip_select 172.18.0.1
    failure sip_select auto
    failure sip_select 1.1.1.1
}
rewrite() {
    sip_rewrite "$scratch/original" 74.219.23.240 ens3 6160 v5 > "$scratch/rewrite"
    [[ $(sip_get "$scratch/rewrite" psk) == 'original-PSK=with-equals' ]]
    [[ $(sip_get "$scratch/rewrite" listen) == 74.219.23.240:6160 ]]
    [[ $(sip_get "$scratch/rewrite" dns) == 8.8.8.8,1.1.1.1 ]]
    [[ $(sip_get "$scratch/rewrite" ipv6) == false ]]
    sip_rewrite "$scratch/rewrite" 74.219.23.240 ens3 6160 v5 > "$scratch/rewrite2"
    cmp "$scratch/rewrite" "$scratch/rewrite2"
    cat > "$scratch/v6" <<'EOF'
#version-choice = v6
[snell-server]
listen = [::]:6160
psk = same-secret
mode = unshaped
dns-ip-preference = prefer-ipv6
[other]
preserve = value
EOF
    sip_rewrite "$scratch/v6" 74.219.23.237 ens3 6160 v6 > "$scratch/v6-rewritten"
    [[ $(sip_get "$scratch/v6-rewritten" mode) == unshaped ]]
    [[ $(sip_get "$scratch/v6-rewritten" psk) == same-secret ]]
    [[ $(sip_get "$scratch/v6-rewritten" dns-ip-preference) == ipv4-only ]]
    grep -q '^preserve = value$' "$scratch/v6-rewritten"
}
migrate() {
    sip_bind main 74.219.23.240 >/dev/null
    [[ $(sip_get "$(sip_conf main)" psk) == 'original-PSK=with-equals' ]]
    [[ $(sip_get "$(sip_conf main)" listen) == 74.219.23.240:6160 ]]
    jq -e '.ip=="74.219.23.240" and .interface=="ens3" and .uid==41001' "$SNELL_IP_STATE/main.json" >/dev/null
    grep -q 'meta skuid 41001 counter snat to 74.219.23.240' "$scratch/rules/41001"
    grep -q '^User=snell-ip-main$' "$SNELL_IP_UNITS/snell.service.d/60-public-ip.conf"
    grep -q '^RestrictAddressFamilies=AF_UNIX AF_INET AF_NETLINK$' "$SNELL_IP_UNITS/snell.service.d/60-public-ip.conf"
    [[ $(cat "$scratch/service-state") == active ]]
}
idempotent_and_export() {
    cp "$(sip_conf main)" "$scratch/before-rerun"
    sip_bind main 74.219.23.240 >/dev/null
    cmp "$scratch/before-rerun" "$(sip_conf main)"
    [[ $(sip_export main) == *'74.219.23.240, 6160, psk = original-PSK=with-equals, version = 5'* ]]
}
restore_rules_on_start() {
    rm "$scratch/rules/41001"
    sip_ensure main
    grep -q 'snat to 74.219.23.240' "$scratch/rules/41001"
    IP_FIXTURE='[]'
    failure sip_ensure main
}
rollback() {
    cp "$(sip_conf main)" "$scratch/before-failure"
    cp "$SNELL_IP_STATE/main.json" "$scratch/old-metadata"
    touch "$scratch/fail-restart"
    failure sip_bind main 74.219.23.237
    cmp "$scratch/before-failure" "$(sip_conf main)"
    cmp "$scratch/old-metadata" "$SNELL_IP_STATE/main.json"
    [[ $(cat "$scratch/service-state") == active ]]
    grep -q 'snat to 74.219.23.240' "$scratch/rules/41001"
}
reject_unsupported() {
    TEST_NETNS=/run/netns/other
    failure sip_bind main 74.219.23.237
    TEST_NETNS=''
    TEST_SOCKETS=snell.socket
    failure sip_bind main 74.219.23.237
    printf '#version-choice = v4\n' > "$scratch/v4"
    failure sip_version "$scratch/v4"
    failure sip_bind ../main 74.219.23.237
}
ports() {
    failure sip_port_free 6160
    sip_port_free 25000
    SOCKETS='tcp LISTEN 0 128 0.0.0.0:25000 0.0.0.0:*'
    failure sip_port_free 25000
}
cleanup() {
    failure sip_cleanup main
    printf inactive > "$scratch/service-state"
    sip_cleanup main
    [[ ! -f $scratch/rules/41001 && ! -f $SNELL_IP_STATE/main.json ]]
    [[ ! -f $SNELL_IP_UNITS/snell.service.d/60-public-ip.conf ]]
    [[ -f $(sip_conf main) ]]
}
new_profiles() {
    sip_add --bind-ip 74.219.23.237 --port 25001 --version v5 > "$scratch/new-profile-output"
    [[ $(sip_get "$(sip_conf 25001)" listen) == 74.219.23.237:25001 ]]
    [[ $(sip_get "$(sip_conf 25001)" psk) != 'original-PSK=with-equals' ]]
    [[ $(sip_get "$(sip_conf 25001)" psk) =~ ^[0-9a-f]{48}$ ]]
    grep -q 'snat to 74.219.23.237' "$scratch/rules/66001"
    sip_add --bind-ip 74.219.23.240 --port 25002 --version v6 >/dev/null
    [[ $(sip_get "$(sip_conf 25002)" psk) != "$(sip_get "$(sip_conf 25001)" psk)" ]]
    [[ $(sip_get "$(sip_conf 25002)" dns-ip-preference) == ipv4-only ]]
    [[ $(sip_export 25002) == *'version = 6, mode = default'* ]]
    failure sip_add --bind-ip 74.219.23.240 --port 25001
}
failed_new_profile() {
    sip_run_bind_child() { return 1; }
    failure sip_add --bind-ip 74.219.23.237 --port 25003 --version v5
    [[ ! -f $(sip_conf 25003) && ! -f $SNELL_IP_UNITS/snell-25003.service ]]
    [[ $(sip_get "$(sip_conf main)" psk) == 'original-PSK=with-equals' ]]
}

if [[ ${1:-} == --menu ]]; then sip_select ''; printf 'SELECTED=%s@%s\n' "$SIP_ADDRESS" "$SIP_INTERFACE"; exit; fi
run public-ip-discovery discovery
run preserve-credentials-and-v6-mode rewrite
run migrate-existing-profile migrate
run idempotence-and-correct-export idempotent_and_export
run restart-restores-source-rules restore_rules_on_start
run failed-restart-rolls-back rollback
run reject-unsupported-configurations reject_unsupported
run avoid-existing-port-collisions ports
run create-v5-v6-with-independent-credentials new_profiles
run failed-create-cleans-up failed_new_profile
run cleanup-only-stopped-profile cleanup
