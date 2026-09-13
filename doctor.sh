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

# Read off the transport, not `pjsip show settings` — that command has no
# external_media_address field at all, so the first version of this check said
# "not set" on every system, configured or not. Measured on one machine: empty,
# then set through FreePBX and reloaded, then read back from the transport.
ext_ip=""
for t in $(dex asterisk -rx 'pjsip show transports' | awk '/^Transport:/ && $2 !~ /^</ {print $2}'); do
    v=$(dex asterisk -rx "pjsip show transport $t" | awk -F': *' '/external_media_address/ {print $2; exit}' | tr -d ' \r')
    if [ -n "$v" ]; then ext_ip="$v"; break; fi
done
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
#
# Read `rtp_additional.conf` as well: FreePBX owns the `_additional` files and
# `rtp.conf` only includes them, so the number that matters was in the file
# this check ignored — it said "could not read the range" while the range was
# plainly wrong. Measured on a clean install: FreePBX ships 10000-20000
# against the 40 ports the kit publishes, so this fails on every new machine
# until somebody fixes it. That is the point of it.
conf_start=$(dex sh -c "grep -hE '^rtpstart' /etc/asterisk/rtp_additional.conf /etc/asterisk/rtp.conf 2>/dev/null | head -1 | cut -d= -f2 | tr -d ' \r'")
conf_end=$(dex sh -c "grep -hE '^rtpend' /etc/asterisk/rtp_additional.conf /etc/asterisk/rtp.conf 2>/dev/null | head -1 | cut -d= -f2 | tr -d ' \r'")
env_start=$(grep -E '^RTP_START=' .env 2>/dev/null | cut -d= -f2 | tr -d ' \r')
env_end=$(grep -E '^RTP_END=' .env 2>/dev/null | cut -d= -f2 | tr -d ' \r')
env_start=${env_start:-10000}
env_end=${env_end:-10039}

if [ -z "${conf_start:-}" ]; then
    hmm "Could not read the RTP range from rtp_additional.conf or rtp.conf"
elif [ "$conf_start" = "$env_start" ] && [ "$conf_end" = "$env_end" ]; then
    ok "RTP range agrees: $conf_start-$conf_end in FreePBX and in .env"
else
    bad "RTP range does NOT agree: FreePBX says $conf_start-$conf_end, .env says $env_start-$env_end"
    note "Calls that pick a port outside the overlap have audio one way only."
    note "Settings → Asterisk SIP Settings → RTP Port Ranges."
fi

# Counted by container port, not by line: Docker lists every published port
# twice — once for 0.0.0.0 and once for [::] — and the first version of this
# reported 82 where 41 was right.
published=$(docker port freepbx 2>/dev/null | awk -F/ '/\/udp/ {print $1}' | sort -u | wc -l)
want=$(( env_end - env_start + 1 + 1 ))   # the RTP ports plus SIP/udp
if [ "$published" -ge "$want" ]; then
    ok "$published UDP ports are published"
else
    hmm "$published UDP ports published, expected about $want"
    note "docker compose up -d   after changing the range in .env"
fi

# --- ports somebody else holds ----------------------------------------------
#
# The check apply.sh enforces, reported here. It matters most after .env was
# edited and before it was applied: a clash found now is a warning, a clash
# found by `docker compose up -d` is a PBX that is down. Measured on a Coolify
# machine with TUNNEL_PORT=443 — the container was recreated and never started.

head_ "Ports in .env against everything else on this machine"

if [ -f scripts/ports.sh ] && [ -f .env ]; then
    # shellcheck source=scripts/ports.sh
    . scripts/ports.sh
    set -a
    # shellcheck disable=SC1091
    . ./.env
    set +a
    if clashes="$(kit_wanted_ports | ports_conflicts)"; then
        ok "nothing else holds a port this installation publishes"
    else
        printf '%s\n' "$clashes" | while read -r label proto port who; do
            bad "$label $port/$proto is held by ${who#*:}"
        done
        note "Change it in .env, then ./apply.sh — which checks before it touches anything."
    fi
else
    hmm "cannot check: scripts/ports.sh or .env is missing"
fi

# --- the module that breaks the machine it protects -------------------------

head_ "The FreePBX firewall module"

# Asked of netfilter, not of fwconsole.
#
# `fwconsole firewall status` is not a command on FreePBX 17 — it answers with
# its own usage text, and the first version of this check read that as "the
# firewall is enabled" and reported a fault on a clean machine. The module is
# always listed as "Enabled" by `fwconsole ma list`; that means installed, not
# running.
#
# What cannot be misread is whether it owns any rules. Measured on a clean
# install with PBX_FIREWALL=off: zero.
fw_rules=$(dex sh -c "iptables -S 2>/dev/null | grep -ciE 'fpbx'")
fw_flag=$(dex sh -c "test -e /etc/asterisk/firewall.enabled && echo on || echo off")
if [ "${fw_rules:-0}" -gt 0 ] || [ "$fw_flag" = "on" ]; then
    bad "it is active (${fw_rules:-0} rules, marker ${fw_flag})"
    note "In a container it wipes Docker's DNS rule and silently drops"
    note "legitimate telephones after a few minutes. Set PBX_FIREWALL=off"
    note "in pbx.env and restart. fail2ban is separate and stays on."
else
    ok "not active — which is right inside a container"
fi

# --- what it is carrying ----------------------------------------------------

head_ "What is on it"

# `grep -c` prints 0 and exits 1 when it matches nothing, so the `|| echo 0`
# after it printed the zero a second time — "0" then "0" on the report.
exts=$(dex asterisk -rx 'pjsip show endpoints' | grep -c '^ Endpoint:'; true)
regs=$(dex asterisk -rx 'pjsip show registrations' | grep -ci 'Registered'; true)
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

# Not a nicety: the software lives in the container's filesystem, and any
# recreate rebuilds that from whatever `PBX_IMAGE` names. If it still names
# the build image, the install is one `docker compose up -d` from gone — and
# ./data will still say "installed", so nothing reinstalls it.
#
# Measured while testing this kit: applying one compose override was enough.
# `Failed to start mariadb.service: Unit mariadb.service not found.`
env_image=$(grep -E '^PBX_IMAGE=' .env 2>/dev/null | cut -d= -f2 | tr -d ' 
')
if ! docker image inspect freepbx17-official:installed >/dev/null 2>&1; then
    bad "No snapshot image — this install is one 'docker compose up -d' from gone."
    note "Run ./snapshot.sh, then set PBX_IMAGE=freepbx17-official:installed in .env."
elif [ "${env_image:-}" = "freepbx17-official:installed" ]; then
    ok "A recreate is survivable (PBX_IMAGE points at the installed image)"
else
    bad "A snapshot exists but .env still says PBX_IMAGE=${env_image:-<unset>}"
    note "A recreate would start from the build image and erase the install."
    note "Set PBX_IMAGE=freepbx17-official:installed in .env."
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
