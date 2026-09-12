#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
XRAY_PATH="${XRAY_PATH:-$ROOT/xray}"
CONFIG_DIR="$ROOT/config"
CONFIG_PATH="$CONFIG_DIR/config.json"
NODES_PATH="$CONFIG_DIR/nodes.json"
DATA_DIR="$ROOT/data"
PID_PATH="$DATA_DIR/xray.pid"
SUBSCRIPTION_PATH="$DATA_DIR/subscription.txt"
LOG_DIR="$ROOT/logs"
LOG_PATH="$LOG_DIR/xray.log"
ERROR_LOG_PATH="$LOG_DIR/xray-error.log"

SOCKS_HOST=127.0.0.1
SOCKS_PORT=10808
HTTP_HOST=127.0.0.1
HTTP_PORT=10809

mkdir -p "$CONFIG_DIR" "$DATA_DIR" "$LOG_DIR"

log() {
  printf '[%s] %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$*" >> "$LOG_PATH"
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || { echo "Missing required command: $1" >&2; exit 1; }
}

require_base_deps() {
  require_cmd curl
  require_cmd jq
  require_cmd base64
}

pid_alive() {
  [[ -s "$PID_PATH" ]] || return 1
  local pid
  pid="$(cat "$PID_PATH" 2>/dev/null || true)"
  [[ "$pid" =~ ^[0-9]+$ ]] || return 1
  kill -0 "$pid" 2>/dev/null
}

get_pid() {
  pid_alive || return 1
  cat "$PID_PATH"
}

cleanup_stale_pid() {
  if [[ -s "$PID_PATH" ]] && ! pid_alive; then
    rm -f "$PID_PATH"
  fi
}

port_in_use() {
  local host="$1" port="$2"
  if command -v ss >/dev/null 2>&1; then
    ss -H -ltn "sport = :$port" 2>/dev/null | grep -q .
  elif command -v netstat >/dev/null 2>&1; then
    netstat -lnt 2>/dev/null | awk -v p=":$port" '$4 ~ p"$" {found=1} END {exit !found}'
  else
    return 1
  fi
}

json_url_decode() {
  local value="$1"
  if command -v python3 >/dev/null 2>&1; then
    python3 - "$value" <<'PY'
import sys
from urllib.parse import unquote
print(unquote(sys.argv[1]))
PY
  else
    printf '%s\n' "$value" | sed 's/+/ /g; s/%/\\x/g' | xargs -0 printf '%b\n' 2>/dev/null || printf '%s\n' "$value"
  fi
}

b64_decode() {
  local text="$1"
  text="${text//-/+}"
  text="${text//_/\/}"
  local rem=$(( ${#text} % 4 ))
  (( rem == 2 )) && text+='=='
  (( rem == 3 )) && text+='='
  printf '%s' "$text" | base64 -d 2>/dev/null || printf '%s' "$text" | base64 -D 2>/dev/null
}

read_nodes() {
  [[ -f "$NODES_PATH" ]] || printf '[]\n'
  [[ -s "$NODES_PATH" ]] || printf '[]\n'
  jq -c 'if type == "array" then . else [.] end' "$NODES_PATH" 2>/dev/null || printf '[]\n'
}

save_nodes() {
  local json="$1"
  printf '%s\n' "$json" | jq '.' > "$NODES_PATH"
}

read_config() {
  [[ -f "$CONFIG_PATH" ]] && cat "$CONFIG_PATH" || true
}

test_config() {
  [[ -x "$XRAY_PATH" ]] || { echo "xray binary not found or not executable: $XRAY_PATH" >&2; return 1; }
  [[ -f "$CONFIG_PATH" ]] || { echo "config.json not found: $CONFIG_PATH" >&2; return 1; }
  "$XRAY_PATH" run -test -c "$CONFIG_PATH" >> "$LOG_PATH" 2>> "$ERROR_LOG_PATH"
}

start_xray() {
  cleanup_stale_pid
  if pid_alive; then
    echo "Xray is already running. PID: $(cat "$PID_PATH")"
    return 0
  fi
  test_config || { echo "Xray configuration validation failed." >&2; return 1; }
  port_in_use "$SOCKS_HOST" "$SOCKS_PORT" && { echo "SOCKS5 port $SOCKS_PORT is already in use." >&2; return 1; }
  port_in_use "$HTTP_HOST" "$HTTP_PORT" && { echo "HTTP port $HTTP_PORT is already in use." >&2; return 1; }

  nohup "$XRAY_PATH" run -c "$CONFIG_PATH" >> "$LOG_PATH" 2>> "$ERROR_LOG_PATH" &
  local pid=$!
  printf '%s\n' "$pid" > "$PID_PATH"
  sleep 0.2
  if ! pid_alive; then
    rm -f "$PID_PATH"
    echo "Xray failed to start; see $ERROR_LOG_PATH" >&2
    return 1
  fi
  log "Started Xray PID=$pid"
  echo "Xray started. PID: $pid"
}

stop_xray() {
  cleanup_stale_pid
  if ! pid_alive; then
    echo 'Xray is not running.'
    return 0
  fi
  local pid
  pid="$(cat "$PID_PATH")"
  kill "$pid" 2>/dev/null || true
  for _ in {1..20}; do
    pid_alive || break
    sleep 0.1
  done
  if pid_alive; then
    kill -9 "$pid" 2>/dev/null || true
  fi
  rm -f "$PID_PATH"
  log "Stopped Xray PID=$pid"
  echo 'Xray stopped.'
}

restart_xray() {
  stop_xray
  sleep 0.3
  start_xray
}

show_status() {
  cleanup_stale_pid
  local nodes active
  nodes="$(read_nodes)"
  active="$(jq -r '.[] | select(.active == true) | .name' <<<"$nodes" | head -n1)"
  if pid_alive; then
    echo "Xray: Running"
    echo "PID: $(cat "$PID_PATH")"
  else
    echo 'Xray: Stopped'
  fi
  [[ -n "$active" ]] && echo "Node: $active"
  echo "SOCKS5: $SOCKS_HOST:$SOCKS_PORT"
  echo "HTTP:   $HTTP_HOST:$HTTP_PORT"
}

parse_query_value() {
  local query="$1" key="$2" pair k v
  IFS='&' read -ra pairs <<< "$query"
  for pair in "${pairs[@]}"; do
    k="${pair%%=*}"
    [[ "$k" == "$key" ]] || continue
    v="${pair#*=}"
    [[ "$pair" == *=* ]] || v=''
    json_url_decode "$v"
    return 0
  done
  return 1
}

new_node_from_uri() {
  local uri="$1" id="$2" scheme rest userinfo hostport query fragment name host port uuid password
  scheme="${uri%%:*}"
  scheme="${scheme,,}"
  rest="${uri#*://}"
  fragment=''
  if [[ "$rest" == *'#'* ]]; then fragment="${rest#*#}"; rest="${rest%%#*}"; fi
  query=''
  if [[ "$rest" == *'?'* ]]; then query="${rest#*?}"; rest="${rest%%\?*}"; fi
  userinfo=''
  if [[ "$rest" == *@* ]]; then userinfo="${rest%@*}"; rest="${rest#*@}"; fi
  hostport="$rest"
  host="${hostport%:*}"
  port="${hostport##*:}"
  [[ "$host" == \[*\] ]] && host="${host#[}" && host="${host%]}"
  name="$(json_url_decode "${fragment:-Node-$id}")"

  case "$scheme" in
    vless)
      uuid="$(json_url_decode "$userinfo")"
      local type security sni fp pbk sid flow path mode alpn vhost
      type="$(parse_query_value "$query" type || true)"
      security="$(parse_query_value "$query" security || true)"
      sni="$(parse_query_value "$query" sni || true)"
      fp="$(parse_query_value "$query" fp || true)"
      pbk="$(parse_query_value "$query" pbk || true)"
      sid="$(parse_query_value "$query" sid || true)"
      flow="$(parse_query_value "$query" flow || true)"
      path="$(parse_query_value "$query" path || true)"
      mode="$(parse_query_value "$query" mode || true)"
      alpn="$(parse_query_value "$query" alpn || true)"
      vhost="$(parse_query_value "$query" host || true)"
      jq -n --argjson id "$id" --arg name "$name" --arg protocol vless --arg address "$host" --argjson port "$port" --arg uuid "$uuid" --arg type "$type" --arg security "$security" --arg sni "$sni" --arg fp "$fp" --arg pbk "$pbk" --arg sid "$sid" --arg flow "$flow" --arg path "$path" --arg mode "$mode" --arg alpn "$alpn" --arg host "$vhost" '{id:$id,name:$name,protocol:$protocol,address:$address,port:$port,active:false,uuid:$uuid,type:$type,security:$security,sni:$sni,fp:$fp,pbk:$pbk,sid:$sid,flow:$flow,path:$path,mode:$mode,alpn:$alpn,host:$host}'
      ;;
    trojan)
      password="$(json_url_decode "$userinfo")"
      local type security sni fp path mode alpn vhost
      type="$(parse_query_value "$query" type || true)"
      security="$(parse_query_value "$query" security || true)"
      sni="$(parse_query_value "$query" sni || true)"
      fp="$(parse_query_value "$query" fp || true)"
      path="$(parse_query_value "$query" path || true)"
      mode="$(parse_query_value "$query" mode || true)"
      alpn="$(parse_query_value "$query" alpn || true)"
      vhost="$(parse_query_value "$query" host || true)"
      jq -n --argjson id "$id" --arg name "$name" --arg protocol trojan --arg address "$host" --argjson port "$port" --arg password "$password" --arg type "$type" --arg security "$security" --arg sni "$sni" --arg fp "$fp" --arg path "$path" --arg mode "$mode" --arg alpn "$alpn" --arg host "$vhost" '{id:$id,name:$name,protocol:$protocol,address:$address,port:$port,active:false,password:$password,type:$type,security:$security,sni:$sni,fp:$fp,path:$path,mode:$mode,alpn:$alpn,host:$host}'
      ;;
    *) return 1 ;;
  esac
}

parse_subscription() {
  local content="$1" text line decoded id=1 node nodes='[]'
  text="$(printf '%s' "$content" | tr -d '\r')"
  if ! grep -Eiq '^(vless|vmess|trojan|ss)://' <<< "$text"; then
    decoded="$(b64_decode "$(printf '%s' "$text" | tr -d '[:space:]')" || true)"
    if grep -Eiq '^(vless|vmess|trojan|ss)://' <<< "$decoded"; then text="$decoded"; fi
  fi

  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line##+([[:space:]])}" 2>/dev/null || true
    [[ -z "$line" || "$line" == \#* ]] && continue
    if [[ "$line" == vmess://* ]]; then
      decoded="$(b64_decode "${line#vmess://}" || true)"
      if [[ -z "$decoded" ]]; then log 'Failed to Base64-decode VMess entry.'; continue; fi
      if node="$(jq -c --argjson id "$id" '({id:$id,name:(.ps // ("Node-"+($id|tostring))),protocol:"vmess",address:(.add // ""),port:(.port|tonumber),uuid:(.id // ""),active:false,alterId:((.aid // 0)|tonumber),security:"auto",network:(.net // "tcp"),tls:(.tls // ""),type:(.type // "none"),host:(.host // ""),path:(.path // ""),serverName:(.sni // ""),alpn:(.alpn // ""),fp:(.fp // "")})' <<< "$decoded" 2>/dev/null); then
        nodes="$(jq --argjson n "$node" '. + [$n]' <<< "$nodes")"
        id=$((id+1))
      else
        log 'Failed to parse VMess JSON.'
      fi
    elif [[ "$line" == vless://* || "$line" == trojan://* ]]; then
      if node="$(new_node_from_uri "$line" "$id")"; then
        nodes="$(jq --argjson n "$node" '. + [$n]' <<< "$nodes")"
        id=$((id+1))
      fi
    fi
  done <<< "$text"
  printf '%s\n' "$nodes"
}

update_subscription() {
  require_base_deps
  local url="${1:-}"
  if [[ -z "$url" ]]; then
    if [[ -f "$DATA_DIR/subscription-url.txt" ]]; then url="$(<"$DATA_DIR/subscription-url.txt")"; fi
  fi
  [[ -n "$url" ]] || { echo 'Specify a subscription URL: ./xray.sh update <url>' >&2; return 1; }
  echo 'Updating subscription...'
  local content nodes count
  content="$(curl -fsSL --compressed -A 'v2rayA/debug WebRequestHelper' "$url")" || { echo 'Subscription download failed.' >&2; return 1; }
  printf '%s\n' "$content" > "$SUBSCRIPTION_PATH"
  nodes="$(parse_subscription "$content")"
  count="$(jq 'length' <<< "$nodes")"
  log "Subscription bytes=${#content} parsedNodes=$count"
  (( count > 0 )) || { echo 'Subscription returned no supported nodes (vmess/vless/trojan).' >&2; return 1; }
  save_nodes "$nodes"
  echo "Parsed $count nodes."
}

show_nodes() {
  require_cmd jq
  local nodes
  nodes="$(read_nodes)"
  if [[ "$(jq 'length' <<< "$nodes")" -eq 0 ]]; then echo 'No nodes. Run update first.'; return; fi
  jq -r '.[] | "\(.id)\t\(.name)\t\(.protocol)\t\(.address):\(.port)"' <<< "$nodes" | column -t -s $'\t' 2>/dev/null || jq -r '.[] | "\(.id)\t\(.name)\t\(.protocol)\t\(.address):\(.port)"' <<< "$nodes"
}

new_xray_outbound() {
  local node="$1" protocol network security
  protocol="$(jq -r '.protocol' <<< "$node")"
  case "$protocol" in
    vmess)
      network="$(jq -r '.network // "tcp"' <<< "$node")"
      security='none'; [[ "$(jq -r '.tls // ""' <<< "$node")" == tls ]] && security=tls
      jq -n --arg address "$(jq -r '.address' <<< "$node")" --argjson port "$(jq -r '.port' <<< "$node")" --arg uuid "$(jq -r '.uuid' <<< "$node")" --argjson alterId "$(jq -r '.alterId // 0' <<< "$node")" --arg network "$network" --arg security "$security" --arg sni "$(jq -r '.serverName // ""' <<< "$node")" --arg fp "$(jq -r '.fp // ""' <<< "$node")" --arg path "$(jq -r '.path // ""' <<< "$node")" --arg host "$(jq -r '.host // ""' <<< "$node")" '
        {protocol:"vmess",settings:{vnext:[{address:$address,port:$port,users:[{id:$uuid,alterId:$alterId,security:"auto"}]}]},streamSettings:({network:$network,security:$security} + (if $security=="tls" then {tlsSettings:({} + (if $sni!="" then {serverName:$sni} else {} end) + (if $fp!="" then {fingerprint:$fp} else {} end))} else {} end) + (if $network=="ws" then {wsSettings:({} + (if $path!="" then {path:$path} else {} end) + (if $host!="" then {headers:{Host:$host}} else {} end))} else {} end))}'
      ;;
    vless)
      network="$(jq -r '.type // "tcp"' <<< "$node")"; security="$(jq -r '.security // "none"' <<< "$node")"
      jq -n --arg address "$(jq -r '.address' <<< "$node")" --argjson port "$(jq -r '.port' <<< "$node")" --arg uuid "$(jq -r '.uuid' <<< "$node")" --arg flow "$(jq -r '.flow // ""' <<< "$node")" --arg network "$network" --arg security "$security" --arg sni "$(jq -r '.sni // ""' <<< "$node")" --arg fp "$(jq -r '.fp // ""' <<< "$node")" --arg pbk "$(jq -r '.pbk // ""' <<< "$node")" --arg sid "$(jq -r '.sid // ""' <<< "$node")" --arg path "$(jq -r '.path // ""' <<< "$node")" --arg host "$(jq -r '.host // ""' <<< "$node")" '
        {protocol:"vless",settings:{vnext:[{address:$address,port:$port,users:[{id:$uuid,encryption:"none",flow:$flow}]}]},streamSettings:({network:$network,security:$security} + (if $security=="tls" then {tlsSettings:({} + (if $sni!="" then {serverName:$sni} else {} end) + (if $fp!="" then {fingerprint:$fp} else {} end))} elif $security=="reality" then {realitySettings:{serverName:$sni,fingerprint:(if $fp!="" then $fp else "chrome" end),publicKey:$pbk,shortId:$sid}} else {} end) + (if $network=="ws" then {wsSettings:({} + (if $path!="" then {path:$path} else {} end) + (if $host!="" then {headers:{Host:$host}} else {} end))} else {} end))}'
      ;;
    trojan)
      network="$(jq -r '.type // "tcp"' <<< "$node")"; security="$(jq -r '.security // "tls"' <<< "$node")"
      jq -n --arg address "$(jq -r '.address' <<< "$node")" --argjson port "$(jq -r '.port' <<< "$node")" --arg password "$(jq -r '.password' <<< "$node")" --arg network "$network" --arg security "$security" --arg sni "$(jq -r '.sni // ""' <<< "$node")" '{protocol:"trojan",settings:{servers:[{address:$address,port:$port,password:$password}]},streamSettings:{network:$network,security:$security,tlsSettings:{serverName:$sni}}}'
      ;;
    *) echo "Unsupported protocol: $protocol" >&2; return 1 ;;
  esac
}

write_config_for_node() {
  require_cmd jq
  local node="$1" outbound config
  outbound="$(new_xray_outbound "$node")"
  config="$(jq -n --argjson outbound "$outbound" '{log:{loglevel:"warning",access:"logs/access.log",error:"logs/error.log"},inbounds:[{tag:"socks-in",listen:"127.0.0.1",port:10808,protocol:"socks",settings:{udp:true}},{tag:"http-in",listen:"127.0.0.1",port:10809,protocol:"http",settings:{}}],outbounds:[$outbound,{protocol:"freedom",tag:"direct"}],routing:{domainStrategy:"AsIs",rules:[]}}')"
  printf '%s\n' "$config" | jq '.' > "$CONFIG_PATH"
}

select_node() {
  require_cmd jq
  local id="${1:-}" nodes node updated
  [[ "$id" =~ ^[0-9]+$ ]] || { echo 'Usage: ./xray.sh select <id>' >&2; return 1; }
  nodes="$(read_nodes)"
  node="$(jq -c --argjson id "$id" '.[] | select(.id == $id)' <<< "$nodes" | head -n1)"
  [[ -n "$node" ]] || { echo "Node $id not found." >&2; return 1; }
  updated="$(jq --argjson id "$id" 'map(.active = (.id == $id))' <<< "$nodes")"
  save_nodes "$updated"
  write_config_for_node "$node"
  echo "Selected: $(jq -r '.name' <<< "$node")"
  if [[ "${NO_START:-0}" != 1 ]]; then restart_xray; fi
}

show_current() {
  require_cmd jq
  local node
  node="$(read_nodes | jq -c '.[] | select(.active == true)' | head -n1)"
  if [[ -n "$node" ]]; then jq '.' <<< "$node"; else echo 'No active node.'; fi
}

test_node() {
  require_cmd curl
  local id="${1:-}" node started=0 start_ms end_ms
  node="$(read_nodes | jq -c --argjson id "$id" '.[] | select(.id == $id)' | head -n1)"
  [[ -n "$node" ]] || { echo "Node $id not found." >&2; return 1; }
  if ! pid_alive; then write_config_for_node "$node"; start_xray; started=1; fi
  start_ms="$(date +%s%3N 2>/dev/null || date +%s000)"
  if curl -fsS --max-time 10 -x "http://$HTTP_HOST:$HTTP_PORT" https://www.gstatic.com/generate_204 -o /dev/null; then
    end_ms="$(date +%s%3N 2>/dev/null || date +%s000)"
    echo "$(jq -r '.name' <<< "$node")\t$((end_ms-start_ms)) ms\tOK"
  else
    echo "$(jq -r '.name' <<< "$node")\t-\tFAILED"
  fi
  (( started == 1 )) && stop_xray >/dev/null
}

test_all() {
  require_cmd jq
  local only="${1:-}" nodes n id
  nodes="$(read_nodes)"
  (( $(jq 'length' <<< "$nodes") > 0 )) || { echo 'No nodes. Run update first.' >&2; return 1; }
  if [[ -n "$only" ]]; then test_node "$only"; return; fi
  while IFS= read -r id; do test_node "$id" || true; done < <(jq -r '.[].id' <<< "$nodes")
}

show_help() {
  cat <<'EOF'
xray.sh commands:
  update [url]             Update and parse a subscription
  list                     List nodes
  select <id>              Select a node and restart Xray
  current                  Show selected node
  status                   Show Xray status
  test [id]                Test one/all nodes
  stop                     Stop Xray
  start                    Start Xray
  restart                  Restart Xray

Environment:
  XRAY_PATH=/path/to/xray  Override the Xray binary path
  NO_START=1               Do not restart Xray after select
EOF
}

command="${1:-help}"
case "${command,,}" in
  update) update_subscription "${2:-}" ;;
  list) show_nodes ;;
  select) select_node "${2:-}" ;;
  current) show_current ;;
  status) show_status ;;
  test) test_all "${2:-}" ;;
  start) start_xray ;;
  stop) stop_xray ;;
  restart) restart_xray ;;
  help|--help|-h) show_help ;;
  *) echo "Unknown command: $command" >&2; show_help; exit 1 ;;
esac
