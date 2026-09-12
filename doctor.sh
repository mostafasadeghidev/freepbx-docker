#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# The checks that would otherwise need somebody who has seen this break before.
#
# Every test here is one that actually went wrong on a live installation. None
# of them changes anything: this reads, and says what it found.
#
#     ./doctor.sh
# ---------------------------------------------------------------------------
set -uo pipefail

cd "$(dirname "$0")"

PASS=0; FAIL=0; WARN=0
ok()   { printf '  \033[32m✓\033[0m %s\n' "$*"; PASS=$((PASS+1)); }
bad()  { printf '  \033[31m✗\033[0m %s\n' "$*"; FAIL=$((FAIL+1)); }
hmm()  { printf '  \033[33m!\033[0m %s\n' "$*"; WARN=$((WARN+1)); }
note() { printf '      %s\n' "$*"; }
head_() { printf '\n\033[1m%s\033[0m\n' "$*"; }

dex() { docker compose exec -T freepbx "$@" 2>/dev/null; }

# --- is it even here --------------------------------------------------------

head_ "The container"

if ! command -v docker >/dev/null 2>&1; then
    bad "Docker is not installed."
    exit 1
fi

state=$(docker inspect -f '{{.State.Status}}' freepbx 2>/dev/null || echo "missing")
case "$state" in
    running) ok "freepbx is running" ;;
    missing) bad "There is no container called freepbx. Start it: docker compose up -d"; exit 1 ;;
    *)       bad "freepbx is $state"; note "docker compose logs --tail 50 freepbx"; exit 1 ;;
esac

health=$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' freepbx 2>/dev/null)
case "$health" in
    healthy)  ok "healthcheck passes" ;;
    starting) hmm "still starting — the first install takes 20-40 minutes" ;;
    none)     hmm "no healthcheck on this container" ;;
    *)        bad "healthcheck says $health" ;;
esac

if dex test -f /data/.freepbx-installed; then
    ok "FreePBX is installed ($(dex cat /data/.freepbx-installed | tr -d '\r\n'))"
else
    bad "The install has not finished."
    note "docker compose logs -f freepbx"
    exit 1
fi

# --- the fault that hides behind every other fault --------------------------

head_ "Names and numbers"

# DNS first, always. A PBX that cannot resolve its provider's hostname
# registers nothing, and every symptom points somewhere else: the trunk shows
# "Rejected", a probe by IP from the same container answers fine, and an hour
# goes by before anybody checks the one thing underneath.
if dex getent hosts mirror.freepbx.org >/dev/null; then
    ok "DNS works inside the container"
else
    bad "The container cannot resolve names."
    note "This is the fault that looks like everything else. See the README, DNS."
    note "Check that ./resolv.conf is mounted: docker compose exec freepbx cat /etc/resolv.conf"
fi

if dex asterisk -rx 'core show version' | grep -qi asterisk; then
    ok "Asterisk is answering ($(dex asterisk -rx 'core show version' | head -1 | cut -d' ' -f1-2))"
else
    bad "Asterisk is not answering."
    note "docker compose exec freepbx systemctl status asterisk"
fi

# --- the fault that makes calls silent --------------------------------------

head_ "NAT — the reason one side hears nothing"

ext_ip=$(dex asterisk -rx 'pjsip show settings' | grep -i 'external_media_address' | head -1 | awk '{print $NF}')
if [ -n "${ext_ip:-}" ] && [ "$ext_ip" != "(null)" ] && [ "$ext_ip" != "0.0.0.0" ]; then
    ok "Asterisk knows an external address: $ext_ip"
else
    hmm "No external address is set."
    note "Settings → Asterisk SIP Settings → NAT Settings → External Address."
    note "Without it calls connect and one side hears silence."
fi

# The RTP range FreePBX believes in, against the ports Docker actually
# publishes. These two drift apart the moment somebody widens one of them, and
# the symptom is one-way audio on the calls that land outside the overlap.
conf_start=$(dex sh -c "grep -h '^rtpstart' /etc/asterisk/rtp.conf 2>/dev/null | head -1 | cut -d= -f2 | tr -d ' \r'")
conf_end=$(dex sh -c "grep -h '^rtpend' /etc/asterisk/rtp.conf 2>/dev/null | head -1 | cut -d= -f2 | tr -d ' \r'")
env_start=$(grep -E '^RTP_START=' .env 2>/dev/null | cut -d= -f2 | tr -d ' \r')
env_end=$(grep -E '^RTP_END=' .env 2>/dev/null | cut -d= -f2 | tr -d ' \r')
env_start=${env_start:-10000}
env_end=${env_end:-10039}

if [ -z "${conf_start:-}" ]; then
    hmm "Could not read the RTP range from /etc/asterisk/rtp.conf"
elif [ "$conf_start" = "$env_start" ] && [ "$conf_end" = "$env_end" ]; then
    ok "RTP range agrees: $conf_start-$conf_end in FreePBX and in .env"
else
    bad "RTP range does NOT agree: FreePBX says $conf_start-$conf_end, .env says $env_start-$env_end"
    note "Calls that pick a port outside the overlap have audio one way only."
    note "Settings → Asterisk SIP Settings → RTP Port Ranges."
fi

published=$(docker port freepbx 2>/dev/null | grep -c '/udp' || true)
want=$(( env_end - env_start + 1 + 1 ))   # the RTP ports plus SIP/udp
if [ "$published" -ge "$want" ]; then
    ok "$published UDP ports are published"
else
    hmm "$published UDP ports published, expected about $want"
    note "docker compose up -d   after changing the range in .env"
fi

# --- the module that breaks the machine it protects -------------------------

head_ "The FreePBX firewall module"

fw=$(dex fwconsole firewall status 2>/dev/null | head -1)
case "$fw" in
    *[Dd]isabled*) ok "disabled — which is right inside a container" ;;
    "")            hmm "could not read its state" ;;
    *)             bad "it is enabled: $fw"
                   note "In a container it wipes Docker's DNS rule and silently drops"
                   note "legitimate telephones after a few minutes. Set PBX_FIREWALL=off"
                   note "in pbx.env and restart. fail2ban is separate and stays on." ;;
esac

# --- what it is carrying ----------------------------------------------------

head_ "What is on it"

exts=$(dex asterisk -rx 'pjsip show endpoints' | grep -c '^ Endpoint:' || echo 0)
regs=$(dex asterisk -rx 'pjsip show registrations' | grep -ci 'Registered' || echo 0)
calls=$(dex asterisk -rx 'core show channels' | grep -oE '[0-9]+ active call' | head -1)
printf '      extensions and trunks configured: %s\n' "${exts:-0}"
printf '      trunk registrations up:           %s\n' "${regs:-0}"
printf '      %s\n' "${calls:-no call count}"

if [ "${regs:-0}" = "0" ] && [ "${exts:-0}" != "0" ]; then
    hmm "No trunk is registered — outside calls will not work."
    note "docker compose exec freepbx asterisk -rx 'pjsip show registrations'"
fi

# --- the copy that is not on this machine -----------------------------------

head_ "If this server disappeared tonight"

if docker image inspect freepbx17-official:installed >/dev/null 2>&1; then
    ok "An installed image exists here (freepbx17-official:installed)"
else
    hmm "No snapshot image. ./snapshot.sh makes one — read the README first."
    note "Without it, a recreate of this container throws the installed software away."
fi

data_kb=$(du -sk ./data 2>/dev/null | cut -f1)
if [ -n "${data_kb:-}" ]; then
    printf '      data folder: %s MB\n' "$(( data_kb / 1024 ))"
fi
hmm "Nothing here can tell whether a backup left this machine."
note "That is the one check a server cannot do about itself. Take a copy off it."

# --- the verdict ------------------------------------------------------------

printf '\n\033[1m%s passed, %s warnings, %s failed\033[0m\n' "$PASS" "$WARN" "$FAIL"
[ "$FAIL" -eq 0 ]
