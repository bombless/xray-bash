#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
XRAY="${XRAY_PATH:-$ROOT/xray}"
CFG="$ROOT/config/config.json"; NODES="$ROOT/config/nodes.json"
DATA="$ROOT/data"; PID="$DATA/xray.pid"; SUB="$DATA/subscription.txt"
LOGS="$ROOT/logs"; LOG="$LOGS/xray.log"; ERR="$LOGS/xray-error.log"
mkdir -p "$ROOT/config" "$DATA" "$LOGS"

need(){ command -v "$1" >/dev/null || { echo "missing command: $1" >&2; exit 1; }; }
need_base(){ need curl; need jq; need base64; }
log(){ printf '[%s] %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$*" >> "$LOG"; }

nodes(){ [[ -s "$NODES" ]] && jq -c 'if type=="array" then . else [.] end' "$NODES" || printf '[]\n'; }
running(){ [[ -s "$PID" ]] || return 1; local p; p=$(cat "$PID" 2>/dev/null || :); [[ "$p" =~ ^[0-9]+$ ]] && kill -0 "$p" 2>/dev/null; }
cleanup_pid(){ running || rm -f "$PID"; }

b64(){ local s="$1" r; s=${s//-/+}; s=${s//_/\/}; r=$(( ${#s}%4 )); ((r==2)) && s+='=='; ((r==3)) && s+='='; printf %s "$s" | base64 -d 2>/dev/null || printf %s "$s" | base64 -D 2>/dev/null; }
urldecode(){ python3 - "$1" <<'PY'
import sys
from urllib.parse import unquote
print(unquote(sys.argv[1]))
PY
}
q(){ local query="$1" key="$2" p k v; IFS='&' read -ra a <<< "$query"; for p in "${a[@]}"; do k="${p%%=*}"; [[ $k == "$key" ]] || continue; v="${p#*=}"; [[ $p == *=* ]] || v=; urldecode "$v"; return; done; }

uri_node(){
  local u="$1" id="$2" scheme rest frag query auth host port name
  scheme="${u%%:*}"; scheme="${scheme,,}"; rest="${u#*://}"
  frag=""; [[ $rest == *'#'* ]] && { frag="${rest#*#}"; rest="${rest%%#*}"; }
  query=""; [[ $rest == *'?'* ]] && { query="${rest#*?}"; rest="${rest%%\?*}"; }
  auth=""; [[ $rest == *@* ]] && { auth="${rest%@*}"; rest="${rest#*@}"; }
  host="${rest%:*}"; port="${rest##*:}"; [[ $host == \[*\] ]] && host="${host#[}" && host="${host%]}"
  name="$(urldecode "${frag:-Node-$id}")"
  case $scheme in
    vless) jq -n --argjson id "$id" --arg name "$name" --arg address "$host" --argjson port "$port" --arg uuid "$(urldecode "$auth")" --arg type "$(q "$query" type)" --arg security "$(q "$query" security)" --arg sni "$(q "$query" sni)" --arg fp "$(q "$query" fp)" --arg pbk "$(q "$query" pbk)" --arg sid "$(q "$query" sid)" --arg flow "$(q "$query" flow)" --arg path "$(q "$query" path)" --arg host "$(q "$query" host)" '{id:$id,name:$name,protocol:"vless",address:$address,port:$port,active:false,uuid:$uuid,type:$type,security:$security,sni:$sni,fp:$fp,pbk:$pbk,sid:$sid,flow:$flow,path:$path,host:$host}' ;;
    trojan) jq -n --argjson id "$id" --arg name "$name" --arg address "$host" --argjson port "$port" --arg password "$(urldecode "$auth")" --arg type "$(q "$query" type)" --arg security "$(q "$query" security)" --arg sni "$(q "$query" sni)" --arg path "$(q "$query" path)" --arg host "$(q "$query" host)" '{id:$id,name:$name,protocol:"trojan",address:$address,port:$port,active:false,password:$password,type:$type,security:$security,sni:$sni,path:$path,host:$host}' ;;
    *) return 1;;
  esac
}

parse_sub(){
  local text="$1" line dec id=1 n out='[]'
  text="$(printf %s "$text" | tr -d '\r')"
  if ! grep -Eiq '^(vless|vmess|trojan)://' <<< "$text"; then dec="$(b64 "$(tr -d '[:space:]' <<< "$text")" || :)"; grep -Eiq '^(vless|vmess|trojan)://' <<< "$dec" && text="$dec"; fi
  while IFS= read -r line || [[ -n $line ]]; do
    line="${line#"${line%%[![:space:]]*}"}"; [[ -z $line || $line == \#* ]] && continue
    if [[ $line == vmess://* ]]; then
      dec="$(b64 "${line#vmess://}" || :)"
      if n=$(jq -c --argjson id "$id" '{id:$id,name:(.ps // ("Node-"+($id|tostring))),protocol:"vmess",address:(.add // ""),port:(.port|tonumber),uuid:(.id // ""),active:false,alterId:((.aid // 0)|tonumber),network:(.net // "tcp"),tls:(.tls // ""),type:(.type // "none"),host:(.host // ""),path:(.path // ""),serverName:(.sni // ""),fp:(.fp // "")} ' <<< "$dec" 2>/dev/null); then out=$(jq --argjson n "$n" '.+[$n]' <<< "$out"); id=$((id+1)); fi
    elif [[ $line == vless://* || $line == trojan://* ]]; then
      if n="$(uri_node "$line" "$id")"; then out="$(jq --argjson n "$n" '.+[$n]' <<< "$out")"; id=$((id+1)); fi
    fi
  done <<< "$text"
  printf '%s\n' "$out"
}

outbound(){
  local n="$1" p; p=$(jq -r .protocol <<< "$n")
  case $p in
    vmess) jq -n --arg address "$(jq -r .address <<< "$n")" --argjson port "$(jq -r .port <<< "$n")" --arg uuid "$(jq -r .uuid <<< "$n")" --argjson aid "$(jq -r '.alterId//0' <<< "$n")" --arg net "$(jq -r '.network//"tcp"' <<< "$n")" --arg tls "$(jq -r '.tls//""' <<< "$n")" --arg sni "$(jq -r '.serverName//""' <<< "$n")" --arg path "$(jq -r '.path//""' <<< "$n")" --arg host "$(jq -r '.host//""' <<< "$n")" '{protocol:"vmess",settings:{vnext:[{address:$address,port:$port,users:[{id:$uuid,alterId:$aid,security:"auto"}]}]},streamSettings:({network:$net,security:(if $tls=="tls" then "tls" else "none" end)} + (if $tls=="tls" then {tlsSettings:{serverName:$sni}} else {} end) + (if $net=="ws" then {wsSettings:{path:$path,headers:(if $host!="" then {Host:$host} else {} end)}} else {} end))}' ;;
    vless) jq -n --arg address "$(jq -r .address <<< "$n")" --argjson port "$(jq -r .port <<< "$n")" --arg uuid "$(jq -r .uuid <<< "$n")" --arg flow "$(jq -r '.flow//""' <<< "$n")" --arg net "$(jq -r '.type//"tcp"' <<< "$n")" --arg sec "$(jq -r '.security//"none"' <<< "$n")" --arg sni "$(jq -r '.sni//""' <<< "$n")" --arg fp "$(jq -r '.fp//""' <<< "$n")" --arg pbk "$(jq -r '.pbk//""' <<< "$n")" --arg sid "$(jq -r '.sid//""' <<< "$n")" --arg path "$(jq -r '.path//""' <<< "$n")" --arg host "$(jq -r '.host//""' <<< "$n")" '{protocol:"vless",settings:{vnext:[{address:$address,port:$port,users:[{id:$uuid,encryption:"none",flow:$flow}]}]},streamSettings:({network:$net,security:$sec}+if $sec=="tls" then {tlsSettings:{serverName:$sni,fingerprint:$fp}} elif $sec=="reality" then {realitySettings:{serverName:$sni,fingerprint:(if $fp!="" then $fp else "chrome" end),publicKey:$pbk,shortId:$sid}} else {} end+if $net=="ws" then {wsSettings:{path:$path,headers:(if $host!="" then {Host:$host} else {} end)}} else {} end)}' ;;
    trojan) jq -n --arg address "$(jq -r .address <<< "$n")" --argjson port "$(jq -r .port <<< "$n")" --arg password "$(jq -r .password <<< "$n")" --arg net "$(jq -r '.type//"tcp"' <<< "$n")" --arg sec "$(jq -r '.security//"tls"' <<< "$n")" --arg sni "$(jq -r '.sni//""' <<< "$n")" '{protocol:"trojan",settings:{servers:[{address:$address,port:$port,password:$password}]},streamSettings:{network:$net,security:$sec,tlsSettings:{serverName:$sni}}}' ;;
  esac
}

write_cfg(){ local n="$1" o; o="$(outbound "$n")"; jq -n --argjson o "$o" '{log:{loglevel:"warning",access:"logs/access.log",error:"logs/error.log"},inbounds:[{tag:"socks-in",listen:"127.0.0.1",port:10808,protocol:"socks",settings:{udp:true}},{tag:"http-in",listen:"127.0.0.1",port:10809,protocol:"http",settings:{}}],outbounds:[$o,{protocol:"freedom",tag:"direct"}],routing:{domainStrategy:"AsIs",rules:[]}}' > "$CFG"; }

test_cfg(){ [[ -x $XRAY ]] || { echo "xray not executable: $XRAY" >&2; return 1; }; "$XRAY" run -test -c "$CFG" >>"$LOG" 2>>"$ERR"; }
start(){ cleanup_pid; running && { echo "Xray is already running. PID $(cat "$PID")"; return; }; test_cfg || { echo 'configuration validation failed' >&2; return 1; }; nohup "$XRAY" run -c "$CFG" >>"$LOG" 2>>"$ERR" & echo $! > "$PID"; sleep .2; running || { rm -f "$PID"; echo "start failed; see $ERR" >&2; return 1; }; log "Started Xray PID=$(cat "$PID")"; echo "Xray started. PID $(cat "$PID")"; }
stop(){ cleanup_pid; running || { echo 'Xray is not running.'; return; }; local p=$(cat "$PID"); kill "$p" 2>/dev/null || :; for _ in {1..20}; do running || break; sleep .1; done; running && kill -9 "$p" 2>/dev/null || :; rm -f "$PID"; log "Stopped Xray PID=$p"; echo 'Xray stopped.'; }
restart(){ stop; sleep .3; start; }
update(){ need_base; local url="${1:-}"; [[ -n $url ]] || [[ -s "$DATA/subscription-url.txt" ]] && url="$(<"$DATA/subscription-url.txt")"; [[ -n $url ]] || { echo 'usage: xray.sh update <url>' >&2; return 1; }; local c n count; c="$(curl -fsSL --compressed -A 'v2rayA/debug WebRequestHelper' "$url")" || return 1; printf '%s\n' "$c" > "$SUB"; n="$(parse_sub "$c")"; count=$(jq length <<< "$n"); ((count>0)) || { echo 'no supported nodes found' >&2; return 1; }; jq . <<< "$n" > "$NODES"; log "parsedNodes=$count"; echo "Parsed $count nodes."; }
list(){ need jq; local n; n=$(nodes); (( $(jq length <<< "$n") )) || { echo 'No nodes. Run update first.'; return; }; jq -r '.[] | [.id, .name, .protocol, (.address + ":" + (.port|tostring))] | @tsv' <<< "$n"; }
select_node(){ need jq; local id="${1:-}" n node; [[ $id =~ ^[0-9]+$ ]] || return 1; n=$(nodes); node=$(jq -c --argjson id "$id" '.[]|select(.id==$id)' <<< "$n"|head -n1); [[ -n $node ]] || { echo "Node $id not found." >&2; return 1; }; jq --argjson id "$id" 'map(.active=(.id==$id))' <<< "$n" > "$NODES"; write_cfg "$node"; echo "Selected: $(jq -r .name <<< "$node")"; [[ ${NO_START:-0} == 1 ]] || restart; }
current(){ need jq; local n=$(nodes); jq '.[]|select(.active==true)' <<< "$n"; }
status(){ cleanup_pid; running && { echo "Xray: Running"; echo "PID: $(cat "$PID")"; } || echo 'Xray: Stopped'; local a=$(nodes|jq -r '.[]|select(.active==true)|.name'|head -n1); [[ -n $a ]] && echo "Node: $a"; echo 'SOCKS5: 127.0.0.1:10808'; echo 'HTTP:   127.0.0.1:10809'; }
test_node(){ need curl; local id="$1" n node t0 t1; n=$(nodes); node=$(jq -c --argjson id "$id" '.[]|select(.id==$id)' <<< "$n"|head -n1); [[ -n $node ]] || return 1; write_cfg "$node"; start >/dev/null || return 1; t0=$(date +%s%3N); if curl -fsS --max-time 10 -x http://127.0.0.1:10809 https://www.gstatic.com/generate_204 -o /dev/null; then t1=$(date +%s%3N); printf '%s\t%s ms\tOK\n' "$(jq -r .name <<< "$node")" "$((t1-t0))"; else printf '%s\t-\tFAILED\n' "$(jq -r .name <<< "$node")"; fi; stop >/dev/null; }
test_all(){ local id="${1:-}"; [[ -n $id ]] && { test_node "$id"; return; }; while read -r id; do test_node "$id" || :; done < <(nodes|jq -r '.[].id'); }
help(){ cat <<'EOF'
xray.sh commands:
  update [url]       Download and parse subscription
  list               List nodes
  select <id>        Select node and restart Xray
  current            Show active node
  status             Show Xray status
  test [id]           Test one/all nodes through HTTP proxy
  start|stop|restart  Manage Xray

Requires: curl, jq, base64; python3 is used for URI decoding.
Put the Xray binary at ./xray or set XRAY_PATH=/path/to/xray.
Set NO_START=1 to avoid restarting after select.
EOF
}
case "${1:-help}" in
 update) update "${2:-}";; list) list;; select) select_node "${2:-}";; current) current;; status) status;; test) test_all "${2:-}";; start) start;; stop) stop;; restart) restart;; -h|--help|help) help;; *) echo "Unknown command: $1" >&2; help; exit 1;; esac
