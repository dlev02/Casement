#!/bin/sh
# Copies WindowsHost/ (without bin/obj) from the Mac to the PC over SSH. The folder must exist on
# the PC (once: ssh <user>@<pc> "mkdir C:\src\vantage"). PC is the SSH target, e.g. the PC's
# Tailscale name or address:
#   PC=you@your-pc sh WindowsHost/scripts/push.sh      # to C:/src/vantage
set -eu
PC="${PC:?set PC to the SSH target, e.g. PC=you@your-pc}"
DEST="${DEST:-C:/src/vantage}"
cd "$(dirname "$0")/../.."
COPYFILE_DISABLE=1 tar --exclude bin --exclude obj --exclude artifacts --exclude TestResults --exclude .vs \
    -czf - WindowsHost | ssh "$PC" "tar -xzf - -C $DEST"
echo "pushed WindowsHost to $PC:$DEST"
