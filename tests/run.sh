#!/bin/bash
# Tests for the website template scripts that run without a container: repo detection, and pve-site.sh against fake
# `pct` and `curl` (no Proxmox, no Cloudflare). Needs bash, node, perl (Git Bash on the PC is enough).
#   bash tests/run.sh
set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
DETECT="$HERE/../ct/lib/detect.sh"
PVE_SITE="$HERE/../pve/pve-site.sh"
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
fails=0 n=0

ok() { n=$((n + 1)); if [[ "$2" == "$3" ]]; then echo "ok   $1"; else echo "FAIL $1"; echo "     want: $3"; echo "     got:  $2"; fails=$((fails + 1)); fi; }
repo() { rm -rf "$T/r"; mkdir -p "$T/r"; cd "$T/r"; }
d() { bash "$DETECT" "$T/r" 2>&1 | grep -E "^(${1:-type|kind|root|build|start|port})=" | tr '\n' ' ' | sed 's/ $//'; }

# --- detection ---
repo; echo '<h1>hi</h1>' >index.html
ok "plain index.html" "$(d)" "type='static' kind='plain' build='' root='.' start='' port=''"

repo; mkdir public; echo x >public/index.html; echo '# readme' >README.md
ok "index.html in public/" "$(d type\|root)" "type='static' root='public'"

repo; echo '{"scripts":{"dev":"vite","start":"vite","build":"vite build"}}' >package.json; touch pnpm-lock.yaml
ok "vite: dev-server start is not a server" "$(d type\|kind\|build\|pm)" "type='static' kind='built' build='pnpm run build' pm='pnpm'"

repo; echo '{"scripts":{"start":"astro dev","build":"astro build"}}' >package.json
ok "astro dev start" "$(d type\|build)" "type='static' build='npm run build'"

repo; echo '{"scripts":{"start":"node server.js"}}' >package.json
ok "express app" "$(d type\|kind\|start\|port\|build)" "type='node' kind='server' build='' start='npm start' port='3000'"

repo; echo '{"scripts":{"build":"next build","start":"next start"}}' >package.json; touch yarn.lock
ok "next.js server" "$(d type\|build\|start)" "type='node' build='yarn run build' start='yarn start'"

repo; printf 'FROM nginx\nEXPOSE 80\n' >Dockerfile; echo '{"scripts":{"start":"node a"}}' >package.json
ok "Dockerfile wins over package.json, port from EXPOSE" "$(d type\|kind\|port)" "type='docker' kind='dockerfile' port='80'"

repo; printf 'FROM scratch\n' >Dockerfile; echo 'services: {}' >compose.yaml
ok "compose wins over Dockerfile" "$(d type\|kind\|port)" "type='docker' kind='compose' port='8080'"

repo; printf 'type = "static"\nbuild = "npx @11ty/eleventy"   # comment\nroot = "_site"\nspa = true\nhealth = "/ok"\n' >site.toml
echo '{"scripts":{"start":"node x"}}' >package.json
ok "site.toml overrides" "$(d type\|kind\|build\|root\|spa\|health)" "type='static' kind='built' build='npx @11ty/eleventy' root='_site' health='/ok' spa='true'"

repo; printf 'port = 5000\n' >site.toml; echo 'services: {}' >docker-compose.yml
ok "site.toml port only" "$(d type\|port)" "type='docker' port='5000'"

repo; echo '# nothing' >README.md
out=$(bash "$DETECT" "$T/r" 2>&1); code=$?
ok "nothing to serve -> exit 3 with help" "$code ${out:0:19}" "3 no site type found:"

repo; printf 'type = "php"\n' >site.toml
ok "unknown type refused" "$(bash "$DETECT" "$T/r" 2>&1)" "site.toml: unknown type 'php' (static, node, docker)"

repo; printf 'root = "../../etc"\n' >site.toml; echo x >index.html
ok "root outside the repo refused" "$(bash "$DETECT" "$T/r" 2>&1)" "site.toml: root must be a folder inside the repo"

repo; printf "build = \"echo it's\"\n" >site.toml; echo x >index.html
eval "$(bash "$DETECT" "$T/r")"
ok "quotes survive eval" "$build" "echo it's"

# --- pve-site.sh with fakes ---
F="$T/fake"; mkdir -p "$F" "$T/fw"
cat >"$F/pct" <<'EOF'
#!/bin/bash
echo "pct $*" >>"$FAKE_LOG"
case $1 in
  status) [[ -f "$FAKE_DIR/ct-$2" ]] && echo "status: running" || exit 2 ;;
  clone) touch "$FAKE_DIR/ct-$3" ;;
  config) echo "net0: name=eth0,bridge=vmbr0,hwaddr=BC:24:11:00:00:01,ip=dhcp,type=veth"
          if [[ $2 == 104 ]]; then echo "description: hand-made CT"; echo "hostname: hub"; else echo "description: Website (pve-site.sh)"; echo "hostname: site-game"; fi ;;
  # Like real `pct exec`: PATH inside is /sbin:/bin:/usr/sbin:/usr/bin, so a bare `site` (/usr/local/sbin) is not found
  exec) shift 3; [[ $1 == site ]] && { echo "lxc-attach: Failed to exec \"site\"" >&2; exit 1; }; echo "  stdin: $(cat)" >>"$FAKE_LOG" ;;
esac
exit 0
EOF
cat >"$F/curl" <<'EOF'
#!/bin/bash
# Fake curl: Cloudflare API answers + the final https check; logs method, URL, body and the auth header it was given
m=GET url="" body="" w=""
while (( $# )); do
  case $1 in
    -X) m=$2; shift 2 ;;
    --data|-d) body=$2; shift 2 ;;
    -H) [[ $2 == @* ]] && echo "  header-file: $(cat "${2#@}")" >>"$FAKE_LOG"; shift 2 ;;
    -w) w=$2; shift 2 ;;
    -o|-m) shift 2 ;;
    http*) url=$1; shift ;;
    *) shift ;;
  esac
done
echo "curl $m $url ${body}" >>"$FAKE_LOG"
case "$m $url" in
  "GET https://api.cloudflare.com/client/v4/accounts/acc/cfd_tunnel?name="*) echo '{"success":true,"result":[]}' ;;
  "POST https://api.cloudflare.com/client/v4/accounts/acc/cfd_tunnel") echo '{"success":true,"result":{"id":"tid-1","name":"site-game"}}' ;;
  "PUT https://api.cloudflare.com/client/v4/accounts/acc/cfd_tunnel/tid-1/configurations") echo '{"success":true,"result":{}}' ;;
  "GET https://api.cloudflare.com/client/v4/zones/zone/dns_records"*) echo '{"success":true,"result":[]}' ;;
  "POST https://api.cloudflare.com/client/v4/zones/zone/dns_records") echo '{"success":true,"result":{"id":"rec-1"}}' ;;
  "GET https://api.cloudflare.com/client/v4/accounts/acc/cfd_tunnel/tid-1/token") echo '{"success":true,"result":"eyJhIjoiYWNjIiwidCI6InRpZC0xIiwicyI6InNlY3JldCJ9AAAAAAAAAAAA"}' ;;
  "GET https://game.example.org/") printf '%s' "${w:+200}" ;;
  *) echo '{"success":false,"errors":[{"code":1000,"message":"unexpected in test"}]}' ;;
esac
EOF
chmod +x "$F/pct" "$F/curl"
export FAKE_LOG="$T/log" FAKE_DIR="$T"
CONF_ENV=(SITES_CONF="$T/none.env" DOMAIN=example.org TEMPLATE=111 DNS_IP=192.0.2.27 LAN=192.0.2.0/24 HUB_URL=http://192.0.2.70:8090)
run_pve() { env PATH="$F:$PATH" PVE_SITE_TEST=1 FWDIR="$T/fw" "${CONF_ENV[@]}" CF_API_TOKEN=cf-secret-123 CF_ACCOUNT_ID=acc CF_ZONE_ID=zone \
  GITHUB_TOKEN=github_pat_TEST HUB_TOKEN=hub-secret bash "$PVE_SITE" "$@"; }

out=$(run_pve new 130 game https://github.com/u/game 2>&1); code=$?
ok "pve-site new exits 0" "$code" "0"
ok "pve-site new reports the URL" "$(tail -1 <<<"$out")" "https://game.example.org -> HTTP 200"
log=$(cat "$T/log")
ok "clone from template 111" "$(grep -c '^pct clone 111 130 --hostname site-game --full' <<<"$log")" "1"
ok "memory, onboot, DNS server, nesting" "$(grep -c '^pct set 130 --memory 512 --swap 512 --onboot 1 --nameserver 192.0.2.27 --features nesting=1,keyctl=1' <<<"$log")" "1"
ok "firewall switched on at net0" "$(grep '^pct set 130 --net0' <<<"$log")" "pct set 130 --net0 name=eth0,bridge=vmbr0,hwaddr=BC:24:11:00:00:01,ip=dhcp,type=veth,firewall=1"
ok "site up with host" "$(grep -c '^pct exec 130 -- /usr/local/sbin/site up https://github.com/u/game --branch main --host game.example.org' <<<"$log")" "1"
ok "tunnel config points at local Caddy" "$(grep -c '"hostname":"game.example.org","service":"http://127.0.0.1:80"' <<<"$log")" "1"
ok "proxied CNAME to the tunnel" "$(grep -c '"content":"tid-1.cfargotunnel.com","proxied":true' <<<"$log")" "1"
ok "tunnel token goes into the CT on stdin" "$(grep -c '^  stdin: eyJhIjoiYWNjIiwidCI6InRpZC0xIiwicyI6InNlY3JldCJ9AAAAAAAAAAAA$' <<<"$log")" "1"
ok "GitHub + hub token on stdin" "$(grep -A1 -E '^pct exec 130 -- /usr/local/sbin/site (github-token|hub)' <<<"$log" | grep -c stdin)" "2"
ok "API token only in header files, never in argv" "$(grep -v 'header-file' <<<"$log" | grep -c 'cf-secret-123')" "0"
ok "API token was sent" "$(grep -c 'header-file: Authorization: Bearer cf-secret-123' <<<"$log")" "7"
ok "no secret in any pct argv" "$(grep '^pct' <<<"$log" | grep -cE 'github_pat|hub-secret|eyJ')" "0"
fw=$(cat "$T/fw/130.fw")
ok "firewall: inbound dropped" "$(grep -c '^policy_in: DROP' <<<"$fw")" "1"
ok "firewall: LAN dropped after DNS + hub" "$(grep -E '^OUT' <<<"$fw" | awk '{print $2, $4}' | tr '\n' ' ')" "ACCEPT 192.0.2.27 ACCEPT 192.0.2.27 ACCEPT 192.0.2.70 DROP 192.0.2.0/24 DROP 100.64.0.0/10 "
ok "firewall: no LAN preview without --lan" "$(grep -c '^IN' <<<"$fw")" "0"

# --- --allow-out: one LAN target for one CT, before the drops, kept on re-runs ---
out=$(run_pve firewall 130 --allow-out 192.0.2.44:11000 2>&1); code=$?
ok "allow-out: firewall exits 0" "$code" "0"
fw=$(cat "$T/fw/130.fw")
ok "allow-out: rule before LAN drop" "$(grep -E '^OUT' <<<"$fw" | awk '{print $2, $4}' | tr '\n' ' ')" "ACCEPT 192.0.2.27 ACCEPT 192.0.2.27 ACCEPT 192.0.2.70 ACCEPT 192.0.2.44 DROP 192.0.2.0/24 DROP 100.64.0.0/10 "
ok "allow-out: tcp port" "$(grep -c '^OUT ACCEPT -dest 192.0.2.44 -p tcp -dport 11000 # allow-out' <<<"$fw")" "1"
run_pve firewall 130 >/dev/null 2>&1
ok "allow-out: kept on re-run" "$(grep -c 'allow-out' "$T/fw/130.fw")" "1"
run_pve firewall 130 --allow-out 192.0.2.44:11000 >/dev/null 2>&1
ok "allow-out: written once" "$(grep -c 'allow-out' "$T/fw/130.fw")" "1"
for bad in 192.0.2.0/24:80 nas.lan:80 1.2.3.4 1.2.3.4:0 1.2.3.4:70000 300.1.1.1:80 ''; do
  out=$(run_pve firewall 130 --allow-out "$bad" 2>&1); code=$?
  ok "allow-out: '$bad' refused" "$code $(grep -c -- '--allow-out' <<<"$out")" "1 1"
done
ok "allow-out: refusals left the rules alone" "$(grep -c 'allow-out' "$T/fw/130.fw")" "1"
out=$(run_pve new 140 recipes https://github.com/u/recipes --allow-out 1.2.3.4 2>&1); code=$?
ok "allow-out: bad value refused by new before any pct call" "$code $(grep -c '^pct clone 111 140' "$T/log")" "1 0"

out=$(run_pve new 130 game https://github.com/u/game 2>&1); code=$?
ok "existing CT refused" "$code ${out}" "1 pve-site: CT 130 exists already"
out=$(run_pve new 131 Bad_Name https://github.com/u/game 2>&1); code=$?
ok "bad name refused" "$code" "1"
out=$(env PATH="$F:$PATH" PVE_SITE_TEST=1 "${CONF_ENV[@]}" bash "$PVE_SITE" new 132 shop https://github.com/u/x 2>&1); code=$?
ok "no Cloudflare credentials -> clear error" "$code ${out:0:59}" "1 pve-site: CF_API_TOKEN, CF_ACCOUNT_ID and CF_ZONE_ID needed"

# --- site values come from the conf file / env, never from the code ---
: >"$T/log"
out=$(env PATH="$F:$PATH" PVE_SITE_TEST=1 FWDIR="$T/fw" "${CONF_ENV[@]}" DNS_IP= CF_API_TOKEN=x CF_ACCOUNT_ID=acc CF_ZONE_ID=zone \
  bash "$PVE_SITE" new 133 shop https://github.com/u/x 2>&1); code=$?
ok "conf: missing DNS_IP refused" "$code ${out}" "1 pve-site: DNS_IP missing in $T/none.env (see sites.env.example)"
ok "conf: refused before any pct call" "$(grep -c '^pct' "$T/log")" "0"
env PATH="$F:$PATH" PVE_SITE_TEST=1 FWDIR="$T/fw" "${CONF_ENV[@]}" HUB_URL= bash "$PVE_SITE" firewall 130 >/dev/null 2>&1
ok "conf: no hub rule without HUB_URL" "$(grep -c 'dport 8090' "$T/fw/130.fw") $(grep -c 'allow-out' "$T/fw/130.fw")" "0 1"
out=$(env PATH="$F:$PATH" PVE_SITE_TEST=1 FWDIR="$T/fw" "${CONF_ENV[@]}" HUB_URL=https://hub.lan bash "$PVE_SITE" firewall 130 2>&1); code=$?
ok "conf: HUB_URL must be http://ip:port" "$code" "1"
fwrun() { env PATH="$F:$PATH" PVE_SITE_TEST=1 FWDIR="$T/fw" "${CONF_ENV[@]}" "$@" bash "$PVE_SITE" firewall 130 2>&1; }
cp "$T/fw/130.fw" "$T/fw-before"
for bad in DNS_IP=nas.lan DNS_IP=192.0.2.300 LAN=192.0.2.0 LAN=192.0.2.0/33 'LAN=192.0.2.0/24 # home' TAILNET=tailnet HUB_URL=http://192.0.2.999:8090; do
  out=$(fwrun "$bad"); code=$?
  ok "conf: '$bad' refused" "$code" "1"
done
ok "conf: refusals left the firewall file alone" "$(cmp -s "$T/fw-before" "$T/fw/130.fw" && echo same)" "same"
fwrun 'LAN="192.0.2.0/24"' "DNS_IP='192.0.2.27'" >/dev/null
ok "conf: quotes around values are stripped" "$(grep -cE '^OUT (DROP -dest 192\.0\.2\.0/24|ACCEPT -dest 192\.0\.2\.27 )' "$T/fw/130.fw") $(grep -c '"' "$T/fw/130.fw")" "3 0"

# --- firewall only rewrites CTs that pve-site.sh made ---
out=$(run_pve firewall 104 2>&1); code=$?
ok "firewall: CT not made by pve-site.sh refused" "$code $([[ -e "$T/fw/104.fw" ]] && echo written || echo untouched)" "1 untouched"

# --- the example conf has no working placeholders: a key you forget must stop the script, not block the wrong LAN ---
ok "sites.env.example: required keys are empty" \
  "$(grep -E '^(DOMAIN|TEMPLATE|DNS_IP|LAN|CF_API_TOKEN|CF_ACCOUNT_ID|CF_ZONE_ID)=' "$HERE/../sites.env.example" | grep -cv '=$')" "0"

# --- syntax of everything that only runs in the container ---
for f in "$HERE/../ct/bin/site" "$HERE/../ct/build-template.sh" "$PVE_SITE"; do
  ok "bash -n $(basename "$f")" "$(bash -n "$f" 2>&1)" ""
done

echo "$((n - fails))/$n passed"
(( fails == 0 ))
