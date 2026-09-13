#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Sourced, not run. Answers one question before anything is started: does
# somebody else already hold a port this kit is about to publish?
#
# ## Why this has to be asked first, not discovered
#
# Measured on a machine running Coolify, with TUNNEL_PORT=443:
#
#     Container freepbx-tunnel-server Recreated
#     Container freepbx Starting
#     Error response from daemon: ... Bind for :::443 failed: port is already allocated
#
# and then no freepbx container at all. Adding a port to a service makes
# compose RECREATE it, and the new one cannot start — so a clash does not fail
# politely before touching anything. It takes a working telephone system down
# and leaves it down. The only safe moment to find out is before `up`.
#
# ## What counts as "somebody else"
#
# Two sources, because either alone misses one kind of holder:
#   - other containers' published ports, read from `docker ps` — the only way
#     to name them, since the host sees every one as the same `docker-proxy`
#     (and, with Docker's userland proxy off, sees nothing at all);
#   - any other process listening on the host, read from `ss`.
# This kit's own containers are left out, or re-applying the same settings
# would report the kit colliding with itself.
# ---------------------------------------------------------------------------

KIT_CONTAINERS_RE='^(freepbx|freepbx-tunnel|freepbx-tunnel-server)$'

# One line per held range: "<proto> <from> <to> <who>".
_held_ports() {
    docker ps --format '{{.Names}}|{{.Ports}}' 2>/dev/null | while IFS='|' read -r name ports; do
        [[ "$name" =~ $KIT_CONTAINERS_RE ]] && continue
        printf '%s\n' "$ports" | tr ',' '\n' \
            | sed -nE 's/^ *[^ ]*:([0-9]+)(-([0-9]+))?->[0-9-]+\/(tcp|udp) *$/\4 \1 \3/p' \
            | while read -r proto from to; do
                printf '%s %s %s container:%s\n' "$proto" "$from" "${to:-$from}" "$name"
            done
    done

    # Everything else. docker-proxy lines are skipped because the loop above has
    # already named every container binding properly.
    #
    # Skipping by name is not enough without root: `ss -p` names only processes
    # the caller may inspect, so for a docker-group user the root-owned
    # docker-proxy sockets — this kit's own SIP and voice ports among them —
    # come back nameless and would read as "held by ?" on every running
    # install. A nameless socket on a port some container publishes is that
    # container's proxy; a named process, or a nameless one on a port no
    # container publishes, is still somebody else.
    ss -Hlntup 2>/dev/null | awk -v bound=" $(_container_bound) " '
        $0 ~ /docker-proxy/ { next }
        {
            proto = $1; addr = $5; sub(/.*:/, "", addr)
            prog = $0
            if (prog ~ /users:\(\("/) { sub(/.*users:\(\("/, "", prog); sub(/".*/, "", prog) } else prog = "?"
            if (prog == "?" && index(bound, " " proto ":" addr " ")) next
            if (addr ~ /^[0-9]+$/) print proto, addr, addr, "process:" prog
        }'
}

# "proto:port" for every host port any running container publishes, this kit's
# included, ranges expanded.
_container_bound() {
    docker ps --format '{{.Ports}}' 2>/dev/null | tr ',' '\n' \
        | sed -nE 's/^ *[^ ]*:([0-9]+)(-([0-9]+))?->[0-9-]+\/(tcp|udp) *$/\4 \1 \3/p' \
        | while read -r proto from to; do
            for p in $(seq "$from" "${to:-$from}"); do printf '%s:%s ' "$proto" "$p"; done
        done
}

# Reads wanted ranges on stdin, one per line: "<label> <proto> <from> <to>".
# Prints "<label> <proto> <port> <who>" for each range somebody else overlaps,
# and returns non-zero when there was at least one.
ports_conflicts() {
    local held found=0 label proto from to line
    held="$(_held_ports)"
    while read -r label proto from to; do
        [ -n "$label" ] || continue
        line=$(printf '%s\n' "$held" | awk -v p="$proto" -v f="$from" -v t="$to" -v l="$label" '
            $1 == p && ($2 + 0) <= (t + 0) && ($3 + 0) >= (f + 0) {
                print l, p, (($2 + 0) > (f + 0) ? $2 : f), $4; exit
            }')
        if [ -n "$line" ]; then
            printf '%s\n' "$line"
            found=1
        fi
    done
    return "$found"
}

# The ranges this kit would publish, from the values in the environment.
# Callers source .env first.
kit_wanted_ports() {
    printf 'SIP_PORT udp %s %s\n' "${SIP_PORT:-5060}" "${SIP_PORT:-5060}"
    printf 'SIP_PORT tcp %s %s\n' "${SIP_PORT:-5060}" "${SIP_PORT:-5060}"
    printf 'RTP udp %s %s\n' "${RTP_START:-10000}" "${RTP_END:-10039}"
    # The panel only matters when it is published beyond this machine's own
    # loopback; 127.0.0.1:8088 cannot clash with a proxy on 0.0.0.0:443.
    printf 'PANEL_PORT tcp %s %s\n' "${PANEL_PORT:-8088}" "${PANEL_PORT:-8088}"
    case ":${COMPOSE_FILE:-}:" in
        *compose.tunnel-server.yml*)
            printf 'TUNNEL_PORT tcp %s %s\n' "${TUNNEL_PORT:-1194}" "${TUNNEL_PORT:-1194}" ;;
    esac
}

# The first of these a tunnel could listen on without a clash, or nothing.
free_tunnel_port() {
    local p held
    held="$(_held_ports)"
    for p in 1194 1195 1196 11940 21194; do
        if ! printf '%s\n' "$held" | awk -v p="$p" '$1 == "tcp" && ($2+0) <= p && ($3+0) >= p { found=1 } END { exit !found }'; then
            printf '%s\n' "$p"
            return 0
        fi
    done
    return 1
}
