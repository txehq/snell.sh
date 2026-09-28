#!/usr/bin/env bash
# Run as root under `unshare --net`; never operate in the host network namespace.
set -euo pipefail
[[ $EUID == 0 && $(readlink /proc/self/ns/net) != "$(readlink /proc/1/ns/net)" ]] || {
    echo 'Run this test with sudo unshare --net.' >&2; exit 1;
}
repo=$(cd "$(dirname "$0")/.." && pwd)
. "$repo/ip-binding.sh"
scratch=$(mktemp -d)
chmod 755 "$scratch"
processes=()
cleanup_test() {
    for process in "${processes[@]}"; do kill "$process" 2>/dev/null || true; done
    rm -rf "$scratch"
}
trap cleanup_test EXIT
ip link set lo up
unshare --net sleep 300 &
peer=$!
processes+=("$peer")
for _ in {1..30}; do
    [[ $(readlink /proc/"$peer"/ns/net) != "$(readlink /proc/self/ns/net)" ]] && break
    sleep .1
done
ip link add ens3 type veth peer name remote0
ip link set remote0 netns "$peer"
ip addr add 74.219.23.240/27 dev ens3
ip addr add 74.219.23.237/27 dev ens3
ip link set ens3 up
nsenter -t "$peer" -n ip link set lo up
nsenter -t "$peer" -n ip addr add 74.219.23.225/27 dev remote0
nsenter -t "$peer" -n ip link set remote0 up
nsenter -t "$peer" -n python3 "$repo/tests/network-echo.py" server 74.219.23.225 17880 &
processes+=("$!")
sleep .3
sip_apply_rules 41001 74.219.23.237
sip_apply_rules 41002 74.219.23.240
for protocol in tcp udp; do
    setpriv --reuid 41001 --regid 41001 --clear-groups --inh-caps +net_raw --ambient-caps +net_raw \
        python3 "$repo/tests/network-echo.py" bound-client 74.219.23.225 17880 "$protocol" 74.219.23.237
    setpriv --reuid 41002 --regid 41002 --clear-groups --inh-caps +net_raw --ambient-caps +net_raw \
        python3 "$repo/tests/network-echo.py" bound-client 74.219.23.225 17880 "$protocol" 74.219.23.240
done
# The host's ordinary processes must still use their normal source address.
python3 "$repo/tests/network-echo.py" bound-client 74.219.23.225 17880 tcp 74.219.23.240

# Source NAT must not rewrite replies on existing inbound client connections.
setpriv --reuid 41001 --regid 41001 --clear-groups \
    python3 "$repo/tests/network-echo.py" server 74.219.23.240 17882 &
processes+=("$!")
sleep .3
for protocol in tcp udp; do
    nsenter -t "$peer" -n python3 "$repo/tests/network-echo.py" client 74.219.23.240 17882 "$protocol" 74.219.23.225
done

# Restore a removed table as ExecStartPre does after reboot/restart.
sip_drop_rules 41001
sip_apply_rules 41001 74.219.23.237
setpriv --reuid 41001 --regid 41001 --clear-groups --inh-caps +net_raw --ambient-caps +net_raw \
    python3 "$repo/tests/network-echo.py" bound-client 74.219.23.225 17880 tcp 74.219.23.237

# Start official Snell binaries with the actual generated configuration. These
# are startup/listener checks, not an implementation of Snell's client protocol.
for version in v5 v6; do
    if [[ $version == v5 ]]; then binary=${SNELL_TEST_V5:?}; port=17885; else binary=${SNELL_TEST_V6:?}; port=17886; fi
    cat > "$scratch/base.conf" <<EOF
#version-choice = ${version}
[snell-server]
listen = 0.0.0.0:${port}
psk = isolated-test-credentials
dns = 74.219.23.225
EOF
    if [[ $version == v6 ]]; then printf 'mode = default\n' >> "$scratch/base.conf"; fi
    sip_rewrite "$scratch/base.conf" 74.219.23.237 ens3 "$port" "$version" > "$scratch/$version.conf"
    chmod 644 "$scratch/$version.conf"
    setpriv --reuid 41001 --regid 41001 --clear-groups --inh-caps +net_raw --ambient-caps +net_raw \
        "$binary" -c "$scratch/$version.conf" > "$scratch/$version.log" 2>&1 &
    snell_pid=$!
    processes+=("$snell_pid")
    sleep 2
    kill -0 "$snell_pid" || { cat "$scratch/$version.log"; exit 1; }
    ss -H -lnt | grep -q "74.219.23.237:$port"
    printf 'PASS: official Snell %s starts on selected public IP\n' "$version"
done
