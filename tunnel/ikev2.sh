#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# The voice tunnel over IKEv2 (with GRE inside), for one router: made, or
# brought up to date. Beside the OpenVPN tunnel, which becomes its fallback.
#
#     ./tunnel/ikev2.sh --net 203.0.113.0/24
#     ./tunnel/ikev2.sh --net 203.0.113.0/24 --user office --via lte1
#
#   --net NET        the operator's network, as address/bits           (needed)
#   --user NAME      the router's name; its IKE identity        (default: router)
#   --voice-ip IP    the address Asterisk advertises to the operator (default:
#                    this server's OpenVPN tunnel address, so nothing in
#                    FreePBX or on the router's NAT changes; 10.95.0.1 with no
#                    OpenVPN tunnel)
#   --via IFACE      in the router's lines: the line IKE must leave by (the
#                    one the operator accepts, often the SIM)
#   --new-secret     replace that router's key instead of keeping it
#   --no-secret      do not print the router's lines (a tool reads them)
#   --write-only     write the files and stop; start nothing
#
# Why IKEv2, why GRE inside it, and what it was measured against: see the top
# of compose.tunnel-ikev2.yml. Safe to run again: a router keeps its key and
# its link number, and a second router is a second --user.
#
# ## Why it refuses an unsnapshotted install
#
# UDP 500 and 4500 are published by the telephone container, so adding them
# RECREATES it — the same reason as tunnel/listen.sh.
# ---------------------------------------------------------------------------
set -euo pipefail

cd "$(dirname "$0")/.."

NET=""; USER_NAME="router"; VOICE_IP=""; VIA=""
NEW_SECRET=0; NO_SECRET=0; WRITE_ONLY=0
while [ $# -gt 0 ]; do
    case "$1" in
        --net)      NET="${2:-}"; shift 2 ;;
        --user)     USER_NAME="${2:-}"; shift 2 ;;
        --voice-ip) VOICE_IP="${2:-}"; shift 2 ;;
        --via)      VIA="${2:-}"; shift 2 ;;
        --new-secret) NEW_SECRET=1; shift ;;
        --no-secret)  NO_SECRET=1; shift ;;
        --write-only) WRITE_ONLY=1; shift ;;
        -h|--help) sed -n '2,29p' "$0"; exit 0 ;;
        *) echo "unknown option: $1 (try --help)" >&2; exit 2 ;;
    esac
done

say() { printf '%s\n' "$*"; }
die() { printf '✗  %s\n' "$*" >&2; exit 1; }
ipv4() { printf '%s' "$1" | grep -qE '^([0-9]{1,3}\.){3}[0-9]{1,3}$'; }

printf '%s' "$NET" | grep -qE '^([0-9]{1,3}\.){3}[0-9]{1,3}/([0-9]|[12][0-9]|3[0-2])$' \
    || die "Give the operator's network as address/bits, like 203.0.113.0/24."
printf '%s' "$USER_NAME" | grep -qE '^[a-z][a-z0-9_-]{0,15}$' \
    || die "A router name is lower-case letters, digits, - and _, starting with a letter, at most 16."
[ -z "$VOICE_IP" ] || ipv4 "$VOICE_IP" || die "--voice-ip is an IPv4 address."
[ -z "$VIA" ] || printf '%s' "$VIA" | grep -qE '^[A-Za-z][A-Za-z0-9_.-]{0,39}$' || die "--via is an interface name, like lte1."

# The network, not an address in it (the kernel refuses a route with host bits).
net_addr=${NET%/*}; net_bits=${NET#*/}
IFS=. read -r o1 o2 o3 o4 <<<"$net_addr"
for o in "$o1" "$o2" "$o3" "$o4"; do [ "$o" -le 255 ] || die "Not an IPv4 network: $NET"; done
m=$(( net_bits == 0 ? 0 : (0xFFFFFFFF << (32 - net_bits)) & 0xFFFFFFFF ))
n=$(( (o1 << 24 | o2 << 16 | o3 << 8 | o4) & m ))
NET="$(( n >> 24 & 255 )).$(( n >> 16 & 255 )).$(( n >> 8 & 255 )).$(( n & 255 ))/$net_bits"

# shellcheck source=../scripts/ports.sh
. scripts/ports.sh
# shellcheck source=../scripts/recreate.sh
. scripts/recreate.sh

if [ "$WRITE_ONLY" = 0 ]; then
    [ -f .env ] || die "No .env here. Run ./setup.sh first."
    if recreate_erases_install; then
        die "The install still lives only inside the container, and adding a port recreates it from an image without it. Run ./snapshot.sh and set PBX_IMAGE=freepbx17-official:installed in .env — nothing was changed."
    fi
fi

# --- the addresses ----------------------------------------------------------
#
# The voice address defaults to the OpenVPN tunnel's own (`server 10.97.0.0`
# → 10.97.0.1): that is what FreePBX already advertises as the trunks' media
# address and what the router's NAT already sends the operator's packets to,
# so moving the voice to IKEv2 changes neither. OpenVPN's route to the
# operator goes via the address after it, which is the watcher's fallback.
LINK_IP=10.95.0.1
FALLBACK_VIA=""
ovpn_net="$(sed -n 's/^server \([0-9.]*\) .*/\1/p' tunnel/server.conf 2>/dev/null | head -n 1)"
if [ -n "$ovpn_net" ]; then
    IFS=. read -r a b c d <<<"$ovpn_net"
    [ -n "$VOICE_IP" ] || VOICE_IP="$a.$b.$c.$((d + 1))"
    FALLBACK_VIA="$a.$b.$c.$((d + 2))"
fi
[ -n "$VOICE_IP" ] || VOICE_IP="$LINK_IP"

# --- this router's key and link number --------------------------------------
#
# tunnel/ikev2/routers: name:key:number:network — the number gives the router
# its link address 10.95.0.<1+number> and its GRE 10.95.<100+number>.0/30.
#
# The link addresses share one /24 with this end (10.95.0.1) on purpose.
# RouterOS installs a mode-config address as a /24 on the interface IKE uses,
# so this end is then "connected" from the router's side and its masquerade
# keeps the source as it is. With the router in another /24 its GRE went out
# by the default line, that line's masquerade rewrote the source before the
# IPsec policy was looked up, and nothing ever reached here — measured. Kept
# across runs: a router that is already connected must not have its key or
# its address moved from under it.
mkdir -p tunnel/ikev2
chmod 700 tunnel/ikev2
touch tunnel/ikev2/routers
chmod 600 tunnel/ikev2/routers
line="$(awk -F: -v u="$USER_NAME" '$1 == u' tunnel/ikev2/routers | head -n 1)"
KEY="$(printf '%s' "$line" | cut -d: -f2)"
NUM="$(printf '%s' "$line" | cut -d: -f3)"
if [ -z "$NUM" ]; then
    NUM=1
    while awk -F: -v k="$NUM" '$3 == k { f = 1 } END { exit !f }' tunnel/ikev2/routers; do NUM=$((NUM + 1)); done
    [ "$NUM" -le 99 ] || die "This server already has 99 routers on IKEv2."
fi
if [ -z "$KEY" ] || [ "$NEW_SECRET" = 1 ]; then
    KEY=$(head -c 48 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 32)
fi
{ awk -F: -v u="$USER_NAME" '$1 != u' tunnel/ikev2/routers; printf '%s:%s:%s:%s\n' "$USER_NAME" "$KEY" "$NUM" "$NET"; } > tunnel/ikev2/routers.new
chmod 600 tunnel/ikev2/routers.new
mv tunnel/ikev2/routers.new tunnel/ikev2/routers

printf 'LINK_IP=%s\nVOICE_IP=%s\nFALLBACK_VIA=%s\n' "$LINK_IP" "$VOICE_IP" "$FALLBACK_VIA" > tunnel/ikev2/settings

# --- strongSwan's configuration, every router in it --------------------------
#
# Proposals are the ones measured against RouterOS 7.25-7.26: AES-256 with
# SHA-256 and ECP-256 for IKE and for ESP. PFS on, because without it (a
# provider VPN measured on the same router) the child SA dropped every 50
# minutes. One connection per router, matched on the router's own identity.
conf_before="$(cat tunnel/ikev2/swanctl.conf 2>/dev/null || true)"
{
    echo '# Written by tunnel/ikev2.sh — edit the routers file and run it again.'
    echo 'connections {'
    while IFS=: read -r name key num net; do
        [ -n "$name" ] || continue
        cat <<CONN
  $name {
    version = 2
    proposals = aes256-sha256-ecp256,aes256-sha256-modp2048,aes128-sha256-ecp256
    pools = pool-$name
    dpd_delay = 10s
    local { auth = psk
            id = pbx }
    remote { auth = psk
             id = $name }
    children {
      link {
        local_ts = $LINK_IP/32
        esp_proposals = aes256-sha256-ecp256,aes256-sha256,aes128-sha256-ecp256
        dpd_action = clear
      }
    }
  }
CONN
    done < tunnel/ikev2/routers
    echo '}'
    echo 'pools {'
    while IFS=: read -r name key num net; do
        [ -n "$name" ] && printf '  pool-%s { addrs = 10.95.0.%s/32 }\n' "$name" "$((1 + num))"
    done < tunnel/ikev2/routers
    echo '}'
    echo 'secrets {'
    while IFS=: read -r name key num net; do
        [ -n "$name" ] && printf '  ike-%s { id = %s\n    secret = "%s" }\n' "$name" "$name" "$key"
    done < tunnel/ikev2/routers
    echo '}'
} > tunnel/ikev2/swanctl.conf
chmod 600 tunnel/ikev2/swanctl.conf

say "IKEv2: router ${USER_NAME} (link 10.95.0.$((1 + NUM))), operator network ${NET}, voice address ${VOICE_IP}${FALLBACK_VIA:+, falls back to OpenVPN via ${FALLBACK_VIA}}"

[ "$WRITE_ONLY" = 1 ] && exit 0

# --- the kernel's half -------------------------------------------------------
#
# GRE and ESP are kernel modules, and a container cannot load one: from inside
# the PBX's namespace `ip link add … type gre` fails with "Operation not
# supported" unless the host has already loaded ip_gre. Loaded now, and listed
# so they load again after a reboot.
SUDO=""; [ "$(id -u)" = 0 ] || SUDO="sudo"
for mod in ip_gre esp4 xfrm_user xfrm4_tunnel; do $SUDO modprobe "$mod" 2>/dev/null || true; done
printf 'ip_gre\nesp4\nxfrm_user\nxfrm4_tunnel\n' | $SUDO tee /etc/modules-load.d/freepbx-ikev2.conf >/dev/null 2>&1 || true
lsmod | grep -q '^ip_gre' || die "The kernel's GRE module (ip_gre) could not be loaded on this machine."

# ESP can be switched off on purpose. The published mitigation for "Dirty
# Frag" (CVE-2026-43284, in ESP, and CVE-2026-43500, in RxRPC) is
# `install esp4 /bin/false` under /etc/modprobe.d, and with it IKE comes up
# but no tunnel is ever installed — measured on a production server, where the
# file had been there since May. Said here, before anything is recreated, with
# the file and whether this kernel already carries the fix.
if ! lsmod | grep -q '^esp4'; then
    blocker="$(grep -rlE '^install +esp4 ' /etc/modprobe.d /lib/modprobe.d 2>/dev/null | head -n 1)"
    if [ -n "$blocker" ]; then
        fixed=""
        log="/usr/share/doc/linux-modules-$(uname -r)/changelog.Debian.gz"
        [ -f "$log" ] && zgrep -q 'CVE-2026-43284' "$log" 2>/dev/null && fixed=1
        if [ -n "$fixed" ]; then
            die "IPsec's ESP module is switched off by $blocker (the Dirty Frag mitigation). This kernel ($(uname -r)) already carries the fix for CVE-2026-43284, which is what Ubuntu says makes the mitigation unnecessary. To allow ESP and keep RxRPC off: sed -i '/^install esp[46] /d' $blocker && modprobe esp4 && update-initramfs -u — then run this again. Nothing was changed."
        fi
        die "IPsec's ESP module is switched off by $blocker (the Dirty Frag mitigation), and this kernel's changelog does not show the fix for CVE-2026-43284. Update the kernel and reboot first; then remove the esp4/esp6 lines from that file. Nothing was changed."
    fi
    die "The kernel's ESP module (esp4) could not be loaded on this machine; IKEv2 would come up without a tunnel. Nothing was changed."
fi

# --- .env: the file that publishes 500 and 4500, after the port check --------
set_env() { if grep -q "^$1=" .env; then sed -i "s#^$1=.*#$1=$2#" .env; else printf '%s=%s\n' "$1" "$2" >> .env; fi; }
files="$(sed -n 's/^COMPOSE_FILE=//p' .env | tail -n 1)"
if [ -z "$files" ]; then
    files="$(docker inspect -f '{{index .Config.Labels "com.docker.compose.project.config_files"}}' freepbx 2>/dev/null \
        | tr ',' '\n' | sed 's#.*/##' | grep -v '^$' | paste -sd: - || true)"
    [ -n "$files" ] || files="compose.yml"
fi
case ":$files:" in *:compose.tunnel-ikev2.yml:*) ;; *) files="$files:compose.tunnel-ikev2.yml" ;; esac

if ! clashes="$(set -a; . ./.env; set +a; COMPOSE_FILE="$files"; kit_wanted_ports | ports_conflicts)"; then
    printf '%s\n' "$clashes" | while read -r label proto port who; do
        printf '✗  %s %s/%s is already held by %s\n' "$label" "$port" "$proto" "${who#*:}" >&2
    done
    die "Nothing was changed."
fi
set_env COMPOSE_FILE "$files"

running_before="$(docker ps -q --filter name='^freepbx-tunnel-ikev2$')"
./apply.sh

# A changed configuration is read when the service starts. Restarting it moves
# voice to OpenVPN for the few seconds IKE takes to come back — not the PBX.
if [ -n "$running_before" ] && [ "$conf_before" != "$(cat tunnel/ikev2/swanctl.conf)" ]; then
    docker compose restart tunnel-ikev2 >/dev/null
fi

say "Waiting for IKEv2 to listen…"
ready=0
for _ in $(seq 1 40); do
    # 500 = 01F4, in the telephone container's own socket table, which the tunnel shares.
    if docker exec freepbx sh -c 'cat /proc/net/udp' | awk '{ n = split($2, a, ":"); if (a[n] == "01F4") f = 1 } END { exit !f }'; then
        ready=1; break
    fi
    sleep 3
done
[ "$ready" = 1 ] || { docker logs --tail 20 freepbx-tunnel-ikev2 2>&1 || true; die "IKEv2 is not listening on 500/udp. Its last lines are above."; }
say "✓ Listening on 500/udp and 4500/udp."

[ "$NO_SECRET" = 1 ] && exit 0

public_ip=$(curl -fsS -m 8 https://api.ipify.org 2>/dev/null || echo ADDRESS-OF-THIS-SERVER)
P="zana-phone-${USER_NAME}"
G="gre-phone-${USER_NAME}"
cat <<ROUTER

THE ROUTER'S HALF — paste into its terminal (RouterOS 7). New objects only;
nothing the router already has is changed.

/ip ipsec profile add name=${P} hash-algorithm=sha256 enc-algorithm=aes-256 dh-group=ecp256 nat-traversal=yes dpd-interval=10s dpd-maximum-failures=5
/ip ipsec proposal add name=${P} auth-algorithms=sha256 enc-algorithms=aes-256-cbc pfs-group=ecp256
/ip ipsec mode-config add name=${P} responder=no
/ip ipsec policy group add name=${P}
/ip ipsec policy add group=${P} template=yes src-address=0.0.0.0/0 dst-address=${LINK_IP}/32 proposal=${P}
/ip ipsec peer add name=${P} address=${public_ip}/32 exchange-mode=ike2 profile=${P}
/ip ipsec identity add peer=${P} auth-method=pre-shared-key secret=${KEY} my-id=fqdn:${USER_NAME} remote-id=fqdn:pbx generate-policy=port-strict mode-config=${P} policy-template-group=${P}
/interface gre add name=${G} local-address=10.95.0.$((1 + NUM)) remote-address=${LINK_IP} keepalive=2s,3 mtu=1360 allow-fast-path=no
/ip address add address=10.95.$((100 + NUM)).2/30 interface=${G}
/ip route add dst-address=${VOICE_IP}/32 gateway=${G} comment="${P}: voice by IKEv2 while it is up"
/ip firewall filter add chain=input action=accept ipsec-policy=in,ipsec comment="${P}: what arrives inside IPsec" place-before=0
ROUTER
if [ -n "$VIA" ]; then
    printf '/ip route add dst-address=%s/32 gateway=%s comment="%s: IKE by %s"\n' "$public_ip" "$VIA" "$P" "$VIA"
fi
cat <<ROUTER

  The key is kept in tunnel/ikev2/routers. The OpenVPN tunnel stays as it is:
  when IKEv2 is down the router's ${VOICE_IP} route goes inactive and voice
  takes OpenVPN again, by itself.

ROUTER
