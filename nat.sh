#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Tell Asterisk the two things that decide whether a call has sound both ways:
# the address the world reaches this server on, and the voice ports that can
# actually arrive here.
#
#     ./nat.sh                      RTP range from .env, public address found online
#     ./nat.sh --address 203.0.113.7   that address instead
#     ./nat.sh --check              say what Asterisk has now, change nothing
#
# Written through FreePBX's own SIP settings module and a reload — the same two
# values Settings → Asterisk SIP Settings stores — so the panel shows them
# afterwards and nothing is edited behind FreePBX's back. Then read back from
# Asterisk itself, because a setting that never arrived looks exactly like one
# that did.
#
# ## Why it runs by itself
#
# Measured on a fresh install of this kit: FreePBX hands out RTP ports
# 10000-20000 and the container publishes forty of them, so every call that
# picks a port outside those forty has sound in one direction only. And with no
# external address the far end is told to send its sound to the container's
# private address. Both were items 2 and 3 of "things only you can do"; both
# have one right answer on a machine this kit set up.
#
# What it does NOT set: Local Networks, and a trunk's own media address. A
# trunk that runs through the tunnel needs its media on the tunnel address
# instead — that depends on the trunk, and see tunnel/README.md.
# ---------------------------------------------------------------------------
set -euo pipefail

cd "$(dirname "$0")"

ADDRESS=""
CHECK_ONLY=0
while [ $# -gt 0 ]; do
    case "$1" in
        --address) ADDRESS="${2:-}"; shift 2 ;;
        --check)   CHECK_ONLY=1; shift ;;
        -h|--help) sed -n '2,29p' "$0"; exit 0 ;;
        *) echo "unknown option: $1 (try --help)" >&2; exit 2 ;;
    esac
done

say() { printf '%s\n' "$*"; }
die() { printf '✗  %s\n' "$*" >&2; exit 1; }

[ -f .env ] || die "No .env here. Run ./setup.sh first."
set -a
# shellcheck disable=SC1091
. ./.env
set +a

RTP_START="${RTP_START:-10000}"
RTP_END="${RTP_END:-10039}"
case "$RTP_START$RTP_END" in ''|*[!0-9]*) die "RTP_START and RTP_END in .env must be numbers." ;; esac
[ "$RTP_START" -lt "$RTP_END" ] || die "RTP_START must be below RTP_END in .env."

is_ipv4() {
    printf '%s' "$1" | grep -qE '^([0-9]{1,3}\.){3}[0-9]{1,3}$' || return 1
    local IFS=.
    # shellcheck disable=SC2086
    set -- $1
    for o in "$@"; do [ "$o" -le 255 ] || return 1; done
}

dex() { docker compose exec -T freepbx "$@"; }

dex test -f /data/.freepbx-installed 2>/dev/null \
    || die "FreePBX is not installed and running here yet — nothing to tell."

# Asterisk, asked. `|| true` inside each read on purpose: right after a reload
# `asterisk -rx` fails for a moment (exit 255, measured), and under pipefail a
# failed read inside `$(…)` ends the whole script without a word.
ask() { dex asterisk -rx "$1" 2>/dev/null || true; }

wait_for_asterisk() {
    for _ in $(seq 1 30); do
        [ -n "$(ask 'core show version')" ] && return 0
        sleep 1
    done
    return 1
}

# What Asterisk itself has, not what the database says it should have.
read_back() {
    now_ports=$(ask 'rtp show settings' \
        | awk -F': *' '/Port start/ {s=$2} /Port end/ {e=$2} END {gsub(/[ \r]/, "", s); gsub(/[ \r]/, "", e); if (s != "") print s "-" e}')
    now_addr=""
    for t in $(ask 'pjsip show transports' | awk '/^Transport:/ && $2 !~ /^</ {print $2}'); do
        v=$(ask "pjsip show transport $t" | awk -F': *' '/external_media_address/ {print $2; exit}' | tr -d ' \r')
        if [ -n "$v" ]; then now_addr="$v"; break; fi
    done
}

wait_for_asterisk || die "Asterisk is not answering in the container."
read_back
if [ "$CHECK_ONLY" = 1 ]; then
    say "voice ports     ${now_ports:-unknown}   (.env publishes $RTP_START-$RTP_END)"
    say "public address  ${now_addr:-not set}"
    [ "$now_ports" = "$RTP_START-$RTP_END" ] && [ -n "$now_addr" ]
    exit
fi

if [ -z "$ADDRESS" ]; then
    ADDRESS=$(curl -fsS -m 8 https://api.ipify.org 2>/dev/null || curl -fsS -m 8 https://ifconfig.me 2>/dev/null || true)
    [ -n "$ADDRESS" ] && say "This server's public address, as the internet sees it: $ADDRESS"
fi
if [ -n "$ADDRESS" ] && ! is_ipv4 "$ADDRESS"; then
    die "Not an IPv4 address: $ADDRESS — give one with --address."
fi
[ -n "$ADDRESS" ] || say "! Could not find the public address — setting the voice ports only. Run again with --address."

say "Setting voice ports $RTP_START-$RTP_END${ADDRESS:+ and public address $ADDRESS}…"

# FreePBX's own module does the storing. `php` reads the script from stdin,
# and the values travel in the environment rather than inside the code.
dex env KIT_RTP_START="$RTP_START" KIT_RTP_END="$RTP_END" KIT_ADDRESS="$ADDRESS" php <<'PHP'
<?php
$bootstrap_settings['freepbx_auth'] = false;
include '/etc/freepbx.conf';
$s = FreePBX::Sipsettings();
$s->setConfig('rtpstart', getenv('KIT_RTP_START'));
$s->setConfig('rtpend', getenv('KIT_RTP_END'));
if (getenv('KIT_ADDRESS') !== '') {
    $s->setConfig('externip', getenv('KIT_ADDRESS'));
}
// Without this the process exits 151 even when everything worked — measured:
// FreePBX's bootstrap leaves that code behind for a script that simply ends.
exit(0);
PHP

# Stored is not applied: Asterisk only sees it once FreePBX rewrites its files.
dex fwconsole reload >/dev/null || die "fwconsole reload failed — the values are stored but Asterisk has not seen them."

# The reload returns before Asterisk has settled: ask until it says the new
# values, for up to half a minute, rather than judging the first answer.
wait_for_asterisk || true
for _ in $(seq 1 15); do
    read_back
    if [ "$now_ports" = "$RTP_START-$RTP_END" ] && { [ -z "$ADDRESS" ] || [ "$now_addr" = "$ADDRESS" ]; }; then
        break
    fi
    sleep 2
done
failed=0
if [ "$now_ports" = "$RTP_START-$RTP_END" ]; then
    say "✓ Asterisk hands out voice ports $now_ports"
else
    say "✗ Asterisk still says voice ports ${now_ports:-unknown}"
    failed=1
fi
if [ -n "$ADDRESS" ]; then
    if [ "$now_addr" = "$ADDRESS" ]; then
        say "✓ Asterisk tells the far end to send sound to $now_addr"
    else
        say "✗ Asterisk's external address is ${now_addr:-not set}, not $ADDRESS"
        failed=1
    fi
fi
exit "$failed"
