#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# One command, on a server that has nothing but Docker.
#
# Asks the handful of things that differ from one installation to the next,
# writes `.env` and `pbx.env`, and starts the install. Everything it asks has
# a default that is right for a small office, so pressing Enter through it is
# a valid way to use this script.
#
# It is deliberately not clever. It does not install Docker, open firewalls or
# buy domains — each of those is somebody's policy, not a detail to guess. It
# tells you when one is missing and stops.
#
#     ./setup.sh              ask, then install
#     ./setup.sh --yes        take every default, ask nothing
#     ./setup.sh --show       print what it would write, change nothing
#     ./setup.sh --prepare    write the files and check the ports, start nothing
#
# ## Answering without a keyboard
#
# Every question can be answered in the environment instead, which is how a
# tool installs this without guessing the order of the questions:
#
#     SETUP_EXTENSIONS=50 SETUP_TUNNEL=listen SETUP_OPERATOR_NET=203.0.113.0/24 \
#       ./setup.sh --yes
#
#   SETUP_EXTENSIONS    SETUP_PANEL_BIND   SETUP_PANEL_PORT   SETUP_SIP_PORT
#   SETUP_TZ            SETUP_DOMAIN       SETUP_COOLIFY      SETUP_PANEL_DOMAIN
#   SETUP_TUNNEL        SETUP_TUNNEL_PORT  SETUP_OPERATOR_NET
#
# A variable that is set answers its question; one that is not falls back to
# the keyboard, or with --yes to the default. Every answer is still validated.
# ---------------------------------------------------------------------------
set -euo pipefail

cd "$(dirname "$0")"

ASSUME_YES=0
DRY_RUN=0
PREPARE_ONLY=0
for arg in "$@"; do
    case "$arg" in
        -y|--yes)  ASSUME_YES=1 ;;
        -n|--show) DRY_RUN=1 ;;
        -p|--prepare) PREPARE_ONLY=1 ;;
        -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
        *) echo "unknown option: $arg (try --help)" >&2; exit 2 ;;
    esac
done

say()  { printf '%s\n' "$*"; }
step() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[33m!  %s\033[0m\n' "$*" >&2; }
die()  { printf '\033[31m✗  %s\033[0m\n' "$*" >&2; exit 1; }

# `ask <prompt> <default>` — one answer on stdout, the default under --yes.
#
# Read from stdin, plainly. This script is run as a file (it starts by cd-ing
# to its own directory), so stdin is free: a person types the answers, and a
# pipe can supply them, which is how the flow above is tested. An empty answer
# and the end of a pipe both mean the default.
#
# The prompt goes to stderr so that stdout carries the answer and nothing else.
ask() {
    local prompt="$1" default="$2" var="${3:-}" reply=""
    # An answer given in the environment wins over both the keyboard and the
    # default — see "Answering without a keyboard" at the top.
    if [ -n "$var" ] && [ -n "${!var+x}" ]; then
        printf '%s\n' "${!var}"
        return
    fi
    if [ "$ASSUME_YES" = 1 ]; then
        printf '%s\n' "$default"
        return
    fi
    printf '%s [%s]: ' "$prompt" "$default" >&2
    read -r reply || true
    printf '\n' >&2
    printf '%s\n' "${reply:-$default}"
}

# --- what has to be here already -------------------------------------------

step "Checking the machine"

command -v docker >/dev/null 2>&1 || die \
    "Docker is not installed. Install it first: https://docs.docker.com/engine/install/"

docker compose version >/dev/null 2>&1 || die \
    "This is Docker without the compose plugin. Install docker-compose-plugin."

docker info >/dev/null 2>&1 || die \
    "Docker is installed but not answering. Is the daemon running, and may this user talk to it?"

say "Docker $(docker version --format '{{.Server.Version}}') with compose $(docker compose version --short)"

# systemd inside the container needs cgroup v2. Debian 12, Ubuntu 22.04 and
# anything newer have it; an older host is where the container starts and then
# sits there with no services.
if [ -d /sys/fs/cgroup ] && [ ! -f /sys/fs/cgroup/cgroup.controllers ]; then
    warn "This host looks like cgroup v1. FreePBX needs systemd in the container,"
    warn "which needs cgroup v2. Expect the container to start and do nothing."
fi

# The installer pulls several GB and the result is about 8 GB with its data.
free_gb=$(df -Pk . | awk 'NR==2 {print int($4/1024/1024)}')
if [ "${free_gb:-99}" -lt 12 ]; then
    warn "Only ${free_gb} GB free here. The install needs about 12 GB to be comfortable."
fi

if [ -f .env ] || [ -f pbx.env ]; then
    warn "There is already a .env or pbx.env here."
    [ "$(ask 'Overwrite them?' 'no')" = "yes" ] || die "Nothing was changed."
fi

# --- the questions ----------------------------------------------------------

step "A few questions"
say "Enter accepts the default. Nothing here is final — .env can be edited later."
say ""

EXTENSIONS=$(ask "How many extensions (telephones) will this serve?" "20" SETUP_EXTENSIONS)
case "$EXTENSIONS" in
    ''|*[!0-9]*) die "That is not a number: $EXTENSIONS" ;;
esac
[ "$EXTENSIONS" -ge 1 ] || die "At least one extension, surely."

# Two ports per simultaneous call, and a spare few. Publishing ports is what
# Docker is slow at, so this is kept to what the size actually needs rather
# than FreePBX's default ten thousand.
RTP_START=10000
RTP_END=$(( RTP_START + (EXTENSIONS * 2) - 1 ))
[ "$RTP_END" -lt $(( RTP_START + 39 )) ] && RTP_END=$(( RTP_START + 39 ))

say ""
say "The web panel. Leave it on 127.0.0.1 if anything else on this machine"
say "already serves HTTPS (Caddy, Nginx, Traefik, Coolify) — that proxy puts"
say "it on a domain. Answer 0.0.0.0 only to reach it directly, without HTTPS."
PANEL_BIND=$(ask "Publish the panel on which address?" "127.0.0.1" SETUP_PANEL_BIND)
PANEL_PORT=$(ask "On which port?" "8088" SETUP_PANEL_PORT)

say ""
SIP_PORT=$(ask "SIP port (the one telephones register to)" "5060" SETUP_SIP_PORT)
TZ_GUESS=$(cat /etc/timezone 2>/dev/null || echo "UTC")
PBX_TZ=$(ask "Time zone" "$TZ_GUESS" SETUP_TZ)
PBX_DOMAIN=$(ask "Domain name for this PBX (any name; the installer needs one)" "local" SETUP_DOMAIN)

# shellcheck source=scripts/ports.sh
. scripts/ports.sh

# --- Coolify ----------------------------------------------------------------
#
# Asked, with the answer guessed from what is running: Coolify's proxy is a
# container called coolify-proxy, and it holds 80, 443 and 443/udp. On such a
# machine the panel has to join Coolify's network to be reachable by its
# proxy at all — measured: a panel on 127.0.0.1 answers "Connection refused"
# from inside that proxy — and the tunnel must stay off 443.
COOLIFY_GUESS=no
docker ps --format '{{.Names}}' 2>/dev/null | grep -qx coolify-proxy && COOLIFY_GUESS=yes
say ""
say "Coolify's proxy owns ports 80 and 443 wherever it runs."
ON_COOLIFY=$(ask "Is Coolify running on this server?" "$COOLIFY_GUESS" SETUP_COOLIFY)
PANEL_DOMAIN=""
case "$ON_COOLIFY" in
    y|yes|Y|YES)
        ON_COOLIFY=yes
        PANEL_DOMAIN=$(ask "Domain for the web panel, served with HTTPS by Coolify's proxy" "" SETUP_PANEL_DOMAIN)
        [ -n "$PANEL_DOMAIN" ] || die "On a Coolify server the panel needs a domain name to be reachable."
        ;;
    *) ON_COOLIFY=no ;;
esac

# --- the tunnel -------------------------------------------------------------
#
# Two directions, and the right one depends on the far end, not on this
# server. A router on an office line or a SIM sits behind its provider's NAT —
# measured on a real one: both lines in 100.64.0.0/10 — so nothing can dial in
# to it, and this server has to be the one that listens. "dial" is only for a
# far end with a public address that handed you an .ovpn file.
say ""
say "A tunnel is only for a PBX abroad whose telephone provider will only talk"
say "to an address inside its own country. Most installations answer none."
say "  listen   a router over there dials in to this server   (the usual case)"
say "  dial     this server dials out to something with a public address"
TUNNEL_MODE=$(ask "Tunnel: none, listen or dial" "none" SETUP_TUNNEL)
PROFILES=""
TUNNEL_PORT=1194
OPERATOR_NET=""
case "$TUNNEL_MODE" in
    listen)
        # The default is a port nobody here holds, found rather than assumed.
        suggested="$(free_tunnel_port || echo 1194)"
        TUNNEL_PORT=$(ask "Port the router dials in on (TCP)" "$suggested" SETUP_TUNNEL_PORT)
        case "$TUNNEL_PORT" in ''|*[!0-9]*) die "That is not a port number: $TUNNEL_PORT" ;; esac
        OPERATOR_NET=$(ask "The operator's network, as address/bits (e.g. 203.0.113.0/24)" "" SETUP_OPERATOR_NET)
        printf '%s' "$OPERATOR_NET" | grep -qE '^([0-9]{1,3}\.){3}[0-9]{1,3}/([0-9]|[12][0-9]|3[0-2])$' \
            || die "Give the operator's network as address/bits, like 203.0.113.0/24."
        ;;
    dial) PROFILES="tunnel" ;;
    *) TUNNEL_MODE=none ;;
esac

# Which compose files make up this installation, written into .env so that a
# plain `docker compose …` — by a person, by doctor.sh, or by any tool that
# reads the project — always uses the whole set. Leaving one out is not
# harmless: `up -d` without the tunnel file removes the tunnel.
COMPOSE_FILES="compose.yml"
[ "$ON_COOLIFY" = yes ] && COMPOSE_FILES="$COMPOSE_FILES:compose.coolify.yml"
[ "$TUNNEL_MODE" = listen ] && COMPOSE_FILES="$COMPOSE_FILES:compose.tunnel-server.yml"

# --- write it down ----------------------------------------------------------

step "Settings"
printf '  extensions   %s  (RTP %s-%s, %s ports)\n' "$EXTENSIONS" "$RTP_START" "$RTP_END" "$(( RTP_END - RTP_START + 1 ))"
printf '  panel        %s:%s\n' "$PANEL_BIND" "$PANEL_PORT"
printf '  SIP          %s\n' "$SIP_PORT"
printf '  time zone    %s\n' "$PBX_TZ"
printf '  coolify      %s%s\n' "$ON_COOLIFY" "${PANEL_DOMAIN:+  (panel on https://$PANEL_DOMAIN)}"
case "$TUNNEL_MODE" in
    listen) printf '  tunnel       listen on %s/tcp, operator network %s\n' "$TUNNEL_PORT" "$OPERATOR_NET" ;;
    dial)   printf '  tunnel       dial out (tunnel/client.ovpn)\n' ;;
    *)      printf '  tunnel       none\n' ;;
esac
printf '  files        %s\n' "$COMPOSE_FILES"

if [ "$DRY_RUN" = 1 ]; then
    say ""
    say "--show: nothing was written."
    exit 0
fi

# Built from the templates rather than written from scratch, so the comments
# that explain each setting — and the traps they name — travel with it.
sed -e "s/^RTP_START=.*/RTP_START=${RTP_START}/" \
    -e "s/^RTP_END=.*/RTP_END=${RTP_END}/" \
    -e "s/^PANEL_BIND=.*/PANEL_BIND=${PANEL_BIND}/" \
    -e "s/^PANEL_PORT=.*/PANEL_PORT=${PANEL_PORT}/" \
    -e "s/^SIP_PORT=.*/SIP_PORT=${SIP_PORT}/" \
    -e "s/^COMPOSE_PROFILES=.*/COMPOSE_PROFILES=${PROFILES}/" \
    -e "s#^COMPOSE_FILE=.*#COMPOSE_FILE=${COMPOSE_FILES}#" \
    -e "s/^TUNNEL_PORT=.*/TUNNEL_PORT=${TUNNEL_PORT}/" \
    -e "s/^PANEL_DOMAIN=.*/PANEL_DOMAIN=${PANEL_DOMAIN}/" \
    .env.example > .env

sed -e "s/^PBX_DOMAIN=.*/PBX_DOMAIN=${PBX_DOMAIN}/" \
    -e "s#^TZ=.*#TZ=${PBX_TZ}#" \
    pbx.env.example > pbx.env

say ""
say "Wrote .env and pbx.env"

if [ "$TUNNEL_MODE" = dial ] && [ ! -f tunnel/client.ovpn ]; then
    warn "The tunnel is on but tunnel/client.ovpn is missing."
    warn "Put your provider's .ovpn file there before the PBX needs it — see tunnel/README.md."
fi

# --- the listening end, made rather than described -------------------------

TUNNEL_PASS=""
if [ "$TUNNEL_MODE" = listen ]; then
    step "Preparing the tunnel"
    # The same script that adds a tunnel to a running installation, so the two
    # paths cannot drift apart. It keeps a password that already exists.
    ./tunnel/listen.sh --write-only --net "$OPERATOR_NET" --port "$TUNNEL_PORT" --user router
    TUNNEL_PASS="$(awk -F: '$1 == "router" { sub(/^[^:]*:/, ""); print; exit }' tunnel/users)"
fi

# --- nothing starts until nothing clashes ----------------------------------
#
# Checked before `up`, not discovered by it. Measured on a Coolify machine: a
# port that is already held makes compose recreate the telephone container and
# then fail to start the new one — the system goes down and stays down. See
# scripts/ports.sh.
step "Checking ports"
set -a
# shellcheck disable=SC1091
. ./.env
set +a
if ! conflicts="$(kit_wanted_ports | ports_conflicts)"; then
    printf '%s\n' "$conflicts" | while read -r label proto port who; do
        warn "$label $port/$proto is already held by ${who#*:}"
    done
    die "Change those in .env, then run ./apply.sh. Nothing was started."
fi
say "No clashes."

if [ "$PREPARE_ONLY" = 1 ]; then
    say ""
    say "--prepare: everything is written and the ports are free. Start it with ./apply.sh"
    exit 0
fi

# --- build and start --------------------------------------------------------

step "Starting"
say "The first run downloads several GB and installs FreePBX inside the"
say "container. It takes 20 to 40 minutes and prints nothing much while it"
say "does. That is normal — the log below is the real progress."
say ""

docker compose up -d --build

step "Installing"
say "Following the installer. Ctrl-C stops watching, not the install."
say ""

# The stamp file is written by scripts/bootstrap.sh the moment the installer
# returns, so it is the one honest signal that this is finished.
started=$(date +%s)
while true; do
    if docker compose exec -T freepbx test -f /data/.freepbx-installed 2>/dev/null; then
        break
    fi
    if ! docker compose ps --status running --quiet freepbx >/dev/null 2>&1; then
        warn "The container is not running. Its last words:"
        docker compose logs --tail 40 freepbx || true
        die "Install did not finish. Fix what that says, then run: docker compose up -d"
    fi
    # One line that rewrites itself on a terminal, one line per minute in a
    # log. `\r` in a redirected file is not a moving line, it is sixty copies
    # of the same sentence — measured, on the first real install.
    mins=$(( ( $(date +%s) - started ) / 60 ))
    if [ -t 1 ]; then
        printf '\r  installing… %s minutes' "$mins"
    elif [ "$mins" != "${said:-}" ]; then
        printf '  installing… %s minutes\n' "$mins"
        said=$mins
    fi
    sleep 20
done
printf '\r  installed in %s minutes.        \n' "$(( ( $(date +%s) - started ) / 60 ))"

# --- make it survive its own next start ------------------------------------

step "Making the install survivable"

# This is not an optimisation. Without it the next `docker compose up -d` —
# an override applied, a port changed, a Docker upgrade — recreates the
# container from the build image and the installed software is gone, while
# ./data still says "installed" so nothing reinstalls it.
#
# Measured on a clean Ubuntu 26.04 while testing this very kit: applying one
# compose override recreated the container, and the next boot said
#
#     Failed to start mariadb.service: Unit mariadb.service not found.
#
# fwconsole gone, Asterisk gone, and the documented way back is to wipe the
# data folder and install again from nothing. The README has warned about this
# since the beginning, and a kit that relies on somebody reading a warning has
# not solved it. So it happens here, now, before anything can recreate it.
say "The installer wrote its software into the container's filesystem, which"
say "any recreate rebuilds from the image. So the installed container becomes"
say "the image it starts from — otherwise the next 'up -d' erases it."
say ""

# `snapshot.sh` refuses a half-started install, and right after the installer
# returns the units are not always up yet.
for _ in $(seq 1 18); do
    up=1
    for unit in mariadb apache2 freepbx; do
        docker compose exec -T freepbx systemctl is-active --quiet "$unit" 2>/dev/null || up=0
    done
    [ "$up" = 1 ] && break
    sleep 10
done

if ./snapshot.sh; then
    sed -i "s#^PBX_IMAGE=.*#PBX_IMAGE=freepbx17-official:installed#" .env
    say ""
    say ".env now says PBX_IMAGE=freepbx17-official:installed"
    say "A recreate from here starts from the installed state, in seconds."
else
    warn "The snapshot did not run. Until it does, DO NOT run 'docker compose up -d'"
    warn "again — it would recreate the container and erase the install."
    warn "Fix what it said, then run: ./snapshot.sh"
fi

# --- the two settings that decide whether calls have sound -----------------
#
# A fresh FreePBX hands out voice ports 10000-20000 against the forty this kit
# publishes, and knows no public address — one-way audio on the first call.
# Both have one right answer on a machine set up this way, so they are set
# here rather than left on a list. See nat.sh.
step "Telling Asterisk its public address and its voice ports"
NAT_DONE=0
if ./nat.sh; then
    NAT_DONE=1
else
    warn "Not everything was set. Run ./nat.sh again once the PBX is up, or set it in the panel"
    warn "(Settings → Asterisk SIP Settings) — see item 2 below."
fi

# --- what is left for a person ---------------------------------------------

if [ "$NAT_DONE" = 1 ]; then
    step "Done — and one thing only you can do"
else
    step "Done — and two things only you can do"
fi
cat <<'NEXT'

1. OPEN THE PANEL and create the administrator account.
   The first person to open it becomes admin, so do this now, before the
   machine is reachable by anyone else.
NEXT

if [ "$NAT_DONE" != 1 ]; then
    cat <<'NEXT'

2. TELL ASTERISK ITS PUBLIC ADDRESS AND ITS VOICE PORTS — ./nat.sh does both,
   or in the panel: Settings → Asterisk SIP Settings →
     NAT Settings:     External Address = this server's public IP
     RTP Port Ranges:  the same numbers as RTP_START and RTP_END in .env
   Get either wrong and calls connect with silence in one direction.
NEXT
fi

cat <<'NEXT'

Then add the provider's trunk and the extensions. A trunk that runs through the
tunnel needs its own media address — see tunnel/README.md.

    ./doctor.sh          check the usual faults
    ./nat.sh --check     the public address and voice ports Asterisk has now
    ./snapshot.sh        ⚠️ run this once it works — read the README first

NEXT

# The router's half, with the real values — printed once, because the password
# was generated here and exists nowhere else but tunnel/users.
if [ "$TUNNEL_MODE" = listen ]; then
    public_ip=$(curl -fsS -m 8 https://api.ipify.org 2>/dev/null || echo ADDRESS-OF-THIS-SERVER)
    cat <<ROUTER
THE ROUTER'S HALF OF THE TUNNEL — paste into its terminal (RouterOS 7):

    /interface ovpn-client add name=ovpn-pbx connect-to=${public_ip} port=${TUNNEL_PORT} \\
      protocol=tcp mode=ip user=router password=${TUNNEL_PASS} \\
      certificate=none verify-server-certificate=no auth=sha1 cipher=aes256-cbc \\
      add-default-route=no

  The password is also in tunnel/users. This is the only time it is printed.
  If the operator only accepts one of the router's lines, see tunnel/README.md
  for the three lines that send its traffic out of that one.

ROUTER
fi

docker compose ps
