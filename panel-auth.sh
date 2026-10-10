#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# A password in front of the panel on its domain (Coolify's proxy), or off.
#
#     ./panel-auth.sh --user admin              asks for the password
#     ./panel-auth.sh --user admin --hash 'admin:$apr1$...'
#                                               a hash made elsewhere (Zana
#                                               makes it on the person's own
#                                               machine, so the password never
#                                               travels)
#     ./panel-auth.sh --off
#
# See compose.coolify-auth.yml for why the users live in Coolify's dynamic
# Traefik directory. The first time on recreates the telephone container once;
# a later password change does not.
# ---------------------------------------------------------------------------
set -euo pipefail

cd "$(dirname "$0")"

USER_NAME=""; HASH=""; OFF=0
while [ $# -gt 0 ]; do
    case "$1" in
        --user) USER_NAME="${2:-}"; shift 2 ;;
        --hash) HASH="${2:-}"; shift 2 ;;
        --off)  OFF=1; shift ;;
        -h|--help) sed -n '2,17p' "$0"; exit 0 ;;
        *) echo "unknown option: $1 (try --help)" >&2; exit 2 ;;
    esac
done

say() { printf '%s\n' "$*"; }
die() { printf '✗  %s\n' "$*" >&2; exit 1; }

[ -f .env ] || die "No .env here. Run ./setup.sh first."
files="$(sed -n 's/^COMPOSE_FILE=//p' .env | tail -n 1)"
# Allowed before the panel has its domain, so the safe order — the door first,
# then the domain — recreates the PBX once: this label does nothing until
# compose.coolify.yml gives the panel a router.
docker inspect coolify-proxy >/dev/null 2>&1 || [ "$OFF" = 1 ]     || die "There is no Coolify proxy on this machine to put the password in. Nothing was changed."

# Where Coolify's proxy reads its dynamic files: asked of the proxy itself.
dyn="$(docker inspect -f '{{range .Mounts}}{{if eq .Destination "/traefik"}}{{.Source}}{{end}}{{end}}' coolify-proxy 2>/dev/null || true)"
dyn="${dyn:-/data/coolify/proxy}/dynamic"
[ -d "$dyn" ] || die "Coolify's dynamic proxy directory was not found ($dyn). Nothing was changed."
FILE="$dyn/zana-pbx-auth.yaml"
SUDO=""; [ "$(id -u)" = 0 ] || SUDO="sudo"

set_files() { if grep -q '^COMPOSE_FILE=' .env; then sed -i "s#^COMPOSE_FILE=.*#COMPOSE_FILE=$1#" .env; else printf 'COMPOSE_FILE=%s\n' "$1" >> .env; fi; }

if [ "$OFF" = 1 ]; then
    # The label goes first, then the file: a router naming a middleware that no
    # longer exists answers 404 for the whole panel.
    rest="$(printf '%s' "$files" | tr ':' '\n' | grep -vx compose.coolify-auth.yml | paste -sd: -)"
    if [ "$rest" != "$files" ]; then
        set_files "$rest"
        ./apply.sh < /dev/null
    fi
    $SUDO rm -f "$FILE"
    say "✓ The panel's extra password is off."
    exit 0
fi

printf '%s' "$USER_NAME" | grep -qE '^[A-Za-z0-9._@-]{1,64}$' || die "A user name is letters, digits and . _ @ -, at most 64."
if [ -z "$HASH" ]; then
    command -v openssl >/dev/null 2>&1 || die "openssl is not installed here; give --hash instead."
    read -r -s -p "Password for $USER_NAME: " pw; echo
    [ "${#pw}" -ge 10 ] || die "Use at least 10 characters."
    HASH="$USER_NAME:$(printf '%s' "$pw" | openssl passwd -apr1 -stdin)"
fi
# The only shapes Traefik's basicAuth takes that are worth taking: apr1 and bcrypt.
rest="${HASH#"$USER_NAME:"}"
[ "$rest" != "$HASH" ] || die "The hash is not for $USER_NAME. Nothing was changed."
printf '%s' "$rest" | grep -qE '^[$]apr1[$][./0-9A-Za-z]{1,8}[$][./0-9A-Za-z]{22}$|^[$]2[aby][$][0-9]{2}[$][./0-9A-Za-z]{53}$'     || die "That is not an apr1 or bcrypt hash. Nothing was changed."

# The file first: the label that will name it must find it there.
tmp="$(mktemp)"
printf 'http:\n  middlewares:\n    zana-pbx-auth:\n      basicAuth:\n        users:\n          - "%s"\n' "$HASH" > "$tmp"
$SUDO install -m 0644 "$tmp" "$FILE"
rm -f "$tmp"

case ":$files:" in
    *:compose.coolify-auth.yml:*)
        say "✓ Password changed. The proxy reads it within a second; nothing was restarted." ;;
    *)
        # After compose.coolify.yml, which defines the router this adds to.
        case ":$files:" in
            *:compose.coolify.yml:*) next="$(printf '%s' "$files" | sed 's#compose.coolify.yml#compose.coolify.yml:compose.coolify-auth.yml#')" ;;
            *) next="${files:-compose.yml}:compose.coolify-auth.yml" ;;
        esac
        set_files "$next"
        ./apply.sh < /dev/null || { set_files "$files"; $SUDO rm -f "$FILE"; die "apply.sh refused; .env is back as it was and the password file removed."; }
        say "✓ The panel now asks for this password before FreePBX's own login." ;;
esac
