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
# ---------------------------------------------------------------------------
set -euo pipefail

cd "$(dirname "$0")"

ASSUME_YES=0
DRY_RUN=0
for arg in "$@"; do
    case "$arg" in
        -y|--yes)  ASSUME_YES=1 ;;
        -n|--show) DRY_RUN=1 ;;
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
    local prompt="$1" default="$2" reply=""
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

EXTENSIONS=$(ask "How many extensions (telephones) will this serve?" "20")
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
PANEL_BIND=$(ask "Publish the panel on which address?" "127.0.0.1")
PANEL_PORT=$(ask "On which port?" "8088")

say ""
SIP_PORT=$(ask "SIP port (the one telephones register to)" "5060")
TZ_GUESS=$(cat /etc/timezone 2>/dev/null || echo "UTC")
PBX_TZ=$(ask "Time zone" "$TZ_GUESS")
PBX_DOMAIN=$(ask "Domain name for this PBX (any name; the installer needs one)" "local")

say ""
say "A tunnel is only for a PBX abroad whose telephone provider will not talk"
say "to a foreign address. If that is not your situation, answer no."
WANT_TUNNEL=$(ask "Use a tunnel?" "no")
PROFILES=""
case "$WANT_TUNNEL" in
    y|yes|Y|YES) PROFILES="tunnel" ;;
esac

# --- write it down ----------------------------------------------------------

step "Settings"
printf '  extensions   %s  (RTP %s-%s, %s ports)\n' "$EXTENSIONS" "$RTP_START" "$RTP_END" "$(( RTP_END - RTP_START + 1 ))"
printf '  panel        %s:%s\n' "$PANEL_BIND" "$PANEL_PORT"
printf '  SIP          %s\n' "$SIP_PORT"
printf '  time zone    %s\n' "$PBX_TZ"
printf '  tunnel       %s\n' "${PROFILES:-no}"

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
    .env.example > .env

sed -e "s/^PBX_DOMAIN=.*/PBX_DOMAIN=${PBX_DOMAIN}/" \
    -e "s#^TZ=.*#TZ=${PBX_TZ}#" \
    pbx.env.example > pbx.env

say ""
say "Wrote .env and pbx.env"

if [ "$PROFILES" = "tunnel" ] && [ ! -f tunnel/client.ovpn ]; then
    warn "The tunnel is on but tunnel/client.ovpn is missing."
    warn "Put your provider's .ovpn file there before the PBX needs it — see tunnel/README.md."
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

# --- what is left for a person ---------------------------------------------

step "Done — and three things only you can do"
cat <<'NEXT'

1. OPEN THE PANEL and create the administrator account.
   The first person to open it becomes admin, so do this now, before the
   machine is reachable by anyone else.

2. TELL ASTERISK ITS PUBLIC ADDRESS.
   Settings → Asterisk SIP Settings → NAT Settings:
     External Address  = this server's public IP
     Local Networks    = the container network (docker network inspect)
   Get this wrong and calls connect with silence in one direction. It is the
   single most common fault in a PBX behind NAT.

3. SET THE RTP RANGE TO MATCH.
   Settings → Asterisk SIP Settings → RTP Port Ranges — the same numbers as
   RTP_START and RTP_END in .env. `./doctor.sh` checks that they agree.

Then add the provider's trunk and the extensions.

    ./doctor.sh          check the usual faults
    ./snapshot.sh        ⚠️ run this once it works — read the README first

NEXT
docker compose ps
