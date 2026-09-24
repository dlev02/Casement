#!/bin/sh
# Copies WindowsHost/ (without bin/obj) from the Mac to the PC over SSH. The folder must exist on
# the PC (once: ssh you@100.64.0.20 "mkdir C:\src\vantage").
#   sh WindowsHost/scripts/push.sh            # to you@100.64.0.20, C:/src/vantage
#   PC=you@drew-pc sh WindowsHost/scripts/push.sh
set -eu
PC="${PC:-you@100.64.0.20}"
DEST="${DEST:-C:/src/vantage}"
cd "$(dirname "$0")/../.."
COPYFILE_DISABLE=1 tar --exclude bin --exclude obj --exclude artifacts --exclude TestResults --exclude .vs \
    -czf - WindowsHost | ssh "$PC" "tar -xzf - -C $DEST"
echo "pushed WindowsHost to $PC:$DEST"
