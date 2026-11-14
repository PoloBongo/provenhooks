#!/usr/bin/env bash
# Ignores stop_hook_active and blocks unconditionally: the classic infinite loop.
set -u
cat > /dev/null
echo "always blocking" >&2
exit 2
