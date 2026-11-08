#!/bin/bash
set -euo pipefail
# Pinned sample check. Executed only by the future prepared guest worker.
/usr/bin/grep -qx after /work/project/message.txt
printf 'sample check passed\n'
