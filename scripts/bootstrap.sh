#!/bin/bash
# ---------------------------------------------------------------------------
# Runs once on first boot: executes the official FreePBX 17 installer.
# On every later boot it only restores config that lives outside the volumes
# and makes sure the services are up.
# ---------------------------------------------------------------------------
set -euo pipefail

# Belt and braces: the unit also loads this via EnvironmentFile.
# shellcheck disable=SC1091
if [ -f /etc/freepbx-container.env ]; then
    set -a; . /etc/freepbx-container.env; set +a
fi

PERSIST_DIR=/data
STAMP="${PERSIST_DIR}/.freepbx-installed"
BAKED_INSTALLER=/usr/local/src/sng_freepbx_debian_install.sh
INSTALLER=/tmp/sng_freepbx_debian_install.sh
INSTALLER_URL="${INSTALLER_URL:-https://raw.githubusercontent.com/FreePBX/sng_freepbx_debian_install/master/sng_freepbx_debian_install.sh}"
DOMAIN="${PBX_DOMAIN:-local}"

# Files the installer writes into /etc that no volume covers.
PERSIST_FILES=(freepbx.conf odbc.ini odbcinst.ini)

mkdir -p "$PERSIST_DIR" /var/log/pbx

# --- FQDN ------------------------------------------------------------------
# The installer aborts when `hostname -f` is empty. With network_mode: host the
# container inherits the host's hostname, which frequently has no domain part.
if ! hostname -f >/dev/null 2>&1 || [ -z "$(hostname -f 2>/dev/null || true)" ]; then
    echo "127.0.1.1 $(hostname).${DOMAIN} $(hostname)" >> /etc/hosts
    echo "[bootstrap] added FQDN $(hostname).${DOMAIN} to /etc/hosts"
fi

# --- restore config that is not covered by a volume ------------------------
for f in "${PERSIST_FILES[@]}"; do
    if [ -f "${PERSIST_DIR}/${f}" ] && [ ! -f "/etc/${f}" ]; then
        cp -a "${PERSIST_DIR}/${f}" "/etc/${f}"
        echo "[bootstrap] restored /etc/${f}"
    fi
done

# --- the FreePBX firewall module, inside a container -----------------------
#
# It assumes it owns the machine's netfilter. In a container it does not:
# Docker put its own rules in that same network namespace, and the module
# rebuilds the whole ruleset when it starts. Two things this measurably breaks:
#
#   1. DNS. Docker's resolver at 127.0.0.11 works only because of a NAT rule
#      the module wipes. The `dns:` block in compose.yml sidesteps that by
#      naming real resolvers -- but only for a container CREATED with it, and
#      `docker restart` does not re-read compose. A container made before that
#      line was added keeps resolving nothing, and the symptom is remote: SIP
#      trunks never register because Asterisk cannot resolve their hostname,
#      while a probe by IP from the same container answers fine.
#
#   2. Legitimate clients. `fpbxratelimit` moves a source to an ATTACKER list
#      after ~100 packets in 300s -- which a busy softphone reaches -- and then
#      DROPs silently. Worse, each dropped packet re-arms the timer, so a
#      client that keeps retrying keeps itself banned. It looks like
#      "Request Timeout", never like "you are blocked".
#
# fail2ban runs separately, stays on, and bans the thing that actually matters
# (repeated auth failures). So the default here is to leave the module off and
# let anyone who wants it opt back in with PBX_FIREWALL=on in pbx.env.
#
# Run on EVERY boot, not just after install: a module update can re-enable it.
apply_firewall_choice() {
    command -v fwconsole >/dev/null 2>&1 || return 0
    case "${PBX_FIREWALL:-off}" in
        on|On|ON|yes|true|1)
            echo "[bootstrap] PBX_FIREWALL=on - leaving the FreePBX firewall alone."
            echo "[bootstrap]   watch for: no DNS after a restart, and legitimate"
            echo "[bootstrap]   clients dropped by fpbxratelimit. See the README."
            ;;
        *)
            if fwconsole firewall status 2>/dev/null | grep -qi "disabled"; then
                return 0
            fi
            echo "[bootstrap] disabling the FreePBX firewall module (PBX_FIREWALL=off)."
            fwconsole firewall disable >/dev/null 2>&1                 && echo "[bootstrap]   done - fail2ban is unaffected and stays on."                 || echo "[bootstrap]   could not disable it; carrying on."
            ;;
    esac
}

# --- already installed: just bring the stack up ----------------------------
if [ -f "$STAMP" ]; then
    echo "[bootstrap] FreePBX already installed ($(cat "$STAMP")) - starting services."
    systemctl start mariadb || true
    systemctl start apache2 || true
    systemctl start freepbx || true
    apply_firewall_choice
    exit 0
fi

# --- first boot: run the official installer --------------------------------
echo "[bootstrap] ============================================================"
echo "[bootstrap] First boot - running the OFFICIAL FreePBX 17 installer."
echo "[bootstrap] This downloads several GB and takes 20-40 minutes."
echo "[bootstrap] Detailed log: /var/log/pbx/freepbx17-install-<timestamp>.log"
echo "[bootstrap] ============================================================"

# The script self-checks its version against GitHub and refuses to run when the
# baked copy is stale, so prefer a fresh download and fall back to the baked one.
if wget -q -T 30 -O "$INSTALLER" "$INSTALLER_URL" && [ -s "$INSTALLER" ]; then
    echo "[bootstrap] using freshly downloaded installer"
else
    echo "[bootstrap] download failed - falling back to the copy baked into the image"
    cp -a "$BAKED_INSTALLER" "$INSTALLER"
fi
chmod +x "$INSTALLER"

# INSTALL_ARGS is intentionally unquoted: it carries multiple flags.
# shellcheck disable=SC2086
bash "$INSTALLER" ${INSTALL_ARGS:-}

# --- persist the config files that live outside the volumes ----------------
for f in "${PERSIST_FILES[@]}"; do
    if [ -f "/etc/${f}" ]; then cp -a "/etc/${f}" "${PERSIST_DIR}/${f}"; fi
done

apply_firewall_choice

date -u +%FT%TZ > "$STAMP"
echo "[bootstrap] ============================================================"
echo "[bootstrap] FreePBX installation finished. Web UI: http://<server-ip>/"
echo "[bootstrap] ============================================================"
