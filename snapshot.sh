#!/bin/bash
# ---------------------------------------------------------------------------
# Turn the installed container into an image, so recreating it is survivable.
#
# The problem this exists for, measured on a real install:
#
#   The volumes in compose.yml keep the data — the database, Asterisk's
#   config, the recordings. They do not keep the software. The official
#   installer writes mariadb, apache2, php, asterisk and their systemd units
#   into the container's own filesystem, and that filesystem is rebuilt from
#   the image every time `docker compose up` recreates the container. Pressing
#   "update" in a UI was enough.
#
#   What is left afterwards looks worse than a clean slate: ./data still holds
#   the "already installed" marker, so bootstrap.sh skips the install and tries
#   to start services that are no longer there —
#
#       Failed to start mariadb.service: Unit mariadb.service not found.
#
# Run this once, after the first install finishes. Then set
#   image: freepbx17-official:installed
# in compose.yml and comment out the `build:` block.
#
# Run it again after anything that changes the software rather than the data:
# `fwconsole ma upgradeall`, a Debian package upgrade, a module install.
# ---------------------------------------------------------------------------
set -euo pipefail

CONTAINER="${CONTAINER:-freepbx}"
IMAGE="${IMAGE:-freepbx17-official:installed}"

if ! docker inspect "$CONTAINER" >/dev/null 2>&1; then
    echo "No container named '$CONTAINER'. Start the project first." >&2
    exit 1
fi

# A snapshot of a half-finished install is worse than none: it would look
# complete and start nothing.
if ! docker exec "$CONTAINER" test -f /data/.freepbx-installed; then
    echo "The install has not finished — /data/.freepbx-installed is not there." >&2
    echo "Watch it with:  docker exec $CONTAINER tail -f /var/log/pbx/freepbx17-install-*.log" >&2
    exit 1
fi

for unit in mariadb apache2 freepbx; do
    if ! docker exec "$CONTAINER" systemctl is-active --quiet "$unit"; then
        echo "$unit is not running; refusing to snapshot a broken install." >&2
        exit 1
    fi
done

echo "Committing $CONTAINER -> $IMAGE (this takes a minute and pauses the PBX briefly)"
docker commit \
    --change 'CMD ["/sbin/init"]' \
    --change 'STOPSIGNAL SIGRTMIN+3' \
    "$CONTAINER" "$IMAGE"

echo
echo "Done. Now point the kit at it — one line in .env:"
echo "    PBX_IMAGE=$IMAGE"
echo "(./setup.sh writes that itself; this message is for a snapshot taken by hand,"
echo " after a module upgrade or a package upgrade.)"
echo
docker image ls "$IMAGE"
