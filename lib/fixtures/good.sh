#!/usr/bin/env bash
set -u
input="$(cat)"
case "$input" in *'"stop_hook_active"'*'true'*) exit 0 ;; esac
exit 0
