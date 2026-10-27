#!/bin/bash
# Works out how to build and serve a checked-out repo. Prints KEY=VALUE lines (shell-safe, single-quoted):
#   type=static|node|docker   kind=plain|built|server|compose|dockerfile
#   build=<command>  root=<dir to serve, "" = find after build>  start=<command>  port=<container/app port>
#   health=<path>  pm=npm|pnpm|yarn  spa=true|false
# Order (first match wins, site.toml values override): site.toml > compose > Dockerfile > package.json > index.html.
#   bash detect.sh <dir>
set -euo pipefail

dir=${1:?usage: detect.sh <dir>}
cd "$dir"

toml() {  # toml <key>: value of a top-level `key = "..."` or `key = 123` line in site.toml
  [[ -f site.toml ]] || return 0
  sed -n -E -e "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*\"([^\"]*)\".*$/\1/p" \
            -e "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*([A-Za-z0-9_.\/-]+)[[:space:]]*(#.*)?$/\1/p" site.toml | head -1
}

pkg() {  # pkg <script name>: that npm script's command, or nothing
  [[ -f package.json ]] || return 0
  node -e 'const s=(JSON.parse(require("fs").readFileSync("package.json","utf8")).scripts||{})[process.argv[1]]; if(s) console.log(s)' "$1"
}

first_index() {  # first folder of the arguments that has an index.html
  local d
  for d in "$@"; do [[ -f "$d/index.html" ]] && { echo "$d"; return; }; done
  return 0
}

type="" kind="" build="" root="" start="" port="" pm="npm"
[[ -f pnpm-lock.yaml ]] && pm=pnpm
[[ -f yarn.lock ]] && pm=yarn

compose=$(ls compose.yaml compose.yml docker-compose.yml docker-compose.yaml 2>/dev/null | head -1 || true)
if [[ -n "$compose" ]]; then
  type=docker kind=compose port=8080
elif [[ -f Dockerfile ]]; then
  type=docker kind=dockerfile
  port=$(sed -n -E 's/^[[:space:]]*EXPOSE[[:space:]]+([0-9]+).*/\1/Ip' Dockerfile | head -1)
  port=${port:-8080}
elif [[ -f package.json ]]; then
  s_start=$(pkg start) s_build=$(pkg build)
  # A "start" that only runs a dev server (Vite, Astro, CRA, …) is not a production server
  if [[ -n "$s_start" ]] && ! grep -qE '(^|[ /])(vite|astro dev|react-scripts start|gatsby develop|vue-cli-service serve|ng serve|eleventy --serve|parcel)( |$)|(^| )dev( |$)|--watch' <<<"$s_start"; then
    type=node kind=server start="$pm start" port=3000
    [[ -n "$s_build" ]] && build="$pm run build"
  elif [[ -n "$s_build" ]]; then
    type=static kind=built build="$pm run build"
  fi
fi
if [[ -z "$type" ]]; then
  root=$(first_index . public site www docs)
  [[ -n "$root" ]] && type=static kind=plain
fi

# site.toml overrides
t=$(toml type); [[ -n "$t" ]] && { [[ "$t" != "$type" ]] && kind=""; type=$t; }
v=$(toml build); [[ -n "$v" ]] && build=$v
v=$(toml root); [[ -n "$v" ]] && root=$v
v=$(toml start); [[ -n "$v" ]] && start=$v
v=$(toml port); [[ -n "$v" ]] && port=$v
health=$(toml health); health=${health:-/}
spa=$(toml spa); spa=${spa:-false}
if [[ -z "$kind" ]]; then
  case $type in
    static) kind=$([[ -n "$build" ]] && echo built || echo plain) ;;
    node) kind=server; start=${start:-$pm start}; port=${port:-3000} ;;
    docker) kind=$([[ -n "$compose" ]] && echo compose || echo dockerfile); port=${port:-8080} ;;
  esac
fi
[[ "$type" == static && "$kind" == plain && -z "$root" ]] && root=$(first_index . public site www docs)

if [[ -z "$type" ]]; then
  echo "no site type found: looked for site.toml, compose.yaml, Dockerfile, package.json (start/build), index.html in . public site www docs" >&2
  exit 3
fi
case $type in static|node|docker) ;; *) echo "site.toml: unknown type '$type' (static, node, docker)" >&2; exit 3 ;; esac
[[ "$port" =~ ^[0-9]*$ ]] || { echo "site.toml: port must be a number" >&2; exit 3; }
[[ "$health" == /* ]] || { echo "site.toml: health must start with /" >&2; exit 3; }
[[ "$root" != *..* && "$root" != /* ]] || { echo "site.toml: root must be a folder inside the repo" >&2; exit 3; }

q() { printf "%s='%s'\n" "$1" "${2//\'/\'\\\'\'}"; }
q type "$type"; q kind "$kind"; q build "$build"; q root "$root"; q start "$start"; q port "$port"
q health "$health"; q pm "$pm"; q spa "$spa"
