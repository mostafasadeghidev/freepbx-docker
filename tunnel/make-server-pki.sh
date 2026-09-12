#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# A CA and a server certificate for the listening end of the tunnel.
#
#     ./tunnel/make-server-pki.sh
#
# Run once. It writes tunnel/pki/, which is git-ignored, and it refuses to
# overwrite an existing CA — replacing it would lock out every client that
# already trusts the old one.
#
# No client certificates are made, deliberately: the far end authenticates
# with a name and a password (`verify-client-cert none` in server.conf), which
# is all a RouterOS ovpn-client needs and one less thing to renew.
#
# openssl runs in a container, so nothing has to be installed on the host.
# ---------------------------------------------------------------------------
set -euo pipefail

cd "$(dirname "$0")"
PKI="$(pwd)/pki"
DAYS="${DAYS:-3650}"
CN="${CN:-freepbx-tunnel}"

if [ -f "$PKI/ca.crt" ]; then
    echo "There is already a CA in tunnel/pki/." >&2
    echo "Delete the folder by hand if you really mean to start again — every" >&2
    echo "client that trusts the old one will stop connecting." >&2
    exit 1
fi

mkdir -p "$PKI"

docker run --rm -v "$PKI:/pki" alpine:3.20 sh -s <<EOF
set -e
apk add -q openssl
cd /pki
openssl req -x509 -newkey rsa:2048 -nodes -days $DAYS \
    -keyout ca.key -out ca.crt -subj "/CN=$CN-ca" 2>/dev/null
openssl req -newkey rsa:2048 -nodes \
    -keyout server.key -out server.csr -subj "/CN=$CN" 2>/dev/null
printf 'extendedKeyUsage=serverAuth\nkeyUsage=digitalSignature,keyEncipherment\n' > ext.cnf
openssl x509 -req -in server.csr -CA ca.crt -CAkey ca.key -set_serial 1 \
    -days $DAYS -out server.crt -extfile ext.cnf 2>/dev/null
rm -f server.csr ext.cnf
# The key is read by the openvpn process in the container, which runs as root.
chmod 600 ca.key server.key
chmod 644 ca.crt server.crt
EOF

echo
echo "Wrote:"
ls -1 "$PKI"
echo
echo "Next:"
echo "  printf 'router:a-long-password\\n' > tunnel/users"
echo "  cp tunnel/server.conf.example tunnel/server.conf   # then read the three ① ② ③ lines"
echo "  printf 'iroute 203.0.113.0 255.255.255.0\\n' > tunnel/ccd/router"
echo
echo "The client side, on a MikroTik, is one line — see tunnel/README.md."
