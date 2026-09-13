#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Sourced, not run. Answers one question before anything recreates the
# telephone container: would the new one still have FreePBX in it?
#
# The installer writes mariadb, apache, Asterisk and fwconsole into the
# container's own filesystem, and `docker compose up -d` recreates a container
# from its IMAGE — so a recreate from the build image erases the install while
# ./data still says "installed". Measured on this kit's first clean-server test:
#
#     Failed to start mariadb.service: Unit mariadb.service not found.
#
# `docker diff` alone is not the answer. Straight after setup.sh the container
# still runs the build image (its diff shows fwconsole Added) while .env already
# names the snapshot, and a recreate from that is safe. So the image a recreate
# would use is looked inside too: a throwaway `docker run` with no network, no
# pull and no stdin. `test -L || test -e`, not `test -x`: in the snapshot
# fwconsole is a symlink into /var/lib/asterisk, a bind mount, so in a bare run
# it dangles — measured, `test -x` said "missing" about the image that had it.
# ---------------------------------------------------------------------------

# True (0) when recreating `freepbx` now would erase its installation.
# Callers source .env first, so compose sees the same file list they will use.
recreate_erases_install() {
    local diff next cur nid
    diff="$(docker diff freepbx 2>/dev/null || true)"
    # No container, or nothing that exists only in it: nothing to lose.
    grep -qx 'A /usr/sbin/fwconsole' <<<"$diff" || return 1

    # The freepbx service has no dependencies, so compose names one image.
    next="$(docker compose config --images freepbx 2>/dev/null </dev/null || true)"
    next="${next%%$'\n'*}"
    [ -n "$next" ] || next="${PBX_IMAGE:-freepbx17-official:local}"

    cur="$(docker inspect -f '{{.Image}}' freepbx 2>/dev/null || true)"
    nid="$(docker image inspect -f '{{.Id}}' "$next" 2>/dev/null || true)"
    # Missing (compose would build one) or the very image it runs now: erased.
    if [ -z "$nid" ] || [ "$nid" = "$cur" ]; then
        return 0
    fi
    if docker run --rm --pull never --network none --entrypoint sh "$next" \
        -c 'test -L /usr/sbin/fwconsole || test -e /usr/sbin/fwconsole' </dev/null >/dev/null 2>&1; then
        return 1
    fi
    return 0
}
