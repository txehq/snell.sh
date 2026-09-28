#!/bin/bash
# Install this launcher as /usr/local/bin/snell to migrate an existing manager
# to this fork without reinstalling Snell or replacing any profile.
set -e
[[ $EUID == 0 ]] || { echo 'Run as root.' >&2; exit 1; }
payload=$(mktemp)
trap 'rm -f "$payload"' EXIT
curl -fLsS --retry 2 --connect-timeout 10 --max-time 60 \
    https://raw.githubusercontent.com/txehq/snell.sh/main/snell.sh -o "$payload"
test -s "$payload"
bash -n "$payload"
bash "$payload" "$@"
