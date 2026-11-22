#!/bin/bash
# Prints a free TCP port for a test host in this checkout's own block, so parallel worktrees
# (and their agents) never fight over one: each checkout path maps to a block of 10 ports in
# 47900–48899, and the first one nothing is listening on is printed.
#   PORT=$(scripts/test-port.sh)                 # this checkout's first free port
#   PORT=$(scripts/test-port.sh 3)               # skip the block's first 3 (a second host)
# 47820 is the real host, 47821–47829 the PC's firewall range; neither is ever handed out.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd -P)
skip=${1:-0}
block=$(( $(printf '%s' "$root" | cksum | cut -d' ' -f1) % 100 ))
base=$(( 47900 + block * 10 ))

for offset in $(seq "$skip" 9); do
    port=$(( base + offset ))
    if ! lsof -nP -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1; then
        echo "$port"
        exit 0
    fi
done
echo "test-port: every port in $base–$(( base + 9 )) is taken" >&2
exit 1
