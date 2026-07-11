#!/bin/bash
# ===================================================================
# VLESS+WS+Argo 一键部署 —— serv00/ct8 专版（最终修正版）
# 修正：配置文件扩展名改为 .json，确保新版 Xray 识别
# ===================================================================

if [ -z "$BASH_VERSION" ]; then
    if command -v bash >/dev/null 2>&1; then
        exec bash "$0" "$@"
    else
        echo "本脚本需要 bash" >&2
        exit 1
    fi
fi

re="\033[0m"
red() { echo -e "\e[1;91m$1\033[0m"; }
green() { echo -e "\e[1;32m$1\033[0m"; }
yellow() { echo -e "\e[1;33m$1\033[0m"; }
purple() { echo -e "\e[1;35m$1\033[0m"; }
export LC_ALL=C

ACTION="${1:-install}"
case "$ACTION" in
    install|re|update|de|status) ;;
    *) red "未知参数: ${ACTION}"; exit 1 ;;
esac

HAVE_CURL=0; command -v curl >/dev/null 2>&1 && HAVE_CURL=1
HAVE_WGET=0; command -v wget >/dev/null 2>&1 && HAVE_WGET=1
[ "$HAVE_CURL" = 0 ] && [ "$HAVE_WGET" = 0 ] && { red "需要 curl 或 wget"; exit 1; }

IS_TTY=0; [ -t 1 ] && IS_TTY=1

fetch_with_retry() {
    local url="$1" out="$2" attempt=0 max_attempts=3
    while [ $attempt -lt $max_attempts ]; do
        attempt=$((attempt + 1))
        if [ "$HAVE_CURL" = 1 ]; then
            if [ "$IS_TTY" = 1 ]; then
                curl -fL --progress-bar --connect-timeout 10 --max-time 120 --retry 2 --retry-delay 2 -o "$out" "$url" && return 0
            else
                curl -fL -sS --connect-timeout 10 --max-time 120 --retry 2 --retry-delay 2 -o "$out" "$url" && return 0
            fi
        else
            if [ "$IS_TTY" = 1 ]; then
                wget -T 10 -t 1 -O "$out" "$url" && return 0
            else
                wget -q -T 10 -t 1 -O "$out" "$url" && return 0
            fi
        fi
        yellow "下载失败(第 ${attempt} 次): ${url}，2秒后重试..."
        sleep 2
    done
    red "下载失败,已重试 ${max_attempts} 次,放弃: ${url}"
    return 1
}

safe_rm() {
    local target
    if [ -z "$BIN_DIR" ] || [ -z "$WORKDIR" ] || [ -z "$FILE_PATH" ] || [ -z "$HOME" ]; then
        red "safe_rm: 关键变量为空,跳过删除"
        return 1
    fi
    for target in "$@"; do
        case "$target" in
            "$BIN_DIR"|"$BIN_DIR"/*|"$WORKDIR"|"$WORKDIR"/*|"$FILE_PATH"|"$FILE_PATH"/*)
                rm -rf -- "$target"
                ;;
            *)
                yellow "safe_rm: 拒绝删除不在白名单内的路径 [${target}]"
                ;;
        esac
    done
}

graceful_kill_pidfile() {
    local pidfile="$1" pid i
    [ -f "$pidfile" ] || return 0
    pid=$(cat "$pidfile" 2>/dev/null)
    [ -z "$pid" ] && return 0
    if kill -0 "$pid" >/dev/null 2>&1; then
        kill "$pid" >/dev/null 2>&1
        for i in 1 2 3 4 5; do
            kill -0 "$pid" >/dev/null 2>&1 || break
            sleep 0.5
        done
        kill -0 "$pid" >/dev/null 2>&1 && kill -9 "$pid" >/dev/null 2>&1
    fi
}

if ! command -v devil >/dev/null 2>&1; then
    red "未检测到 devil 命令,本脚本是 serv00/ct8 专版"
    exit 1
fi

HOSTNAME=$(hostname)
USERNAME=$(whoami | tr '[:upper:]' '[:lower:]')

if [[ "$HOSTNAME" =~ ct8 ]]; then
    CURRENT_DOMAIN="ct8.pl"
elif [[ "$HOSTNAME" =~ hostuno ]]; then
    CURRENT_DOMAIN="useruno.com"
else
    CURRENT_DOMAIN="serv00.net"
fi
WORKDIR="${HOME}/domains/${USERNAME}.${CURRENT_DOMAIN}/logs"
FILE_PATH="${HOME}/domains/${USERNAME}.${CURRENT_DOMAIN}/public_html"
BIN_DIR="${HOME}/.oceanus"
STATE_FILE="${BIN_DIR}/.current.log"

# 伪装文件名（关键修改：config.json -> service.json，保留 .json 扩展名）
CONFIG_FILE="service.json"
CRED_FILE="cache.db"
TUNNEL_CONFIG="state.dat"

load_state() {
    [ -f "$STATE_FILE" ] || return 0
    # shellcheck disable=SC1090
    source "$STATE_FILE"
}
save_state() {
    mkdir -p "$BIN_DIR"
    cat > "$STATE_FILE" <<EOF
SAVED_USERNAME=$(printf '%q' "$USERNAME")
SAVED_UUID=$(printf '%q' "$UUID")
SAVED_PORT=$(printf '%q' "$PORT")
SAVED_ARGO_DOMAIN=$(printf '%q' "$ARGO_DOMAIN")
SAVED_ARGO_AUTH=$(printf '%q' "$ARGO_AUTH")
SAVED_CFIP=$(printf '%q' "$CFIP")
SAVED_CFPORT=$(printf '%q' "$CFPORT")
SAVED_SUB_TOKEN=$(printf '%q' "$SUB_TOKEN")
SAVED_TG_TOKEN=$(printf '%q' "$TG_TOKEN")
SAVED_TG_ID=$(printf '%q' "$TG_ID")
SAVED_BOT_ARGS=$(printf '%q' "$args")
SAVED_WORKDIR=$(printf '%q' "$WORKDIR")
SAVED_FILE_PATH=$(printf '%q' "$FILE_PATH")
SAVED_WARP=$(printf '%q' "$WARP")
SAVED_CONFIG_FILE=$(printf '%q' "$CONFIG_FILE")
EOF
    chmod 600 "$STATE_FILE" >/dev/null 2>&1
}
get_xray_version_string() {
    echo "未知(serv00 使用的是第三方重命名二进制,不支持查询版本)"
}

HEALTH_MARK="sys_mon"
HEALTH_SCRIPT="${BIN_DIR}/monitor.sh"
HEALTH_STATE="${BIN_DIR}/.mon_state"

remove_healthcheck_schedule() {
    if command -v crontab >/dev/null 2>&1; then
        ( crontab -l 2>/dev/null | grep -v "$HEALTH_MARK" ) | crontab - 2>/dev/null
    fi
}

do_uninstall() {
    purple "正在卸载 vless-argo 并清理相关文件..."
    remove_healthcheck_schedule
    graceful_kill_pidfile "${BIN_DIR}/web.pid"
    graceful_kill_pidfile "${BIN_DIR}/bot.pid"
    pkill -f "${BIN_DIR}/web" >/dev/null 2>&1
    pkill -f "${BIN_DIR}/bot" >/dev/null 2>&1
    devil www del "${USERNAME}.${CURRENT_DOMAIN}" >/dev/null 2>&1
    devil www del "keep.${USERNAME}.${CURRENT_DOMAIN}" >/dev/null 2>&1
    safe_rm "$WORKDIR" "$FILE_PATH" "$BIN_DIR"
    green "卸载完成"
}

if [ "$ACTION" = "de" ]; then
    do_uninstall
    exit 0
fi

if [ "$ACTION" = "re" ] || [ "$ACTION" = "update" ] || [ "$ACTION" = "status" ]; then
    load_state
fi
[ "$ACTION" = "update" ] && FORCE_REDOWNLOAD=1

json_escape() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\n'/\\n}"
    s="${s//$'\r'/}"
    s="${s//$'\t'/\\t}"
    printf '%s' "$s"
}

sed_repl_escape() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//&/\\&}"
    s="${s//|/\\|}"
    printf '%s' "$s"
}

export UUID=${UUID:-${SAVED_UUID:-$(cat /proc/sys/kernel/random/uuid 2>/dev/null || echo -n "$USERNAME+$HOSTNAME" | md5sum | head -c 32 | sed -E 's/(.{8})(.{4})(.{4})(.{4})(.{12})/\1-\2-\3-\4-\5/')}}
if ! [[ "$UUID" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]; then
    red "UUID 格式不合法: $UUID"
    exit 1
fi
export ARGO_DOMAIN=${ARGO_DOMAIN:-${SAVED_ARGO_DOMAIN:-''}}
if [ -n "$ARGO_DOMAIN" ] && ! [[ "$ARGO_DOMAIN" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)+$ ]]; then
    red "ARGO_DOMAIN 格式不合法: $ARGO_DOMAIN"
    exit 1
fi
export ARGO_AUTH=${ARGO_AUTH:-${SAVED_ARGO_AUTH:-''}}
export CFIP=${CFIP:-${SAVED_CFIP:-'saas.sin.fan'}}
export CFPORT=${CFPORT:-${SAVED_CFPORT:-'443'}}
export SUB_TOKEN=${SUB_TOKEN:-${SAVED_SUB_TOKEN:-${UUID:0:8}}}
export TG_TOKEN=${TG_TOKEN:-${SAVED_TG_TOKEN:-''}}
export TG_ID=${TG_ID:-${SAVED_TG_ID:-''}}

if [ "$WARP" = "1" ]; then
    export WARP=1
else
    export WARP=0
fi
WARP_PROFILE="${BIN_DIR}/.wg.env"

do_status() {
    echo "===================== vless-argo 状态 ====================="
    if [ ! -f "$STATE_FILE" ]; then
        yellow "未找到安装记录(${STATE_FILE} 不存在)"
    fi
    echo "UUID         : ${UUID}"
    echo "端口(PORT)   : ${SAVED_PORT:-<尚未分配>}"
    echo "ARGO_DOMAIN  : ${ARGO_DOMAIN:-<未设置,使用quick tunnel>}"
    echo "ARGO_AUTH    : $([ -n "$ARGO_AUTH" ] && echo '已设置' || echo '<未设置>')"
    echo "Xray 版本     : $(get_xray_version_string)"
    if [ -n "$TG_TOKEN" ] && [ -n "$TG_ID" ]; then
        green "TG心跳监控   : 已启用"
    else
        echo "TG心跳监控   : 未启用"
    fi
    if [ "$SAVED_WARP" = "1" ]; then
        [ -f "$WARP_PROFILE" ] && green "WARP出站     : 已启用" || yellow "WARP出站     : 未就绪"
    else
        echo "WARP出站     : 未启用"
    fi
    echo "---------------------------------------------------------------"
    for name in web bot; do
        pidfile="${BIN_DIR}/${name}.pid"
        if [ -f "$pidfile" ] && kill -0 "$(cat "$pidfile" 2>/dev/null)" >/dev/null 2>&1; then
            green "${name}: 运行中"
        else
            red "${name}: 未运行"
        fi
    done
    if [ -f "${FILE_PATH}/${SAVED_SUB_TOKEN:-$SUB_TOKEN}_feed.php" ]; then
        echo "订阅链接: https://${USERNAME}.${CURRENT_DOMAIN}/${SAVED_SUB_TOKEN:-$SUB_TOKEN}_feed.php"
    fi
    echo "==============================================================="
}

if [ "$ACTION" = "status" ]; then
    do_status
    exit 0
fi

purple "检测到运行平台: serv00/ct8"
case "$ACTION" in
    re) purple "模式: 重新配置" ;;
    update) purple "模式: 强制更新" ;;
esac

TOTAL_STEPS=6
[ "$WARP" = "1" ] && TOTAL_STEPS=$((TOTAL_STEPS + 1))
STEP_NUM=0
step() {
    STEP_NUM=$((STEP_NUM + 1))
    purple "\n[步骤 ${STEP_NUM}/${TOTAL_STEPS}] $1"
}

graceful_kill_pidfile "${BIN_DIR}/web.pid"
graceful_kill_pidfile "${BIN_DIR}/bot.pid"
safe_rm "$WORKDIR" "$FILE_PATH"
mkdir -p "$WORKDIR" "$FILE_PATH" "$BIN_DIR"
chmod 755 "$WORKDIR" "$FILE_PATH" >/dev/null 2>&1

check_port() {
  if { [ "$ACTION" = "re" ] || [ "$ACTION" = "update" ]; } && [ -n "$SAVED_PORT" ]; then
      export PORT="$SAVED_PORT"
      purple "沿用已分配端口: $PORT"
      return
  fi
  clear
  purple "正在检测可用端口..."
  port_list=$(devil port list)
  tcp_ports=$(echo "$port_list" | grep -c "tcp")
  udp_ports=$(echo "$port_list" | grep -c "udp")

  if [[ $tcp_ports -lt 1 ]]; then
      red "没有可用的TCP端口,需要自动调整端口配额"
      if [[ $udp_ports -ge 3 ]]; then
          if [ "$ALLOW_PORT_ADJUST" != "1" ]; then
              red "请加上环境变量 ALLOW_PORT_ADJUST=1 重新运行"
              exit 1
          fi
          udp_port_to_delete=$(echo "$port_list" | awk '/udp/ {print $1}' | head -n 1)
          yellow "5秒后将删除UDP端口: $udp_port_to_delete"
          sleep 5
          devil port del udp $udp_port_to_delete
          green "已删除udp端口: $udp_port_to_delete"
      else
          red "UDP端口数不足3个,无法调整"
          exit 1
      fi
      while true; do
          tcp_port=$(shuf -i 10000-65535 -n 1)
          result=$(devil port add tcp $tcp_port 2>&1)
          if [[ $result == *"Ok"* ]]; then
              green "已添加TCP端口: $tcp_port"
              tcp_port1=$tcp_port
              break
          else
              yellow "端口 $tcp_port 不可用,尝试其他端口..."
          fi
      done
      devil binexec on >/dev/null 2>&1
      red "端口已调整! 5秒后将断开当前SSH连接,请重新连接后再次执行"
      sleep 5
      kill -9 $(ps -o ppid= -p $$) >/dev/null 2>&1
  else
      tcp_port1=$(echo "$port_list" | awk '/tcp/ {print $1}' | sed -n '1p')
  fi
  export PORT=$tcp_port1
  purple "vless-argo 使用端口: $PORT"
}
step "检测可用端口"
check_port

detect_argo_mode() {
    if [[ -z $ARGO_AUTH || -z $ARGO_DOMAIN ]]; then
        ARGO_MODE="quick"
    elif [[ $ARGO_AUTH =~ TunnelSecret ]]; then
        ARGO_MODE="tunnelsecret"
    elif [[ $ARGO_AUTH =~ ^[A-Za-z0-9=]{120,250}$ ]]; then
        ARGO_MODE="token"
    else
        red "无法识别 ARGO_AUTH 格式"
        exit 1
    fi
}

argo_configure() {
  detect_argo_mode
  if [ "$ARGO_MODE" = "quick" ]; then
    green "使用临时隧道(quick tunnel)"
    return
  fi

  if [ "$ARGO_MODE" = "tunnelsecret" ]; then
    echo $ARGO_AUTH > "${BIN_DIR}/${CRED_FILE}"
    if command -v python3 >/dev/null 2>&1; then
        TUNNEL_ID=$(python3 -c "import json,sys; print(json.load(open('${BIN_DIR}/${CRED_FILE}'))['TunnelID'])" 2>/dev/null)
    fi
    if [ -z "$TUNNEL_ID" ]; then
        TUNNEL_ID=$(sed -n 's/.*"TunnelID"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "${BIN_DIR}/${CRED_FILE}" 2>/dev/null)
    fi
    if [ -z "$TUNNEL_ID" ]; then
        red "无法解析 TunnelID"
        exit 1
    fi
    cat > "${BIN_DIR}/${TUNNEL_CONFIG}" << EOF
tunnel: ${TUNNEL_ID}
credentials-file: ${BIN_DIR}/${CRED_FILE}
protocol: http2
ingress:
  - hostname: $ARGO_DOMAIN
    service: http://localhost:$PORT
    originRequest:
      noTLSVerify: true
  - service: http_status:404
EOF
  else
    cat > "${BIN_DIR}/${TUNNEL_CONFIG}" << EOF
token: ${ARGO_AUTH}
EOF
    yellow "token已写入配置文件,不在命令行暴露"
  fi
}
step "配置 Argo 隧道"
argo_configure

download_binaries() {
  ARCH=$(uname -m)
  cd "$BIN_DIR" || exit 1
  BASE_URL="https://github.com/Joshuagpt/Go_Real/releases/download/v1"
  if [[ "$ARCH" =~ ^(arm|arm64|aarch64)$ ]]; then
      WEB_ASSET="runtime-arm64"; BOT_ASSET="serv-arm64"
  else
      WEB_ASSET="runtime"; BOT_ASSET="serv"
  fi

  if [ -x "${BIN_DIR}/web" ] && [ "$FORCE_REDOWNLOAD" != "1" ]; then
      green "web 已存在,跳过下载"
  else
      purple "正在下载 web(xray)..."
      fetch_with_retry "${BASE_URL}/${WEB_ASSET}" "${BIN_DIR}/web" || exit 1
      chmod +x "${BIN_DIR}/web"
  fi
  if [ -x "${BIN_DIR}/bot" ] && [ "$FORCE_REDOWNLOAD" != "1" ]; then
      green "bot 已存在,跳过下载"
  else
      purple "正在下载 bot(cloudflared)..."
      fetch_with_retry "${BASE_URL}/${BOT_ASSET}" "${BIN_DIR}/bot" || exit 1
      chmod +x "${BIN_DIR}/bot"
  fi
}
step "下载核心程序"
download_binaries

check_warp_supported() {
    [ "$WARP" = "1" ] || return 0
    purple "检测 WARP 兼容性..."
    local test_conf="${BIN_DIR}/.probe.json"
    cat > "$test_conf" <<'EOF'
{
  "outbounds": [{
    "protocol": "wireguard",
    "tag": "warp-probe",
    "settings": {
      "secretKey": "wIol6i8Wl4Wp+i6PXVXwZBoTr6Ez2FZ3+Rjez7cvvV0=",
      "address": ["172.16.0.2/32"],
      "peers": [{"publicKey": "bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo=", "endpoint": "162.159.192.1:2408"}]
    }
  }]
}
EOF
    probe_out=$("${BIN_DIR}/web" run -test -c "$test_conf" 2>&1)
    rm -f "$test_conf"
    if echo "$probe_out" | grep -qiE "unknown (outbound )?protocol|not registered"; then
        red "当前二进制不支持 WARP,已关闭"; export WARP=0; return 1
    fi
    green "WARP 兼容性通过"
}

warp_register() {
    [ "$WARP" = "1" ] || return 0
    if [ -f "$WARP_PROFILE" ]; then
        purple "复用 WARP 凭据: ${WARP_PROFILE}"
        return 0
    fi
    purple "注册 WARP 账号..."
    if ! command -v openssl >/dev/null 2>&1; then
        red "未找到 openssl"; export WARP=0; return 1
    fi
    local py_bin=""
    command -v python3 >/dev/null 2>&1 && py_bin="python3"
    if [ -z "$py_bin" ]; then
        (apt-get update -y && apt-get install -y python3) >/dev/null 2>&1 || yum install -y python3 >/dev/null 2>&1
        command -v python3 >/dev/null 2>&1 && py_bin="python3"
    fi
    [ -z "$py_bin" ] && { red "需要 python3"; export WARP=0; return 1; }

    local tmpdir priv_pem priv_key_b64 pub_key_b64
    tmpdir=$(mktemp -d)
    priv_pem="${tmpdir}/priv.pem"
    openssl genpkey -algorithm X25519 -out "$priv_pem" >/dev/null 2>&1 || { rm -rf "$tmpdir"; export WARP=0; return 1; }
    priv_key_b64=$(openssl pkey -in "$priv_pem" -outform DER 2>/dev/null | tail -c 32 | base64 | tr -d '\n')
    pub_key_b64=$(openssl pkey -in "$priv_pem" -pubout -outform DER 2>/dev/null | tail -c 32 | base64 | tr -d '\n')
    rm -rf "$tmpdir"
    [ -z "$priv_key_b64" ] && { export WARP=0; return 1; }

    local reg_resp="${BIN_DIR}/.reg.json" tos_ts body
    tos_ts=$(date -u +%Y-%m-%dT%H:%M:%S.000Z)
    body=$(printf '{"key":"%s","tos":"%s","type":"PC","model":"PC","locale":"en_US"}' "$pub_key_b64" "$tos_ts")
    if [ "$HAVE_CURL" = 1 ]; then
        curl -fsSL -X POST "https://api.cloudflareclient.com/v0a2158/reg" -H "Content-Type: application/json" -d "$body" -o "$reg_resp" --connect-timeout 10 --max-time 20
    else
        wget -q -T 20 --post-data="$body" -O "$reg_resp" "https://api.cloudflareclient.com/v0a2158/reg"
    fi
    [ ! -s "$reg_resp" ] && { rm -f "$reg_resp"; export WARP=0; return 1; }

    "$py_bin" - "$reg_resp" "$priv_key_b64" > "${WARP_PROFILE}.tmp" <<'PYEOF'
import json, base64, sys
resp_path, priv_key = sys.argv[1], sys.argv[2]
try:
    d = json.load(open(resp_path))
    cfg = d["config"]
    peer = cfg["peers"][0]
    client_id_b64 = cfg.get("client_id", "")
    pad = client_id_b64 + "=" * (-len(client_id_b64) % 4)
    raw = base64.b64decode(pad) if client_id_b64 else b"\x00\x00\x00"
    reserved = ",".join(str(b) for b in raw[:3])
    v4 = cfg.get("interface", {}).get("addresses", {}).get("v4", "")
    v6 = cfg.get("interface", {}).get("addresses", {}).get("v6", "")
    endpoint = peer.get("endpoint", {}).get("host") or "engage.cloudflareclient.com:2408"
    print("WARP_PRIVATE_KEY=%r" % priv_key)
    print("WARP_ADDRESS_V4=%r" % v4)
    print("WARP_ADDRESS_V6=%r" % v6)
    print("WARP_PEER_PUBLIC_KEY=%r" % peer["public_key"])
    print("WARP_ENDPOINT=%r" % endpoint)
    print("WARP_RESERVED=%r" % reserved)
except Exception as e:
    sys.stderr.write("parse_error: %s\n" % e)
    sys.exit(1)
PYEOF
    rm -f "$reg_resp"
    if [ ! -s "${WARP_PROFILE}.tmp" ]; then
        rm -f "${WARP_PROFILE}.tmp"; export WARP=0; return 1
    fi
    mv "${WARP_PROFILE}.tmp" "$WARP_PROFILE"
    chmod 600 "$WARP_PROFILE"
    green "WARP 注册成功"
}
if [ "$WARP" = "1" ]; then
    step "配置 WARP"
    check_warp_supported
    warp_register
fi

generate_config() {
  local uuid_json
  uuid_json=$(json_escape "$UUID")
  local warp_outbound="" warp_routing=""
  if [ "$WARP" = "1" ] && [ -f "$WARP_PROFILE" ]; then
    if bash -n "$WARP_PROFILE" 2>/dev/null; then
        # shellcheck disable=SC1090
        source "$WARP_PROFILE"
    else
        mv -f "$WARP_PROFILE" "${WARP_PROFILE}.corrupt" 2>/dev/null
    fi
    if [ -n "$WARP_PRIVATE_KEY" ] && [ -n "$WARP_PEER_PUBLIC_KEY" ]; then
        warp_outbound=",
        {
            \"protocol\": \"wireguard\",
            \"tag\": \"warp-out\",
            \"settings\": {
                \"secretKey\": \"${WARP_PRIVATE_KEY}\",
                \"address\": [\"${WARP_ADDRESS_V4:-172.16.0.2/32}\", \"${WARP_ADDRESS_V6:-::/128}\"],
                \"peers\": [{\"publicKey\": \"${WARP_PEER_PUBLIC_KEY}\", \"endpoint\": \"${WARP_ENDPOINT:-engage.cloudflareclient.com:2408}\"}],
                \"reserved\": [${WARP_RESERVED:-0,0,0}],
                \"mtu\": 1280
            }
        }"
        warp_routing=", \"routing\": { \"rules\": [ { \"type\": \"field\", \"outboundTag\": \"warp-out\", \"network\": \"tcp,udp\" } ] }"
    fi
  fi
  cat > "${BIN_DIR}/${CONFIG_FILE}" << EOF
{
    "log": { "access": "/dev/null", "error": "/dev/null", "loglevel": "none" },
    "inbounds": [{
        "tag": "vless-ws",
        "port": ${PORT},
        "listen": "127.0.0.1",
        "protocol": "vless",
        "settings": { "clients": [ { "id": "${uuid_json}", "level": 0 } ], "decryption": "none" },
        "streamSettings": { "network": "ws", "wsSettings": { "path": "/data-sync?ed=2560" } }
    }],
    "dns": { "servers": [ "https+local://8.8.8.8/dns-query" ] },
    "outbounds": [ { "protocol": "freedom", "tag": "direct" }, { "protocol": "blackhole", "tag": "blocked" }${warp_outbound} ]${warp_routing}
}
EOF
}
step "生成节点配置"
generate_config

start_services() {
  cd "$BIN_DIR" || exit 1

  # 启动 xray，最多尝试两次
  local web_ok=0
  for attempt in 1 2; do
    nohup ./web -c "${CONFIG_FILE}" >/dev/null 2>&1 &
    echo $! > "${BIN_DIR}/web.pid"
    sleep 2
    if [ -f "${BIN_DIR}/web.pid" ] && kill -0 "$(cat "${BIN_DIR}/web.pid")" 2>/dev/null; then
      green "xray(web) 运行中"
      web_ok=1
      break
    else
      red "xray(web) 启动失败 (尝试 ${attempt}/2)"
      [ -f "${BIN_DIR}/web.pid" ] && kill -9 "$(cat "${BIN_DIR}/web.pid")" 2>/dev/null
    fi
  done
  if [ "$web_ok" -eq 0 ]; then
    red "xray(web) 两次启动均失败，请检查 ${BIN_DIR}/${CONFIG_FILE} 配置或端口 ${PORT} 是否被占用"
    exit 1
  fi

  # 启动 cloudflared
  detect_argo_mode
  case "$ARGO_MODE" in
      token)        args="tunnel --edge-ip-version auto --no-autoupdate --protocol http2 --config ${BIN_DIR}/${TUNNEL_CONFIG} run" ;;
      tunnelsecret) args="tunnel --edge-ip-version auto --no-autoupdate --protocol http2 --config ${BIN_DIR}/${TUNNEL_CONFIG} run" ;;
      *)            args="tunnel --edge-ip-version auto --no-autoupdate --protocol http2 --logfile ${WORKDIR}/boot.log --loglevel info --url http://localhost:$PORT" ;;
  esac
  nohup ./bot $args >/dev/null 2>&1 &
  echo $! > "${BIN_DIR}/bot.pid"
  sleep 2
  if [ -f "${BIN_DIR}/bot.pid" ] && kill -0 "$(cat "${BIN_DIR}/bot.pid")" 2>/dev/null; then
      green "cloudflared(bot) 运行中"
  else
      red "cloudflared(bot) 启动失败，但继续执行（隧道可能无法工作）"
      # 不退出，因为 xray 已启动，隧道失败不影响节点本身，但会影响外部访问
  fi
}
step "启动服务"
start_services

get_argodomain() {
  if [[ -n $ARGO_AUTH ]]; then
    echo "$ARGO_DOMAIN"
  else
    local retry=0 max_retries=6 argodomain=""
    while [[ $retry -lt $max_retries ]]; do
        ((retry++))
        argodomain=$(grep -oE 'https://[[:alnum:]+\.-]+\.trycloudflare\.com' "${WORKDIR}/boot.log" 2>/dev/null | sed 's@https://@@')
        [[ -n $argodomain ]] && break
        sleep 1
    done
    echo "$argodomain"
  fi
}

install_homepage() {
    local homepage="${FILE_PATH}/index.html"
    cat > "$homepage" <<'HTMLEOF'
<!DOCTYPE html>
<html lang="en"><head><meta charset="UTF-8"><meta name="viewport" content="width=device-width, initial-scale=1.0"><title>Project Oceanus</title>
<style>:root{--deep-blue:#050b14;--cyan:#64ffda;--text-main:#ccd6f6;--text-muted:#8892b0}body{margin:0;padding:0;background:#050b14;color:#ccd6f6;font-family:sans-serif;display:flex;justify-content:center;align-items:center;min-height:100vh}.container{width:90%;max-width:580px;background:rgba(10,25,47,0.65);backdrop-filter:blur(20px);border:1px solid rgba(100,255,218,0.1);border-radius:16px;padding:45px 40px;text-align:center}h1{color:#e6f1ff}.cyan{color:#64ffda}.footer{margin-top:20px;font-size:0.8rem;color:var(--text-muted)}</style>
</head><body><div class="container"><h1>Project Oceanus</h1><p class="cyan">Global Marine Ecology Initiative</p><p style="color:#8892b0;text-align:justify">Dedicated to deep-sea ecosystem preservation. Acoustic sensor network monitoring water quality, thermal currents, and microplastics.</p><div class="footer">&copy; 2026 Project Oceanus</div></div></body></html>
HTMLEOF
    chmod 644 "$homepage" >/dev/null 2>&1
}

generate_links() {
  argodomain=$(get_argodomain)
  echo -e "\e[1;32mArgoDomain: \e[1;35m${argodomain}\e[0m\n"

  NAME="${USERNAME}"
  LINK="vless://${UUID}@${CFIP}:${CFPORT}?encryption=none&security=tls&sni=${argodomain}&type=ws&host=${argodomain}&path=%2Fdata-sync%3Fed%3D2560#${NAME}"

  devil www add "${USERNAME}.${CURRENT_DOMAIN}" php > /dev/null 2>&1

  LINK_FILE="${WORKDIR}/current_link.txt"
  echo "$LINK" > "$LINK_FILE"
  chmod 600 "$LINK_FILE" >/dev/null 2>&1

  cat > "${FILE_PATH}/${SUB_TOKEN}_feed.php" << 'PHPEOF'
<?php
header('Content-Type: text/plain; charset=utf-8');
$link_file = 'REPLACE_WITH_LINK_FILE';
$fallback_link = 'REPLACE_WITH_LINK';
$link = @file_get_contents($link_file);
$link = ($link !== false) ? trim($link) : '';
if ($link === '') $link = $fallback_link;
$nodes = [ $link ];
echo implode("\n", array_filter($nodes));
?>
PHPEOF

  local php_tmp="${FILE_PATH}/${SUB_TOKEN}_feed.php.tmp.$$"
  sed -e "s|REPLACE_WITH_LINK_FILE|$(sed_repl_escape "$LINK_FILE")|g" \
      -e "s|REPLACE_WITH_LINK|$(sed_repl_escape "$LINK")|g" \
      "${FILE_PATH}/${SUB_TOKEN}_feed.php" > "$php_tmp" && mv "$php_tmp" "${FILE_PATH}/${SUB_TOKEN}_feed.php"
  chmod 644 "${FILE_PATH}/${SUB_TOKEN}_feed.php" >/dev/null 2>&1

  install_homepage
  echo "$LINK"
  green "\n订阅链接: https://${USERNAME}.${CURRENT_DOMAIN}/${SUB_TOKEN}_feed.php"
  : > "${WORKDIR}/boot.log" 2>/dev/null
}

step "生成订阅链接"
generate_links

install_healthcheck() {
    if [ -z "$TG_TOKEN" ] || [ -z "$TG_ID" ]; then
        yellow "未设置 TG_TOKEN / TG_ID,跳过 TG 通知"
    else
        purple "检测到 TG_TOKEN/TG_ID,已启用心跳异常通知"
    fi

    cat > "$HEALTH_SCRIPT" << 'HEALTHEOF'
#!/bin/bash
export LC_ALL=C
STATE_FILE="__STATE_FILE__"
BIN_DIR="__BIN_DIR__"
HEALTH_STATE_FILE="__HEALTH_STATE__"

LOCK_DIR="${BIN_DIR}/.health.lock"
if [ -d "$LOCK_DIR" ]; then
    lock_age=$(( $(date +%s) - $(stat -f %m "$LOCK_DIR" 2>/dev/null || stat -c %Y "$LOCK_DIR" 2>/dev/null || echo 0) ))
    [ "$lock_age" -gt 120 ] && rm -rf "$LOCK_DIR" 2>/dev/null
fi
mkdir "$LOCK_DIR" 2>/dev/null || exit 0
trap 'rmdir "$LOCK_DIR" 2>/dev/null' EXIT

[ -f "$STATE_FILE" ] || exit 0
if ! bash -n "$STATE_FILE" 2>/dev/null; then
    exit 0
fi
source "$STATE_FILE"

# 默认配置文件为 service.json（兼容老版本）
: "${SAVED_CONFIG_FILE:=service.json}"

TG_TOKEN="$SAVED_TG_TOKEN"
TG_ID="$SAVED_TG_ID"

urlencode() {
    local s="$1" out="" c i
    for (( i = 0; i < ${#s}; i++ )); do
        c="${s:i:1}"
        case "$c" in
            [a-zA-Z0-9.~_-]) out+="$c" ;;
            *) printf -v hex '%02X' "'$c"; out+="%${hex}" ;;
        esac
    done
    printf '%s' "$out"
}

tg_send() {
    [ -z "$TG_TOKEN" ] && return 0
    [ -z "$TG_ID" ] && return 0
    local text="$1" attempt=0 ok=1 resp_file
    resp_file="$(mktemp 2>/dev/null || echo "/tmp/.tgresp_$$")"
    while [ $attempt -lt 2 ]; do
        attempt=$((attempt + 1))
        if command -v curl >/dev/null 2>&1; then
            curl -s --max-time 10 "https://api.telegram.org/bot${TG_TOKEN}/sendMessage" --data-urlencode "chat_id=${TG_ID}" --data-urlencode "text=${text}" -o "$resp_file" 2>/dev/null
            grep -q '"ok":true' "$resp_file" 2>/dev/null && ok=0
        elif command -v wget >/dev/null 2>&1; then
            wget -q -T 10 -O "$resp_file" "https://api.telegram.org/bot${TG_TOKEN}/sendMessage?chat_id=$(urlencode "$TG_ID")&text=$(urlencode "$text")" >/dev/null 2>&1
            grep -q '"ok":true' "$resp_file" 2>/dev/null && ok=0
        fi
        [ "$ok" -eq 0 ] && break
        sleep 3
    done
    rm -f "$resp_file"
    return $ok
}

is_port_open() {
    local port="$1"
    [ -z "$port" ] && return 1
    if command -v timeout >/dev/null 2>&1; then
        timeout 3 bash -c "echo >/dev/tcp/127.0.0.1/${port}" >/dev/null 2>&1
    else
        (exec 3<>"/dev/tcp/127.0.0.1/${port}") >/dev/null 2>&1
    fi
}

is_alive_xray() {
    [ -f "${BIN_DIR}/web.pid" ] && kill -0 "$(cat "${BIN_DIR}/web.pid" 2>/dev/null)" >/dev/null 2>&1 || return 1
    is_port_open "$SAVED_PORT"
}

is_alive_cf() {
    [ -f "${BIN_DIR}/bot.pid" ] && kill -0 "$(cat "${BIN_DIR}/bot.pid" 2>/dev/null)" >/dev/null 2>&1
}

restart_xray() {
    [ -f "${BIN_DIR}/web.pid" ] && kill -9 "$(cat "${BIN_DIR}/web.pid" 2>/dev/null)" >/dev/null 2>&1
    ( cd "$BIN_DIR" && nohup ./web -c "${SAVED_CONFIG_FILE}" >/dev/null 2>&1 & echo $! > "${BIN_DIR}/web.pid" )
    sleep 3
    is_alive_xray
}

restart_cf() {
    [ -f "${BIN_DIR}/bot.pid" ] && kill -9 "$(cat "${BIN_DIR}/bot.pid" 2>/dev/null)" >/dev/null 2>&1
    ( cd "$BIN_DIR" && nohup ./bot ${SAVED_BOT_ARGS} >/dev/null 2>&1 & echo $! > "${BIN_DIR}/bot.pid" )
    sleep 3
    is_alive_cf
}

get_current_domain() {
    local wait_retries="${1:-0}" n=0 d=""
    if [ -n "$SAVED_ARGO_AUTH" ]; then
        echo "$SAVED_ARGO_DOMAIN"
        return
    fi
    while :; do
        d=$(grep -oE 'https://[[:alnum:]+.-]+\.trycloudflare\.com' "${SAVED_WORKDIR}/boot.log" 2>/dev/null | tail -n1 | sed 's@https://@@')
        [ -n "$d" ] && break
        n=$((n + 1))
        [ "$n" -gt "$wait_retries" ] && break
        sleep 1
    done
    : > "${SAVED_WORKDIR}/boot.log" 2>/dev/null
    echo "$d"
}

prev_xray="up"; prev_cf="up"; prev_domain=""
[ -f "$HEALTH_STATE_FILE" ] && source "$HEALTH_STATE_FILE"

cur_xray="down"; is_alive_xray && cur_xray="up"
cur_cf="down"; is_alive_cf && cur_cf="up"
cf_restarted=0
msg=""

if [ "$cur_xray" = "down" ] && [ "$prev_xray" != "down" ]; then
    sleep 10
    if is_alive_xray; then
        cur_xray="up"
    else
        if restart_xray; then
            cur_xray="up"
            msg="${msg}⚠️ xray 掉线，等待10秒后仍异常，重启成功 ✅\n"
        else
            msg="${msg}🔴 xray 掉线，重启失败 ❌\n"
        fi
    fi
elif [ "$cur_xray" = "up" ] && [ "$prev_xray" = "down" ]; then
    msg="${msg}✅ xray 已恢复\n"
fi

if [ "$cur_cf" = "down" ] && [ "$prev_cf" != "down" ]; then
    sleep 10
    if is_alive_cf; then
        cur_cf="up"
    else
        if restart_cf; then
            cur_cf="up"
            cf_restarted=1
            msg="${msg}⚠️ cloudflared 掉线，等待10秒后仍异常，重启成功 ✅\n"
        else
            msg="${msg}🔴 cloudflared 掉线，重启失败 ❌\n"
        fi
    fi
elif [ "$cur_cf" = "up" ] && [ "$prev_cf" = "down" ]; then
    msg="${msg}✅ cloudflared 已恢复\n"
fi

if [ "$cf_restarted" = "1" ]; then
    cur_domain="$(get_current_domain 6)"
else
    cur_domain="$(get_current_domain 0)"
fi
[ -z "$cur_domain" ] && cur_domain="$prev_domain"

if [ -n "$prev_domain" ] && [ -n "$cur_domain" ] && [ "$prev_domain" != "$cur_domain" ]; then
    new_link="vless://${SAVED_UUID}@${SAVED_CFIP}:${SAVED_CFPORT}?encryption=none&security=tls&sni=${cur_domain}&type=ws&host=${cur_domain}&path=%2Fdata-sync%3Fed%3D2560#${SAVED_USERNAME:-$(hostname)}"
    msg="${msg}🔄 域名变化: ${prev_domain} → ${cur_domain}\n新链接:\n${new_link}\n"
    [ -n "$SAVED_WORKDIR" ] && echo "$new_link" > "${SAVED_WORKDIR}/current_link.txt" 2>/dev/null
fi

[ -n "$msg" ] && tg_send "$(hostname) vless-argo 状态:\n${msg}"

cat > "$HEALTH_STATE_FILE" <<EOF2
prev_xray=${cur_xray}
prev_cf=${cur_cf}
prev_domain=${cur_domain}
EOF2
HEALTHEOF

    local health_tmp="${HEALTH_SCRIPT}.tmp.$$"
    sed -e "s#__STATE_FILE__#$(sed_repl_escape "$STATE_FILE")#g" \
        -e "s#__BIN_DIR__#$(sed_repl_escape "$BIN_DIR")#g" \
        -e "s#__HEALTH_STATE__#$(sed_repl_escape "$HEALTH_STATE")#g" \
        "$HEALTH_SCRIPT" > "$health_tmp" && mv "$health_tmp" "$HEALTH_SCRIPT"
    chmod +x "$HEALTH_SCRIPT"
    cat > "$HEALTH_STATE" <<EOF
prev_xray=up
prev_cf=up
EOF
    remove_healthcheck_schedule
    if command -v crontab >/dev/null 2>&1; then
        ( crontab -l 2>/dev/null | grep -v "$HEALTH_MARK"; echo "*/5 * * * * ${HEALTH_SCRIPT} >/dev/null 2>&1 # ${HEALTH_MARK}" ) | crontab -
        green "已启用 crontab 内部巡检(每5分钟一次)"
    else
        red "未找到 crontab,请手动配置"
    fi
}

purple "\n[附加] 配置心跳监控"
install_healthcheck

# ---------- 所有步骤成功，最后保存状态 ----------
save_state

case "$ACTION" in
    re) green "\n重新配置完成!\n" ;;
    update) green "\n更新完成!\n" ;;
    *) green "\n安装完成!\n" ;;
esac

green "订阅地址: https://${USERNAME}.${CURRENT_DOMAIN}/${SUB_TOKEN}_feed.php"
green "伪装首页: https://${USERNAME}.${CURRENT_DOMAIN}/"
