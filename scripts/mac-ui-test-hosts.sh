#!/bin/zsh
# Starts (or stops) the synthetic hosts the Mac UI tests talk to: the VantageHost.app built beside
# them, run from its executable so its arguments always arrive, on 47856 (MacShellUITests) and
# 47857 (SessionInputUITests), pairing code 246810. The VantageMacUITests scheme runs `start` as a
# test pre-action and `stop` as a post-action; the UI test runner is sandboxed and can't start a
# host that listens itself. Never touches the live host's 47820.
#
# Usage: mac-ui-test-hosts.sh start|stop [products dir]   (default: $BUILT_PRODUCTS_DIR)
set -u
action=${1:-start}
products=${2:-${BUILT_PRODUCTS_DIR:-}}
ports=(47856 47857)

stop() {
    for port in $ports; do
        pkill -f "VantageHost --synthetic-capture --port $port " 2>/dev/null
    done
}

case $action in
start)
    stop
    host="$products/VantageHost.app/Contents/MacOS/VantageHost"
    if [[ ! -x $host ]]; then
        echo "mac-ui-test-hosts: no VantageHost at $host" >&2
        exit 1
    fi
    for port in $ports; do
        nohup "$host" --synthetic-capture --port $port --pairing-code 246810 --exit-after 1800 >/dev/null 2>&1 &
    done
    ;;
stop)
    stop
    ;;
esac
exit 0
