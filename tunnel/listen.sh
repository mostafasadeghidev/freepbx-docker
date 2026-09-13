#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# The listening end of the tunnel, for one router: made, or brought up to date.
#
#     ./tunnel/listen.sh --net 203.0.113.0/24
#     ./tunnel/listen.sh --net 203.0.113.0/24 --port 1194 --user office
#
#   --net NET        the operator's network, as address/bits           (needed)
#   --port N         the TCP port the router dials in on   (default: .env, else
#                    the first free one of 1194 1195 1196 11940 21194)
#   --user NAME      the router's login name                   (default: router)
#   --new-password   replace that user's password instead of keeping it
#   --no-secret      do not print the password (a tool reads tunnel/users)
#   --write-only     write the files and stop; start nothing (setup.sh uses it)
#
# For an installation that is already running, and safe to run again: an
# existing CA is kept, an existing user keeps its password, and a second router
# is a second --user. Everything it writes is git-ignored.
#
# ## Why it refuses an unsnapshotted install
#
# The port is published by the telephone container, so adding it makes compose
# RECREATE that container — and a container that still carries its install in
# its own filesystem loses the whole install on a recreate. Measured, on this
# kit's first clean-server test. So until ./snapshot.sh has run, this stops
# before touching anything.
# ---------------------------------------------------------------------------
set -euo pipefail

cd "$(dirname "$0")/.."

NET=""
PORT=""
USER_NAME="router"
NEW_PASSWORD=0
NO_SECRET=0
WRITE_ONLY=0
while [ $# -gt 0 ]; do
    case "$1" in
        --net)  NET="${2:-}"; shift 2 ;;
        --port) PORT="${2:-}"; shift 2 ;;
        --user) USER_NAME="${2:-}"; shift 2 ;;
        --new-password) NEW_PASSWORD=1; shift ;;
        --no-secret)    NO_SECRET=1; shift ;;
        --write-only)   WRITE_ONLY=1; shift ;;
        -h|--help) sed -n '2,27p' "$0"; exit 0 ;;
        *) echo "unknown option: $1 (try --help)" >&2; exit 2 ;;
    esac
done

say()  { printf '%s\n' "$*"; }
die()  { printf '✗  %s\n' "$*" >&2; exit 1; }

printf '%s' "$NET" | grep -qE '^([0-9]{1,3}\.){3}[0-9]{1,3}/([0-9]|[12][0-9]|3[0-2])$' \
    || die "Give the operator's network as address/bits, like 203.0.113.0/24."
printf '%s' "$USER_NAME" | grep -qE '^[a-z][a-z0-9_-]{0,31}$' \
    || die "A user name is lower-case letters, digits, - and _, starting with a letter."

# shellcheck source=../scripts/ports.sh
. scripts/ports.sh

if [ "$WRITE_ONLY" = 0 ]; then
    [ -f .env ] || die "No .env here. Run ./setup.sh first."

    # The one check that decides whether this is safe at all — see the top.
    # Read whole, then searched: `docker diff | grep -q` under pipefail reports
    # a match as a failure when grep stops reading and docker gets SIGPIPE.
    container_diff="$(docker diff freepbx 2>/dev/null || true)"
    if grep -qx 'A /usr/sbin/fwconsole' <<<"$container_diff"; then
        die "The install still lives only inside the container, and adding a port recreates it. Run ./snapshot.sh first — nothing was changed."
    fi
fi

if [ -z "$PORT" ]; then
    PORT="$(sed -n 's/^TUNNEL_PORT=//p' .env 2>/dev/null | tail -n 1)"
    # A port in .env from a machine that never listened is only a default.
    case ":$(sed -n 's/^COMPOSE_FILE=//p' .env 2>/dev/null):" in
        *compose.tunnel-server.yml*) ;;
        *) PORT="" ;;
    esac
    [ -n "$PORT" ] || PORT="$(free_tunnel_port || echo 1194)"
fi
case "$PORT" in ''|*[!0-9]*) die "That is not a port number: $PORT" ;; esac
[ "$PORT" -ge 1 ] && [ "$PORT" -le 65535 ] || die "That is not a port number: $PORT"

# --- the files --------------------------------------------------------------

[ -f tunnel/pki/ca.crt ] || ./tunnel/make-server-pki.sh >/dev/null

# The password: kept if this user already has one, so running this again does
# not lock out a router that is already connected.
touch tunnel/users
chmod 600 tunnel/users
PASS="$(awk -F: -v u="$USER_NAME" '$1 == u { sub(/^[^:]*:/, ""); print; exit }' tunnel/users)"
if [ -z "$PASS" ] || [ "$NEW_PASSWORD" = 1 ]; then
    PASS=$(head -c 32 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 24)
    others="$(awk -F: -v u="$USER_NAME" '$1 != u' tunnel/users)"
    { [ -n "$others" ] && printf '%s\n' "$others"; printf '%s:%s\n' "$USER_NAME" "$PASS"; } > tunnel/users.new
    chmod 600 tunnel/users.new
    mv tunnel/users.new tunnel/users
fi

# OpenVPN wants a netmask, people write /bits.
net_addr=${NET%/*}
net_bits=${NET#*/}
mask=""
b=$net_bits
for _ in 1 2 3 4; do
    if [ "$b" -ge 8 ]; then oct=255; b=$((b - 8)); else oct=$(( 256 - (1 << (8 - b)) )); [ "$b" -eq 0 ] && oct=0; b=0; fi
    mask="${mask:+$mask.}$oct"
done

conf_before="$(cat tunnel/server.conf 2>/dev/null || true)"
if [ ! -f tunnel/server.conf ]; then
    # The example's route is a placeholder for the first router's network.
    sed -e "s/^port .*/port ${PORT}/" \
        -e "s/^route .*/route ${net_addr} ${mask}/" \
        tunnel/server.conf.example > tunnel/server.conf
else
    sed -i "s/^port .*/port ${PORT}/" tunnel/server.conf
    # A second router brings a second network; the first one's stays.
    grep -qx "route ${net_addr} ${mask}" tunnel/server.conf \
        || sed -i "/^client-config-dir /i route ${net_addr} ${mask}" tunnel/server.conf
fi

# Both halves of the trap in one place: `route` above for this machine and
# `iroute` here for OpenVPN. Without the iroute every packet for the operator
# is dropped without a log line — see tunnel/README.md.
mkdir -p tunnel/ccd
printf 'iroute %s %s\n' "$net_addr" "$mask" > "tunnel/ccd/${USER_NAME}"

say "Tunnel: ${PORT}/tcp, user ${USER_NAME}, operator network ${net_addr} ${mask}"

if [ "$WRITE_ONLY" = 1 ]; then
    exit 0
fi

# --- .env: the port, and the file that publishes it -------------------------

files="$(sed -n 's/^COMPOSE_FILE=//p' .env | tail -n 1)"
if [ -z "$files" ]; then
    # An .env older than COMPOSE_FILE. The running container remembers which
    # files made it, so the Coolify override is not silently dropped.
    files="$(docker inspect -f '{{index .Config.Labels "com.docker.compose.project.config_files"}}' freepbx 2>/dev/null \
        | tr ',' '\n' | sed 's#.*/##' | grep -v '^$' | paste -sd: - || true)"
    [ -n "$files" ] || files="compose.yml"
fi
case ":$files:" in
    *:compose.tunnel-server.yml:*) ;;
    *) files="$files:compose.tunnel-server.yml" ;;
esac

set_env() {
    if grep -q "^$1=" .env; then
        sed -i "s#^$1=.*#$1=$2#" .env
    else
        printf '%s=%s\n' "$1" "$2" >> .env
    fi
}
set_env TUNNEL_PORT "$PORT"
set_env COMPOSE_FILE "$files"

# --- start it, after the same check apply.sh makes --------------------------

running_before="$(docker ps -q --filter name='^freepbx-tunnel-server$')"
./apply.sh

# A changed server.conf is only read when OpenVPN starts. Users and ccd are
# read on every connection, so those need nothing.
if [ -n "$running_before" ] && [ "$conf_before" != "$(cat tunnel/server.conf)" ]; then
    docker compose restart tunnel-server >/dev/null
fi

# `up -d` returning is not OpenVPN listening: the container installs openvpn
# first. Asked of the telephone container's own socket table, which the tunnel
# shares — a log line would still be there from the run before a restart.
port_hex="$(printf '%04X' "$PORT")"
say "Waiting for OpenVPN to listen…"
ready=0
for _ in $(seq 1 40); do
    if docker exec freepbx cat /proc/net/tcp /proc/net/tcp6 2>/dev/null \
        | awk -v p="$port_hex" '{ n = split($2, a, ":"); if (a[n] == p && $4 == "0A") f = 1 } END { exit !f }'; then
        ready=1
        break
    fi
    sleep 3
done
if [ "$ready" = 1 ]; then
    say "✓ Listening on ${PORT}/tcp."
else
    docker logs --tail 20 freepbx-tunnel-server 2>&1 || true
    die "OpenVPN is not listening on ${PORT}/tcp. Its last lines are above."
fi

if [ "$NO_SECRET" = 0 ]; then
    public_ip=$(curl -fsS -m 8 https://api.ipify.org 2>/dev/null || echo ADDRESS-OF-THIS-SERVER)
    cat <<ROUTER

THE ROUTER'S HALF — paste into its terminal (RouterOS 7):

    /interface ovpn-client add name=ovpn-pbx connect-to=${public_ip} port=${PORT} \\
      protocol=tcp mode=ip user=${USER_NAME} password=${PASS} \\
      certificate=none verify-server-certificate=no auth=sha1 cipher=aes256-cbc \\
      add-default-route=no

  The password is kept in tunnel/users.

ROUTER
fi
