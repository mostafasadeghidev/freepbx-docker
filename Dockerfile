# ---------------------------------------------------------------------------
# FreePBX 17 in Docker — Debian 12 + systemd + the OFFICIAL Sangoma installer.
#
# Sangoma does not publish an official FreePBX container image. The only
# supported install path is sng_freepbx_debian_install.sh on a clean Debian 12
# host, so this image reproduces exactly that: Debian 12 with a real systemd,
# and the official script run once on first boot.
#
# The installer uses `set -e` and calls systemctl (mask/start/restart/enable),
# so it cannot run at build time — it needs PID 1 to actually be systemd.
# ---------------------------------------------------------------------------
FROM debian:12

ENV DEBIAN_FRONTEND=noninteractive \
    container=docker \
    LANG=C.UTF-8

# systemd, plus the handful of tools the installer expects to already exist
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      systemd systemd-sysv dbus \
      ca-certificates wget curl gnupg \
      procps iproute2 net-tools \
      locales tzdata less nano \
 && rm -rf /var/lib/apt/lists/*

# Units that are meaningless (or harmful) inside a container
RUN systemctl mask -- \
      dev-hugepages.mount \
      sys-fs-fuse-connections.mount \
      sys-kernel-config.mount \
      systemd-logind.service \
      getty.target \
      console-getty.service \
      systemd-udevd.service \
      systemd-udev-trigger.service \
 && rm -f /lib/systemd/system/multi-user.target.wants/getty.target

# Bake a copy of the official installer as a fallback. bootstrap.sh still tries
# to fetch the newest one at first boot, because the script refuses to run when
# it detects it is out of date.
ARG INSTALLER_URL=https://raw.githubusercontent.com/FreePBX/sng_freepbx_debian_install/master/sng_freepbx_debian_install.sh
RUN wget -O /usr/local/src/sng_freepbx_debian_install.sh "$INSTALLER_URL" \
 && chmod +x /usr/local/src/sng_freepbx_debian_install.sh

COPY scripts/bootstrap.sh /usr/local/sbin/freepbx-bootstrap.sh
COPY scripts/freepbx-bootstrap.service /etc/systemd/system/freepbx-bootstrap.service

# Defensive: these files are authored on Windows, CRLF would break the shebang
RUN sed -i 's/\r$//' /usr/local/sbin/freepbx-bootstrap.sh \
                     /etc/systemd/system/freepbx-bootstrap.service \
 && chmod +x /usr/local/sbin/freepbx-bootstrap.sh \
 && systemctl enable freepbx-bootstrap.service

VOLUME ["/var/lib/mysql", "/etc/asterisk", "/var/lib/asterisk", "/var/spool/asterisk", "/var/www/html", "/data"]

STOPSIGNAL SIGRTMIN+3
CMD ["/sbin/init"]
