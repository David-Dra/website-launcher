# website-template

One public website per Proxmox container, from a GitHub repo, at `<name>.<your domain>` through its own Cloudflare
tunnel. Every push goes live within ~2 minutes; a broken build leaves the old version live.

```bash
# on the Proxmox host, as root
bash pve/pve-site.sh new 130 game https://github.com/<user>/<repo> [--memory 1024] [--branch main] [--allow-out ip:port]
```

| Folder | Runs | What |
|---|---|---|
| `ct/` | inside the template CT | `build-template.sh` (Debian 13: Caddy, Node 24, Docker, cloudflared), the `site` command, repo detection, systemd units |
| `pve/` | on the Proxmox host, as root | `pve-site.sh`: clone, per-CT firewall, Cloudflare tunnel + DNS via API, first deploy |
| `tests/` | on any PC with bash, node, perl | `bash tests/run.sh`: detection + `pve-site.sh` against fake `pct`/`curl` |
| `sites.env.example` | | every setting and secret `pve-site.sh` reads |

Repo types: static (`index.html`), built static (`package.json` `build`), Node server (`start`), `Dockerfile`,
`compose.yaml`; a `site.toml` in the repo overrides the detection (`type`, `build`, `root`, `start`, `port`,
`health`, `spa`). Inside a site CT: `site status`, `site update --force`, `site rollback`, `site logs`,
`site secret set NAME` (value on stdin; the app gets it as an environment variable).

## Isolation

Caddy listens on 127.0.0.1 only and cloudflared connects outbound, so nothing reaches a site CT from the LAN.
Each site CT gets its own Proxmox firewall file: inbound dropped; outbound to the internet allowed, to the LAN and the
tailnet dropped, except the DNS server, an optional hub and any `--allow-out ip:port` you give that one site
(for example the one service it reads its data from). The Proxmox node's own firewall is not touched.

## Setup

1. Cloudflare: an API token with *Account › Cloudflare Tunnel › Edit* and *Zone › DNS › Edit* for your zone; note the
   account id and zone id.
2. Proxmox host: copy `sites.env.example` to `/root/.config/pve-sites.env`, fill it in, `chmod 600`.
3. Template: a fresh Debian 13 CT (1 core, 512 MB, 15 GB, unprivileged, DHCP); copy `ct/` in, run
   `bash ct/build-template.sh` inside it, then `pct shutdown <id> && pct template <id>`.
4. First site: `bash pve/pve-site.sh new <ctid> <name> <repo>`; it prints `https://<name>.<domain> -> HTTP 200`.
   Remove a site with `bash pve/pve-site.sh rm <ctid> <name>`.

Secrets never live in this repo and enter a CT only on stdin; the Cloudflare API token never enters a CT at all.

## License

MIT
