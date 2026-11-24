#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Debian's security updates inside the container, and nothing else — then the
# restart that actually loads them, a check that the panel answers, and a
# snapshot so a recreate does not undo it.
#
# Written the day PHP shipped 8.2.35 for two unauthenticated remote-code-
# execution holes (CVE-2026-109618, CVE-2026-109619, "php2shell", 2026-10-21),
# on a live install running 8.2.34. Two things went wrong that nothing in the
# kit said:
#
#   1. Apache keeps the old PHP in memory. mod_php is loaded once, into the
#      parent process. Neither `apache2ctl graceful` nor `apache2ctl restart`
#      replaces that process (same PID), so the new 8.2.35 extensions on disk
#      were loaded into the old 8.2.34 core and refused:
#
#          Unable to load dynamic library 'mbstring.so' ... undefined symbol
#
#      and every page of the panel answered 500. Only `systemctl restart
#      apache2` — a new parent — fixed it. This script does that, and then
#      asks PHP itself, through Apache, which version it is.
#
#   2. `apt-get upgrade` is not "security updates". Asterisk and FreePBX come
#      from Sangoma's repository (deb.freepbx.org) and are upgraded the
#      FreePBX way (`fwconsole ma upgradeall`), not by apt behind its back.
#      Only packages whose new version comes from Debian-Security are taken.
#
#     ./security-update.sh            # list what would change, then do it
#     DRY_RUN=1 ./security-update.sh  # list only
#     FORCE=1 ./security-update.sh    # even with calls in progress (they may drop)
#
# Data is not touched: it lives in ./data. The software is, which is why the
# snapshot at the end matters — see snapshot.sh.
# ---------------------------------------------------------------------------
set -euo pipefail

cd "$(dirname "$0")"

CONTAINER="${CONTAINER:-freepbx}"
DRY_RUN="${DRY_RUN:-0}"
FORCE="${FORCE:-0}"

dex() { docker exec "$CONTAINER" "$@"; }

if [ "$(docker inspect -f '{{.State.Status}}' "$CONTAINER" 2>/dev/null || echo missing)" != running ]; then
    echo "The container '$CONTAINER' is not running." >&2
    exit 1
fi

# A package upgrade restarts Apache, and the snapshot pauses the PBX: not during a call.
calls=$(dex asterisk -rx 'core show channels count' 2>/dev/null | awk '/active call/{print $1}')
if [ "${calls:-0}" != 0 ] && [ "$FORCE" != 1 ]; then
    echo "$calls call(s) in progress. Try again when the line is quiet, or FORCE=1." >&2
    exit 1
fi

echo "Reading Debian's package lists…"
dex env DEBIAN_FRONTEND=noninteractive apt-get update -qq

# `Inst php8.2-common [8.2.34-1~deb12u1] (8.2.35-1~deb12u1 Debian-Security:12/stable-security [amd64])`
plan=$(dex apt-get -s upgrade 2>/dev/null | grep '^Inst ' | grep 'Debian-Security' || true)
if [ -z "$plan" ]; then
    echo "No security updates from Debian. Nothing to do."
    exit 0
fi
pkgs=$(printf '%s\n' "$plan" | awk '{print $2}' | tr '\n' ' ')

echo
echo "Security updates from Debian:"
printf '%s\n' "$plan" | awk '{gsub(/[][()]/,""); printf "  %-32s %s -> %s\n", $2, $3, $4}'
echo
if [ "$DRY_RUN" = 1 ]; then
    echo "(DRY_RUN=1: nothing was changed.)"
    exit 0
fi

before=$(dex php -r 'echo PHP_VERSION;' 2>/dev/null || echo none)

dex env DEBIAN_FRONTEND=noninteractive apt-get install -y --only-upgrade \
    -o Dpkg::Options::=--force-confold $pkgs

# A new parent process, not a reload — see the top of this file.
echo
echo "Restarting Apache (systemctl, so the new PHP is what it loads)…"
dex systemctl restart apache2
sleep 3

# Everything else that still runs the old code. This image's policy-rc.d
# answers 101, so no package restarts its own service: after 68 upgraded
# packages, MariaDB, HAProxy and rsyslog were still the old binaries while apt
# said all was well (measured). The processes are asked directly — which ones
# still map a binary or library the install deleted — and their systemd units
# restarted. Not Asterisk or FreePBX: that drops the calls, so they are named
# and left for a quiet moment (`fwconsole restart`).
echo
echo "Restarting the services still running the old files…"
docker exec -i "$CONTAINER" sh -s <<'SCAN'
stale() {
  for m in /proc/[0-9]*/maps; do
    p=${m#/proc/}; p=${p%/maps}
    [ "$p" = 1 ] && continue
    grep -qE '/(usr/)?(s?bin|lib|lib64|libexec)/[^ ]* [(]deleted[)]$' "$m" 2>/dev/null || continue
    u=$(awk -F/ '{for(i=1;i<=NF;i++) if ($i ~ /[.]service$/) {print $i; exit}}' /proc/$p/cgroup 2>/dev/null)
    if [ -n "$u" ]; then echo "u $u"; else echo "p $(cat /proc/$p/comm 2>/dev/null)"; fi
  done | sort -u
}
stale | while read kind name; do
  case "$name" in
    asterisk*|freepbx*) echo "  still the old libraries, left for a quiet moment (a restart drops the calls): $name"; continue ;;
    systemd-*|dbus*|user@*) continue ;;
  esac
  [ "$kind" = u ] || { echo "  still the old files, not a service: $name"; continue; }
  if systemctl restart "$name" && systemctl is-active --quiet "$name"; then echo "  restarted: $name"; else echo "  NOT running after the restart: $name"; fi
done
SCAN

# PHP through Apache, not the CLI: the CLI was right all along while the web was not.
probe=/var/www/html/.security-update-probe.php
printf '%s' '<?php echo PHP_VERSION, " ", extension_loaded("pdo_mysql") && extension_loaded("mbstring") ? "ok" : "missing-extensions";' \
    | docker exec -i "$CONTAINER" sh -c "cat > $probe"
web=$(dex curl -s --max-time 20 http://127.0.0.1/.security-update-probe.php || true)
dex rm -f "$probe"
panel=$(dex curl -s -o /dev/null -w '%{http_code}' --max-time 30 http://127.0.0.1/admin/config.php || true)
cli=$(dex php -r 'echo PHP_VERSION;' 2>/dev/null || echo none)

echo "PHP before: $before   now (CLI): $cli   through Apache: ${web:-no answer}"
echo "Panel (/admin/config.php): $panel"

if [ "${web#"$cli" }" != ok ] || [ "$panel" != 200 ]; then
    echo >&2
    echo "The panel is not answering as it should. The snapshot was NOT taken." >&2
    echo "Look at:  docker exec $CONTAINER tail -n 30 /var/log/apache2/error.log" >&2
    exit 1
fi

echo
./snapshot.sh
echo
echo "Done. Recreating the container now starts from the updated image."
