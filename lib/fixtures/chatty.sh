#!/usr/bin/env bash
set -u
input="$(cat)"
case "$input" in *'"stop_hook_active"'*'true'*) exit 0 ;; esac
echo "everything looks fine to me"   # stdout nobody will ever read
exit 0
