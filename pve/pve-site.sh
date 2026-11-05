#!/bin/bash
# Website containers from a template CT. Run as root on Proxmox VE. Every site gets its own CT, its own Cloudflare
# tunnel and the name <name>.$DOMAIN.
#
#   bash pve-site.sh new <ctid> <name> <github-repo-url> [--branch main] [--memory 512] [--subdir dir] [--lan]
#                        [--allow-out ip:port]...   lets this CT reach one LAN address:port (e.g. its data source)
#   bash pve-site.sh publish <ctid> <name>      tunnel + DNS for an existing site CT (again), token into the CT
#   bash pve-site.sh unpublish <name>           delete DNS record and tunnel (the CT keeps running, offline)
#   bash pve-site.sh firewall <ctid> [--lan] [--allow-out ip:port]  (re)write the firewall: no inbound, no LAN except DNS, hub, allow-outs
#   bash pve-site.sh rm <ctid> <name>           unpublish, then stop and destroy the CT (asks first)
#   bash pve-site.sh list                       site tunnels in Cloudflare and site CTs here
#
# Settings and secrets live only here, in /root/.config/pve-sites.env (0600; SITES_CONF points elsewhere), or come in
# as environment variables for one run (CF_API_TOKEN=… bash pve-site.sh new …). Every key: sites.env.example.
#   DOMAIN, TEMPLATE, DNS_IP, LAN   required: site domain, template CT id, the DNS server site CTs use, your LAN range
#   HUB_URL                          optional, http://ip:port of a hub that collects deploy results (gets a firewall hole)
#   CF_API_TOKEN     Cloudflare API token: Account > Cloudflare Tunnel > Edit, Zone > DNS > Edit (your zone only)
#   CF_ACCOUNT_ID    Cloudflare account ID          CF_ZONE_ID   zone ID of $DOMAIN
#   GITHUB_TOKEN     optional, fine-grained, read-only "Contents" on the website repos (private repos)
#   HUB_TOKEN        optional, the hub's token for deploy results
# Secrets go into a CT only on stdin and only what that CT needs; the Cloudflare API token never enters a CT.
set -euo pipefail

CONF=${SITES_CONF:-/root/.config/pve-sites.env}
CF=https://api.cloudflare.com/client/v4
PCT=${PCT:-pct}
SITE=/usr/local/sbin/site   # full path: `pct exec` runs with PATH=/sbin:/bin:/usr/sbin:/usr/bin
FWDIR=${FWDIR:-/etc/pve/firewall}

die() { echo "pve-site: $*" >&2; exit 1; }
[[ $EUID -eq 0 || -n "${PVE_SITE_TEST:-}" ]] || die "run as root on pve"
if [[ -f "$CONF" ]]; then
  [[ $(stat -c %a "$CONF") == 600 ]] || die "$CONF must be chmod 600"
  # Values already in the environment win over the file
  while IFS='=' read -r k v; do
    if [[ "$k" =~ ^[A-Z_]+$ && -z "${!k:-}" ]]; then export "$k=${v//$'\r'/}"; fi
  done <"$CONF"
fi
CF_API_TOKEN=${CF_API_TOKEN:-} CF_ACCOUNT_ID=${CF_ACCOUNT_ID:-} CF_ZONE_ID=${CF_ZONE_ID:-} GITHUB_TOKEN=${GITHUB_TOKEN:-} HUB_TOKEN=${HUB_TOKEN:-}
DOMAIN=${DOMAIN:-} TEMPLATE=${TEMPLATE:-} DNS_IP=${DNS_IP:-} LAN=${LAN:-} HUB_URL=${HUB_URL:-} TAILNET=${TAILNET:-100.64.0.0/10}
HUB_IP="" HUB_PORT=""

ipv4() {  # ipv4 <value>: true for a.b.c.d with every part 0-255
  local o
  [[ "$1" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || return 1
  for o in ${1//./ }; do (( 10#$o <= 255 )) || return 1; done
}
cidr() { [[ "$1" == */* ]] && ipv4 "${1%/*}" && [[ "${1#*/}" =~ ^[0-9]{1,2}$ ]] && (( 10#${1#*/} <= 32 )); }

# The site values every command needs, checked before anything touches a CT: they end up in firewall rules, and
# pve-firewall skips a rule it cannot parse (a quoted or mistyped LAN would leave the LAN open, silently).
need_conf() {
  local k v
  for k in DOMAIN TEMPLATE DNS_IP LAN TAILNET HUB_URL; do  # LAN="…" / LAN='…' as people write in env files
    v=${!k}; v=${v#[\"\']}; v=${v%[\"\']}; printf -v "$k" '%s' "$v"
  done
  for k in DOMAIN TEMPLATE DNS_IP LAN; do [[ -n "${!k}" ]] || die "$k missing in $CONF (see sites.env.example)"; done
  ipv4 "$DNS_IP" || die "DNS_IP must be one IPv4 address (got '$DNS_IP')"
  cidr "$LAN" || die "LAN must be an IPv4 range like 192.168.1.0/24 (got '$LAN')"
  cidr "$TAILNET" || die "TAILNET must be an IPv4 range like 100.64.0.0/10 (got '$TAILNET')"
  [[ "$TEMPLATE" =~ ^[0-9]{3,4}$ ]] || die "TEMPLATE must be a CT id (got '$TEMPLATE')"
  [[ "$DOMAIN" =~ ^[a-z0-9]([a-z0-9.-]*[a-z0-9])?\.[a-z]{2,}$ ]] || die "DOMAIN must look like example.org (got '$DOMAIN')"
  if [[ -n "$HUB_URL" ]]; then
    [[ "$HUB_URL" =~ ^http://([0-9.]+):([0-9]{1,5})/?$ ]] || die "HUB_URL must look like http://192.168.1.20:8090 (got '$HUB_URL')"
    HUB_IP=${BASH_REMATCH[1]} HUB_PORT=${BASH_REMATCH[2]}
    ipv4 "$HUB_IP" && (( 10#$HUB_PORT >= 1 && 10#$HUB_PORT <= 65535 )) || die "HUB_URL must look like http://192.168.1.20:8090 (got '$HUB_URL')"
  fi
}

json() {  # json <perl expression on $j> < JSON: prints the result (perl + JSON::PP ship with Proxmox)
  perl -MJSON::PP -e 'local $/; my $j = decode_json(<STDIN>); my @r = eval $ARGV[0]; die $@ if $@; print map { "$_\n" } grep { defined } @r' "$1"
}

need_cf() { [[ -n "$CF_API_TOKEN" && -n "$CF_ACCOUNT_ID" && -n "$CF_ZONE_ID" ]] || die "CF_API_TOKEN, CF_ACCOUNT_ID and CF_ZONE_ID needed ($CONF)"; }

cf() {  # cf <METHOD> <path> [json body]: Cloudflare API call, prints .result as JSON; the token never shows in argv
  local out data=()
  need_cf
  if [[ -n "${3:-}" ]]; then data=(--data "$3"); fi
  out=$(curl -sS -m 30 -X "$1" -H "Content-Type: application/json" -H @<(printf 'Authorization: Bearer %s\n' "$CF_API_TOKEN") \
        "${data[@]}" "$CF$2") || die "Cloudflare API not reachable ($1 $2)"
  if [[ $(json '$j->{success} ? 1 : 0' <<<"$out") != 1 ]]; then
    die "Cloudflare: $1 $2 failed: $(json 'map { "$_->{code} $_->{message}" } @{$j->{errors} || []}' <<<"$out" | tr '\n' ' ')"
  fi
  json 'JSON::PP->new->canonical->encode(ref $j->{result} eq "ARRAY" ? $j->{result} : [$j->{result}])' <<<"$out"
}

valid_name() { [[ "$1" =~ ^[a-z0-9]([a-z0-9-]{0,30}[a-z0-9])?$ ]] || die "name: lowercase letters, digits, dashes (it becomes <name>.$DOMAIN)"; }
valid_ctid() { [[ "$1" =~ ^[0-9]{3,4}$ ]] || die "ctid: a number like 130"; }

tunnel_id() {  # the id of tunnel site-<name>, or nothing
  cf GET "/accounts/$CF_ACCOUNT_ID/cfd_tunnel?name=site-$1&is_deleted=false" | json 'map { $_->{id} } @$j' | head -1
}

publish() {  # publish <ctid> <name>: tunnel site-<name> -> http://127.0.0.1:80, DNS <name>.DOMAIN, token into the CT
  local ctid=$1 name=$2 host="$2.$DOMAIN" id rec
  id=$(tunnel_id "$name")
  if [[ -z "$id" ]]; then
    id=$(cf POST "/accounts/$CF_ACCOUNT_ID/cfd_tunnel" "{\"name\":\"site-$name\",\"config_src\":\"cloudflare\"}" | json '$j->[0]{id}')
    echo "tunnel site-$name created ($id)"
  else
    echo "tunnel site-$name exists ($id)"
  fi
  cf PUT "/accounts/$CF_ACCOUNT_ID/cfd_tunnel/$id/configurations" \
     "{\"config\":{\"ingress\":[{\"hostname\":\"$host\",\"service\":\"http://127.0.0.1:80\"},{\"service\":\"http_status:404\"}]}}" >/dev/null
  rec=$(cf GET "/zones/$CF_ZONE_ID/dns_records?type=CNAME&name=$host" | json 'map { $_->{id} } @$j' | head -1)
  local body="{\"type\":\"CNAME\",\"name\":\"$host\",\"content\":\"$id.cfargotunnel.com\",\"proxied\":true,\"comment\":\"pve-site ct$ctid\"}"
  if [[ -n "$rec" ]]; then cf PUT "/zones/$CF_ZONE_ID/dns_records/$rec" "$body" >/dev/null; else cf POST "/zones/$CF_ZONE_ID/dns_records" "$body" >/dev/null; fi
  echo "DNS $host -> tunnel"
  cf GET "/accounts/$CF_ACCOUNT_ID/cfd_tunnel/$id/token" | json '$j->[0]' | $PCT exec "$ctid" -- "$SITE" tunnel
}

unpublish() {
  local name=$1 host="$1.$DOMAIN" id r recs
  recs=$(cf GET "/zones/$CF_ZONE_ID/dns_records?name=$host" | json 'map { $_->{id} } @$j')
  for r in $recs; do
    cf DELETE "/zones/$CF_ZONE_ID/dns_records/$r" >/dev/null; echo "DNS $host deleted"
  done
  id=$(tunnel_id "$name")
  if [[ -n "$id" ]]; then
    cf DELETE "/accounts/$CF_ACCOUNT_ID/cfd_tunnel/$id/connections" >/dev/null || true
    cf DELETE "/accounts/$CF_ACCOUNT_ID/cfd_tunnel/$id" >/dev/null; echo "tunnel site-$name deleted"
  fi
}

valid_allow() {  # a.b.c.d:port, one IPv4 address and one TCP port, nothing wider
  local ip=${1%:*} port=${1##*:} o
  [[ "$1" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}:[0-9]{1,5}$ ]] || die "--allow-out wants one IPv4 address and port, like 192.168.1.20:8080 (got '$1')"
  for o in ${ip//./ }; do (( 10#$o <= 255 )) || die "--allow-out: $ip is not an IPv4 address"; done
  (( 10#$port >= 1 && 10#$port <= 65535 )) || die "--allow-out: port $port must be 1-65535"
}

# firewall <ctid> [--lan] [--allow-out ip:port]...: drop all inbound (LAN :80 with --lan), no LAN egress except
# the DNS server, the hub and each --allow-out target. Allow-out rules already in the CT's file are kept.
firewall() {
  local ctid=$1 lan="" net conf allow=() a; shift
  while (( $# )); do
    case $1 in
      --lan) lan=--lan; shift ;;
      --allow-out) valid_allow "${2:-}"; allow+=("$2"); shift 2 ;;
      *) die "firewall: unknown option $1" ;;
    esac
  done
  # Only site CTs: a typo must not replace the rules of some other CT (and cut it off)
  conf=$($PCT config "$ctid" 2>/dev/null) || die "CT $ctid not found"
  grep -q '^description:.*pve-site\.sh' <<<"$conf" || die "CT $ctid was not made by pve-site.sh; not touching its firewall"
  net=$(sed -n 's/^net0: //p' <<<"$conf")
  [[ -n "$net" ]] || die "CT $ctid has no net0"
  if [[ -f "$FWDIR/$ctid.fw" ]]; then
    while read -r a; do allow+=("$a"); done < <(sed -n 's/^OUT ACCEPT -dest \([0-9.]*\) -p tcp -dport \([0-9]*\) # allow-out.*/\1:\2/p' "$FWDIR/$ctid.fw")
  fi
  mkdir -p "$FWDIR"
  local rules=""
  for a in $(printf '%s\n' "${allow[@]}" | awk 'NF && !seen[$0]++'); do
    rules+="OUT ACCEPT -dest ${a%:*} -p tcp -dport ${a##*:} # allow-out (pve-site.sh)"$'\n'
  done
  cat >"$FWDIR/$ctid.fw" <<EOF
# Written by pve-site.sh (website CT). Inbound: nothing (the Cloudflare tunnel is outbound).
[OPTIONS]
enable: 1
dhcp: 1
ndp: 0
policy_in: DROP
policy_out: ACCEPT

[RULES]
$([[ "$lan" == --lan ]] && echo "IN ACCEPT -source $LAN -p tcp -dport 80 # LAN preview (--lan)" || true)
OUT ACCEPT -dest $DNS_IP -p udp -dport 53 # DNS
OUT ACCEPT -dest $DNS_IP -p tcp -dport 53 # DNS
$([[ -n "$HUB_IP" ]] && echo "OUT ACCEPT -dest $HUB_IP -p tcp -dport $HUB_PORT # hub: deploy results" || true)
${rules}OUT DROP -dest $LAN # nothing else on the LAN
OUT DROP -dest $TAILNET # nor the tailnet (Tailscale range)
EOF
  if [[ "$net" != *firewall=1* ]]; then
    net=$(sed -E 's/,?firewall=0//' <<<"$net")
    $PCT set "$ctid" --net0 "$net,firewall=1"
  fi
  echo "firewall on for CT $ctid ($FWDIR/$ctid.fw)"
}

wait_online() {  # until the CT resolves and reaches github.com (60 s)
  local i
  for i in $(seq 30); do
    $PCT exec "$1" -- curl -fsS -o /dev/null -m 5 https://github.com 2>/dev/null && return 0
    sleep 2
  done
  die "CT $1 has no internet after 60 s (DHCP? DNS $DNS_IP? firewall: $FWDIR/$1.fw)"
}

cmd_new() {
  local ctid=${1:-} name=${2:-} repo=${3:-}; shift 3 || die "usage: new <ctid> <name> <repo-url> [--branch b] [--memory MB] [--subdir d] [--lan] [--allow-out ip:port]..."
  valid_ctid "$ctid"; valid_name "$name"; need_cf
  local branch=main mem=512 subdir="" lan="" up=() fw=()
  while (( $# )); do
    case $1 in
      --branch) branch=$2; shift 2 ;;
      --memory) mem=$2; shift 2 ;;
      --subdir) subdir=$2; shift 2 ;;
      --lan) lan=--lan; fw+=(--lan); shift ;;
      --allow-out) valid_allow "${2:-}"; fw+=(--allow-out "$2"); shift 2 ;;
      *) die "unknown option $1" ;;
    esac
  done
  [[ "$mem" =~ ^[0-9]+$ ]] || die "--memory in MB"
  $PCT status "$ctid" >/dev/null 2>&1 && die "CT $ctid exists already"
  local taken
  taken=$(cf GET "/zones/$CF_ZONE_ID/dns_records?name=$name.$DOMAIN" | json 'map { $_->{id} } @$j')
  [[ -z "$taken" ]] ||
    die "$name.$DOMAIN already has a DNS record (another site? pve-site.sh unpublish $name)"

  $PCT clone "$TEMPLATE" "$ctid" --hostname "site-$name" --full --description "Website https://$name.$DOMAIN from $repo (pve-site.sh)"
  $PCT set "$ctid" --memory "$mem" --swap "$mem" --onboot 1 --nameserver "$DNS_IP" --features nesting=1,keyctl=1
  firewall "$ctid" "${fw[@]}"
  $PCT start "$ctid"
  wait_online "$ctid"
  if [[ -n "${GITHUB_TOKEN:-}" ]]; then printf '%s\n' "$GITHUB_TOKEN" | $PCT exec "$ctid" -- "$SITE" github-token; fi
  if [[ -n "${HUB_TOKEN:-}" && -n "$HUB_URL" ]]; then printf '%s\n' "$HUB_TOKEN" | $PCT exec "$ctid" -- "$SITE" hub "$HUB_URL"; fi
  up=("$SITE" up "$repo" --branch "$branch" --host "$name.$DOMAIN")
  [[ -n "$subdir" ]] && up+=(--subdir "$subdir")
  [[ -n "$lan" ]] && up+=(--lan)
  $PCT exec "$ctid" -- "${up[@]}" || die "first deploy failed (pct exec $ctid -- $SITE logs). Fix the repo, then: pct exec $ctid -- $SITE update --force && bash $0 publish $ctid $name"
  publish "$ctid" "$name"
  local i code=""
  for i in $(seq 20); do
    code=$(curl -s -o /dev/null -m 10 -w '%{http_code}' "https://$name.$DOMAIN/" || true)
    [[ "$code" =~ ^[23] ]] && break
    sleep 3
  done
  echo "https://$name.$DOMAIN -> HTTP $code"
  [[ "$code" =~ ^[23] ]] || echo "not answering yet: DNS can take a minute; check again with  curl -I https://$name.$DOMAIN"
}

cmd_rm() {
  local ctid=${1:-} name=${2:-} answer
  valid_ctid "$ctid"; valid_name "$name"; need_cf
  $PCT config "$ctid" | grep -q "pve-site.sh" || die "CT $ctid was not made by pve-site.sh; not touching it"
  read -r -p "Destroy CT $ctid and take $name.$DOMAIN offline? Type the name to confirm: " answer
  [[ "$answer" == "$name" ]] || die "not confirmed"
  unpublish "$name"
  $PCT stop "$ctid" >/dev/null 2>&1 || true
  $PCT destroy "$ctid" --purge
  rm -f "$FWDIR/$ctid.fw"
  echo "CT $ctid destroyed"
}

cmd_list() {
  echo "Cloudflare tunnels:"
  cf GET "/accounts/$CF_ACCOUNT_ID/cfd_tunnel?is_deleted=false&per_page=100" | json 'map { "  $_->{name}  $_->{status}" } grep { $_->{name} =~ /^site-/ } @$j'
  echo "Site CTs:"
  local id
  for id in $($PCT list | awk 'NR>1{print $1}'); do
    if $PCT config "$id" | grep -q "pve-site.sh"; then echo "  $id $($PCT config "$id" | sed -n 's/^hostname: //p') $($PCT status "$id" | cut -d' ' -f2)"; fi
  done
  return 0
}

[[ "${1:-}" =~ ^(new|publish|unpublish|firewall|rm|list)$ ]] && need_conf
case ${1:-} in
  new) shift; cmd_new "$@" ;;
  publish) [[ $# -eq 3 ]] || die "usage: publish <ctid> <name>"; need_cf; valid_ctid "$2"; valid_name "$3"; publish "$2" "$3" ;;
  unpublish) [[ $# -eq 2 ]] || die "usage: unpublish <name>"; need_cf; valid_name "$2"; unpublish "$2" ;;
  firewall) [[ $# -ge 2 ]] || die "usage: firewall <ctid> [--lan] [--allow-out ip:port]..."; valid_ctid "$2"; shift; firewall "$@" ;;
  rm) shift; cmd_rm "$@" ;;
  list) need_cf; cmd_list ;;
  *) sed -n '2,19p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac
