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
#
# And that image is looked inside even when it carries the snapshot's name. The
# first version stopped as soon as the container ran from the snapshot — its
# diff has no fwconsole, because the image does — and called that safe. But a
# `docker compose build` (or `up -d --build`) builds a fresh, empty image and
# gives it the snapshot's name. Measured with throwaway containers shaped like
# this kit, on Docker 29: the old check said "safe", `up -d` followed, and
# fwconsole was gone.
#
# The same measurement is why "is FreePBX in the container now?" is asked of
# the running container itself. With Docker 29's containerd image store the
# image a container was made from stops existing the moment its name moves —
# `docker run <its id>` answers "No such image" — so there was nothing left to
# look inside, and every check that looked there said "nothing installed".
# ---------------------------------------------------------------------------

# True (0) when recreating `freepbx` now would erase its installation.
# Callers source .env first, so compose sees the same file list they will use.
recreate_erases_install() {
    local cur diff next nid in_layer=0 installed=0
    cur="$(docker inspect -f '{{.Image}}' freepbx 2>/dev/null || true)"
    # No container: nothing to lose.
    [ -n "$cur" ] || return 1

    # fwconsole Added in the container's own layer: the install lives in what
    # a recreate throws away.
    diff="$(docker diff freepbx 2>/dev/null || true)"
    grep -qx 'A /usr/sbin/fwconsole' <<<"$diff" && in_layer=1

    # Is FreePBX in the container at all? A running one is simply asked. A
    # stopped one is judged by its layer and its image, and when neither can
    # answer (its image gone) it is assumed to hold something worth keeping.
    if [ "$(docker inspect -f '{{.State.Running}}' freepbx 2>/dev/null)" = true ]; then
        docker exec freepbx sh -c 'test -L /usr/sbin/fwconsole || test -e /usr/sbin/fwconsole' \
            </dev/null >/dev/null 2>&1 && installed=1
    elif [ "$in_layer" = 1 ] || kit_image_has_fwconsole "$cur"; then
        installed=1
    elif ! docker image inspect "$cur" >/dev/null 2>&1; then
        installed=1
    fi
    # Nothing installed yet: nothing to lose.
    [ "$installed" = 1 ] || return 1

    # The freepbx service has no dependencies, so compose names one image.
    next="$(docker compose config --images freepbx 2>/dev/null </dev/null || true)"
    next="${next%%$'\n'*}"
    [ -n "$next" ] || next="${PBX_IMAGE:-freepbx17-official:local}"

    nid="$(docker image inspect -f '{{.Id}}' "$next" 2>/dev/null || true)"
    # Missing: compose would build a fresh, empty one under that name.
    [ -n "$nid" ] || return 0
    # The very image it runs now: safe only when the install is in that image
    # rather than in the layer a recreate throws away.
    if [ "$nid" = "$cur" ]; then
        [ "$in_layer" = 1 ] && return 0
        return 1
    fi
    # Anything else must have FreePBX in it — whatever name it goes by.
    kit_image_has_fwconsole "$nid" && return 1
    return 0
}

# Does this image (a name or an id) have fwconsole in it? See the header for
# why the test is `-L || -e`. An image that no longer exists answers no.
kit_image_has_fwconsole() {
    docker run --rm --pull never --network none --entrypoint sh "$1" \
        -c 'test -L /usr/sbin/fwconsole || test -e /usr/sbin/fwconsole' </dev/null >/dev/null 2>&1
}
