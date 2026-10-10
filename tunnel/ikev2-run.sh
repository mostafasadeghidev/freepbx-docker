#!/bin/sh
# ---------------------------------------------------------------------------
# Runs inside freepbx-tunnel-ikev2, in the PBX's network namespace.
# Written by nobody by hand: ./tunnel/ikev2.sh makes tunnel/ikev2/ and starts
# the service.
#
# 1. strongSwan answers each router's IKEv2 and hands it its link address
#    (10.95.0.<1+n>) through mode-config; this end is 10.95.0.1.
# 2. Over that protected link, one GRE interface per router.
# 3. Every two seconds: a router whose GRE answers gets its operator network
#    routed through GRE, from the voice address Asterisk advertises; one whose
#    GRE does not answer gets the OpenVPN route back, if there is an OpenVPN
#    tunnel to fall back to. Only changes are logged.
#
# On stop it puts every operator route back on OpenVPN and removes its GRE
# interfaces — they live in the PBX's namespace, which outlives this
# container, and a route left on a dead GRE would silence the telephone.
# ---------------------------------------------------------------------------
set -u
D=/etc/tunnel/ikev2
. "$D/settings"     # LINK_IP VOICE_IP FALLBACK_VIA

apk add -q --no-cache strongswan iproute2 >/dev/null 2>&1 || apk add --no-cache strongswan iproute2

ip addr add "$LINK_IP/32" dev lo 2>/dev/null || true
# Asterisk advertises VOICE_IP; it must exist here even while OpenVPN (which
# normally owns it on tun0) is down, or the route below has no source.
ip -o addr show | grep -q " $VOICE_IP/" || ip addr add "$VOICE_IP/32" dev lo 2>/dev/null || true

cp "$D/swanctl.conf" /etc/swanctl/swanctl.conf
/usr/lib/strongswan/charon >/dev/null 2>&1 &
CHARON=$!
for _ in $(seq 1 30); do swanctl --stats >/dev/null 2>&1 && break; sleep 1; done
swanctl --load-all

# name index network
routers() { grep -v '^#' "$D/routers" 2>/dev/null | awk -F: 'NF >= 4 { print $1, $3, $4 }'; }

fallback() {   # $1 network -> the OpenVPN route, or nothing to fall back to
    if [ -n "$FALLBACK_VIA" ] && ip link show tun0 >/dev/null 2>&1; then
        ip route replace "$1" via "$FALLBACK_VIA" dev tun0 2>/dev/null && return 0
    fi
    return 1
}

stop() {
    routers | while read -r name n net; do
        fallback "$net" || ip route del "$net" dev "gre-$name" 2>/dev/null
        ip link del "gre-$name" 2>/dev/null
    done
    kill "$CHARON" 2>/dev/null
    exit 0
}
trap stop TERM INT

say() { echo "$(date '+%F %T') $*"; }
state=""
while true; do
    kill -0 "$CHARON" 2>/dev/null || { say "charon stopped"; stop; }
    new=""
    for line in $(routers | tr ' ' ':'); do
        name=${line%%:*}; rest=${line#*:}; n=${rest%%:*}; net=${rest#*:}
        g="gre-$name"
        if ! ip link show "$g" >/dev/null 2>&1; then
            ip link add "$g" type gre local "$LINK_IP" remote "10.95.0.$((1 + n))" ttl 64
            ip addr add "10.95.$((100 + n)).1/30" dev "$g"
            ip link set "$g" mtu 1360 up
        fi
        if ping -c1 -W1 -I "$g" "10.95.$((100 + n)).2" >/dev/null 2>&1; then
            ip route replace "$net" dev "$g" src "$VOICE_IP"
            new="$new $name=gre"
        else
            if fallback "$net"; then new="$new $name=openvpn"; else new="$new $name=down"; fi
        fi
    done
    if [ "$new" != "$state" ]; then say "voice path:$new"; state=$new; fi
    sleep 2 & wait $!
done
