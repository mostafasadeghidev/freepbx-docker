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
# shellcheck source=scripts/recreate.sh
. scripts/recreate.sh
set -a
# shellcheck disable=SC1091
. ./.env
set +a

# An .env older than COMPOSE_FILE: a bare `up -d` would load compose.yml alone
# and recreate the PBX without its tunnel port and Coolify network. The running
# container remembers which files made it, so ask it, and write the answer down.
if [ -z "${COMPOSE_FILE:-}" ]; then
    COMPOSE_FILE="$(docker inspect -f '{{index .Config.Labels "com.docker.compose.project.config_files"}}' freepbx 2>/dev/null \
        | tr ',' '\n' | sed 's#.*/##' | grep -v '^$' | paste -sd: - || true)"
    export COMPOSE_FILE="${COMPOSE_FILE:-compose.yml}"
    if [ "$CHECK_ONLY" = 0 ]; then
        printf 'COMPOSE_FILE=%s\n' "$COMPOSE_FILE" >> .env
        echo "(.env had no COMPOSE_FILE; wrote the files the running PBX was made from: $COMPOSE_FILE)"
    fi
fi

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

# The other way a recreate takes the PBX down — see scripts/recreate.sh.
echo "Checking that a recreate keeps the installation…"
if recreate_erases_install; then
    echo
    echo "✗ FreePBX exists only inside the running container, and a recreate would"
    echo "  start from an image without it — erasing the install while ./data still"
    echo "  says installed. Take the snapshot first:"
    echo
    echo "      ./snapshot.sh"
    echo "      sed -i 's#^PBX_IMAGE=.*#PBX_IMAGE=freepbx17-official:installed#' .env"
    echo
    echo "Nothing was changed, and the running system was not touched."
    exit 1
fi
echo "✓ A recreate starts from an image that has the installation (or there is none yet)."

[ "$CHECK_ONLY" = 1 ] && exit 0

docker compose up -d
