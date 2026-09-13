#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Apply what .env says — after making sure nothing else holds its ports.
#
#     ./apply.sh            check, then docker compose up -d
#     ./apply.sh --check    check only, change nothing
#
# Use this instead of a bare `docker compose up -d` whenever a port, the panel
# address, the tunnel or the file list in .env has changed.
#
# The reason is measured, and it is not "you get an error". On a machine
# running Coolify, TUNNEL_PORT=443 made compose recreate the telephone
# container to add the port, fail to start the new one because Traefik already
# held 443, and leave NO telephone container running. A clash takes the system
# down; it does not refuse politely. So the question is asked here, first,
# while everything still works.
# ---------------------------------------------------------------------------
set -euo pipefail

cd "$(dirname "$0")"

CHECK_ONLY=0
[ "${1:-}" = "--check" ] && CHECK_ONLY=1

[ -f .env ] || { echo "No .env here. Run ./setup.sh first." >&2; exit 1; }

# shellcheck source=scripts/ports.sh
. scripts/ports.sh
set -a
# shellcheck disable=SC1091
. ./.env
set +a

echo "Checking the ports .env asks for…"
if ! conflicts="$(kit_wanted_ports | ports_conflicts)"; then
    echo
    echo "✗ These are already taken by something else:"
    printf '%s\n' "$conflicts" | while read -r label proto port who; do
        printf '    %-12s %s/%s  held by %s\n' "$label" "$port" "$proto" "${who#*:}"
    done
    echo
    if printf '%s\n' "$conflicts" | grep -q '^TUNNEL_PORT '; then
        if alt="$(free_tunnel_port)"; then
            echo "  For the tunnel, $alt/tcp is free here: set TUNNEL_PORT=$alt in .env"
            echo "  and the same port= on the router's ovpn-client."
        fi
    fi
    echo "Nothing was changed, and the running system was not touched."
    exit 1
fi
echo "✓ No clashes."

[ "$CHECK_ONLY" = 1 ] && exit 0

docker compose up -d
