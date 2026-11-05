#!/bin/bash
# Turns a fresh Debian 13 LXC into the website template. Run as root INSIDE the container, from the
# unpacked folder:   bash build-template.sh
# Then on the Proxmox host:   pct shutdown <id> && pct template <id>
#
# Installs: Caddy, git + git-lfs, rsync, Node.js LTS (NodeSource) with corepack, Docker (off until a Docker site needs
# it), cloudflared (Cloudflare's apt repo), unattended security upgrades; the `site` command and its systemd units.
# No SSH server and no keys: get in with `pct enter` / `pct exec`. Run it again any time; it is idempotent.
set -euo pipefail

NODE_MAJOR=24
HERE=$(cd "$(dirname "$0")" && pwd)

[[ $EUID -eq 0 ]] || { echo "run as root" >&2; exit 1; }
. /etc/os-release
[[ "$VERSION_CODENAME" == trixie ]] || { echo "needs Debian 13 (trixie), this is $PRETTY_NAME. Recreate the CT from the Debian 13 template." >&2; exit 1; }

export DEBIAN_FRONTEND=noninteractive
apt-get update -q
apt-get full-upgrade -y -q
apt-get install -y -q --no-install-recommends ca-certificates curl gnupg git git-lfs rsync jq unattended-upgrades \
  caddy docker.io docker-cli docker-compose util-linux procps   # Debian 13: the docker command is its own package

# Node.js LTS and cloudflared from their signed apt repos (keys pinned to these repos only)
install -d -m 755 /etc/apt/keyrings
curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key | gpg --dearmor --yes -o /etc/apt/keyrings/nodesource.gpg
echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_$NODE_MAJOR.x nodistro main" \
  >/etc/apt/sources.list.d/nodesource.list
curl -fsSL https://pkg.cloudflare.com/cloudflare-main.gpg -o /etc/apt/keyrings/cloudflare-main.gpg
echo "deb [signed-by=/etc/apt/keyrings/cloudflare-main.gpg] https://pkg.cloudflare.com/cloudflared any main" \
  >/etc/apt/sources.list.d/cloudflared.list
apt-get update -q
apt-get install -y -q nodejs cloudflared
git lfs install --system >/dev/null

# The unprivileged user that builds and runs the site
id site >/dev/null 2>&1 || useradd --system --home-dir /var/lib/site/home --create-home --shell /usr/sbin/nologin site
install -d -o site -g site /var/lib/site/home /srv/site/data
install -d -m 755 /srv/site /srv/site/releases /var/log/site
install -d -m 700 /etc/site

# The site command, detection and units
install -m 755 "$HERE/bin/site" /usr/local/sbin/site
ln -sf /usr/local/sbin/site /usr/sbin/site   # `pct exec <id> -- site …` has no /usr/local/sbin in its PATH
install -d /usr/local/lib/site
install -m 644 "$HERE/lib/detect.sh" /usr/local/lib/site/detect.sh
git -C "$HERE/.." rev-parse --short HEAD 2>/dev/null >/usr/local/lib/site/VERSION || date -u +%F >/usr/local/lib/site/VERSION
install -m 644 "$HERE"/systemd/*.service "$HERE"/systemd/*.timer /etc/systemd/system/
systemctl daemon-reload
systemctl enable site-firstboot.service >/dev/null
# Docker only starts once a Docker site needs it (site enables it); cloudflared runs only via cloudflared-site
systemctl disable --now docker.service docker.socket containerd.service >/dev/null 2>&1 || true
systemctl disable --now cloudflared.service >/dev/null 2>&1 || true

# Caddy: placeholder until the first deploy
cat >/etc/caddy/Caddyfile <<'EOF'
{
	admin localhost:2019
	auto_https off
}
http://:80 {
	bind 127.0.0.1
	respond "No site deployed yet." 200
}
EOF
systemctl enable caddy >/dev/null
systemctl restart caddy

# No IPv6: the per-CT firewall rules are IPv4; with IPv6 the LAN would be reachable around them
cat >/etc/sysctl.d/90-site.conf <<'EOF'
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
EOF
sysctl -q -p /etc/sysctl.d/90-site.conf || true

# Security updates by themselves; small journal (15 G disk)
cat >/etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF
mkdir -p /etc/systemd/journald.conf.d
printf '[Journal]\nSystemMaxUse=200M\n' >/etc/systemd/journald.conf.d/size.conf

# No SSH in the template (a clone that needs it gets SSH set up by hand)
apt-get purge -y -q openssh-server >/dev/null 2>&1 || true

echo "versions: $(caddy version | cut -d' ' -f1) · node $(node -v) · $(cloudflared --version | head -1 | cut -d' ' -f3) · $(docker --version | cut -d, -f1)"

# Clean, so every clone starts fresh: own machine-id, no history, no state
apt-get autoremove -y -q >/dev/null; apt-get clean
rm -rf /etc/site/* /var/lib/site/*.env /srv/site/repo /srv/site/releases/* /srv/site/current /srv/site/slot-* /var/log/site/*
truncate -s 0 /etc/machine-id; rm -f /var/lib/dbus/machine-id
rm -f /etc/ssh/ssh_host_* /root/.bash_history
journalctl --rotate >/dev/null 2>&1 && journalctl --vacuum-time=1s >/dev/null 2>&1 || true
rm -rf "$HERE" /root/ct.tar.gz
echo "done. Now on the Proxmox host:  pct shutdown 111 && pct template 111"
