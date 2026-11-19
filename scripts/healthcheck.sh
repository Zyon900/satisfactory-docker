#!/usr/bin/env bash
set -euo pipefail

# Verify the Unreal dedicated server binary is running
if ! pgrep -f 'FactoryServer-Linux-Shipping|UnrealServer-Linux-Shipping' >/dev/null 2>&1; then
    echo "Satisfactory server process is not running" >&2
    exit 1
fi

# Verify the configured game port is bound on UDP or TCP via /proc/net
GAME_PORT="${GAME_PORT:-7777}"
HEX_PORT="$(printf '%04X' "${GAME_PORT}")"

if ! grep -qiE ":${HEX_PORT}[[:space:]]" /proc/net/udp /proc/net/udp6 /proc/net/tcp /proc/net/tcp6 2>/dev/null; then
    echo "Satisfactory server is not listening on port ${GAME_PORT}" >&2
    exit 1
fi

exit 0
