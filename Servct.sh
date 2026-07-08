#!/bin/bash
# ===================================================================
# Serv00 / Ct8 / HostUNO 专用部署脚本
# 架构: 原生二进制(nohup 后台进程) + 独立 crontab 巡检,不依赖 Node.js 常驻运行时
# 生命周期: install(默认) / re(改参数重装) / update(强制更新二进制并重启) / de(卸载清理) / status(查看状态)
# ===================================================================

re="\033[0m"
red() { echo -e "\e[1;91m$1\033[0m"; }
green() { echo -e "\e[1;32m$1\033[0m"; }
yellow() { echo -e "\e[1;33m$1\033[0m"; }
purple() { echo -e "\e[1;35m$1\033[0m"; }
export LC_ALL=C
step() { purple "\n[步骤] $1"; }

# ---------------------------------------------------------------
# 子命令解析
# 用法示例:
#   bash <(curl -Ls .../servct_lite.sh)                              # 安装
#   RELAY_PORT=9443 UUID=xxx bash <(curl -Ls .../servct_lite.sh) re   # 改参数重装(沿用未指定的旧配置)
#   WARP=1 bash <(curl -Ls .../servct_lite.sh) re                     # 开启WARP出站(每次都要显式带WARP=1才会保持开启)
#   bash <(curl -Ls .../servct_lite.sh) update                        # 强制重新下载二进制并重启
#   bash <(curl -Ls .../servct_lite.sh) status                        # 查看当前配置和运行状态
#   bash <(curl -Ls .../servct_lite.sh) de                            # 卸载并清理
# ---------------------------------------------------------------
ACTION="${1:-install}"
case "$ACTION" in
    install|re|update|de|status) ;;
    *) red "未知参数: ${ACTION} (支持: 留空=安装, re=用新参数重装, update=强制更新二进制, status=查看状态, de=卸载并清理)"; exit 1 ;;
esac

HAVE_CURL=0; command -v curl >/dev/null 2>&1 && HAVE_CURL=1
HAVE_WGET=0; command -v wget >/dev/null 2>&1 && HAVE_WGET=1
if [ "$HAVE_CURL" = 0 ] && [ "$HAVE_WGET" = 0 ]; then
    red "Error: 需要 curl 或 wget, 请先安装其中之一"
    exit 1
fi

IS_TTY=0; [ -t 1 ] && IS_TTY=1

# 统一的下载函数:自带超时 + 重试
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

# 只删除脚本自己拼出来的固定路径,拒绝空值/根目录/HOME 这种明显危险的目标
safe_rm() {
    local target
    if [ -z "$BIN_DIR" ] || [ -z "$WORKDIR" ] || [ -z "$FILE_PATH" ] || [ -z "$HOME" ]; then
        red "safe_rm: 检测到关键目录变量意外为空,为安全起见本次调用已全部跳过,不执行任何删除: $*"
        return 1
    fi
    for target in "$@"; do
        case "$target" in
            "$BIN_DIR"|"$BIN_DIR"/*|"$WORKDIR"|"$WORKDIR"/*|"$FILE_PATH"|"$FILE_PATH"/*|\
            "${HOME}/domains/hb.${USERNAME}.${CURRENT_DOMAIN}"|"${HOME}/domains/hb.${USERNAME}.${CURRENT_DOMAIN}"/*)
                rm -rf -- "$target"
                ;;
            *)
                yellow "safe_rm: 拒绝删除不在白名单内的路径 [${target:-<空>}],已跳过"
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

# ---------------------------------------------------------------
# 平台探测: 仅支持 serv00/ct8/hostuno(devil 管理的共享主机)
# ---------------------------------------------------------------
command -v devil >/dev/null 2>&1 || { red "未检测到 devil 命令,本脚本仅适用于 Serv00/Ct8/HostUNO"; exit 1; }

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
BIN_DIR="${HOME}/.px_bin"
STATE_FILE="${BIN_DIR}/.px.env"

# ---------------------------------------------------------------
# 状态持久化
# ---------------------------------------------------------------
load_state() {
    [ -f "$STATE_FILE" ] || return 0
    # shellcheck disable=SC1090
    source "$STATE_FILE"
}
save_state() {
    mkdir -p "$BIN_DIR"
    cat > "$STATE_FILE" <<EOF
SAVED_UUID=$(printf '%q' "$UUID")
SAVED_PORT=$(printf '%q' "$PORT")
SAVED_RELAY_DOMAIN=$(printf '%q' "$RELAY_DOMAIN")
SAVED_RELAY_AUTH=$(printf '%q' "$RELAY_AUTH")
SAVED_CFIP=$(printf '%q' "$CFIP")
SAVED_CFPORT=$(printf '%q' "$CFPORT")
SAVED_SUB_TOKEN=$(printf '%q' "$SUB_TOKEN")
SAVED_TG_TOKEN=$(printf '%q' "$TG_TOKEN")
SAVED_TG_ID=$(printf '%q' "$TG_ID")
SAVED_TUN_ARGS=$(printf '%q' "$tun_args")
SAVED_WORKDIR=$(printf '%q' "$WORKDIR")
SAVED_FILE_PATH=$(printf '%q' "$FILE_PATH")
SAVED_WARP=$(printf '%q' "$WARP")
EOF
    chmod 600 "$STATE_FILE" >/dev/null 2>&1
}

# ---------------------------------------------------------------
# 巡检定时任务标识 + 清理(提前定义,de 分支会提前 exit)
# ---------------------------------------------------------------
HEALTH_MARK="px-health"
HEALTH_SCRIPT="${BIN_DIR}/healthcheck.sh"
HEALTH_STATE="${BIN_DIR}/.health_state"

remove_healthcheck_schedule() {
    if command -v crontab >/dev/null 2>&1; then
        ( crontab -l 2>/dev/null | grep -v "$HEALTH_MARK" ) | crontab - 2>/dev/null
    fi
}

# ---------------------------------------------------------------
# 卸载
# ---------------------------------------------------------------
do_uninstall() {
    purple "正在卸载并清理相关文件..."
    remove_healthcheck_schedule
    purple "已清理心跳巡检定时任务(如有)"

    graceful_kill_pidfile "${BIN_DIR}/core.pid"
    graceful_kill_pidfile "${BIN_DIR}/sync.pid"
    pkill -f "${BIN_DIR}/core" >/dev/null 2>&1
    pkill -f "cf_run.py" >/dev/null 2>&1

    devil www del "${USERNAME}.${CURRENT_DOMAIN}" >/dev/null 2>&1
    devil www del "hb.${USERNAME}.${CURRENT_DOMAIN}" >/dev/null 2>&1

    safe_rm "$WORKDIR" "$FILE_PATH" "$BIN_DIR"
    safe_rm "$HOME/domains/hb.${USERNAME}.${CURRENT_DOMAIN}"

    green "服务、配置文件和二进制已清理完毕"
}

if [ "$ACTION" = "de" ]; then
    do_uninstall
    exit 0
fi

if [ "$ACTION" = "re" ] || [ "$ACTION" = "update" ] || [ "$ACTION" = "status" ]; then
    load_state
fi
[ "$ACTION" = "update" ] && FORCE_REDOWNLOAD=1

# ---------------------------------------------------------------
# 公共变量: 本次显式传入 > 上次保存的值(仅re/update/status) > 硬编码默认值
# ---------------------------------------------------------------
json_escape() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\n'/\\n}"
    s="${s//$'\r'/}"
    s="${s//$'\t'/\\t}"
    printf '%s' "$s"
}

export UUID=${UUID:-${SAVED_UUID:-$(cat /proc/sys/kernel/random/uuid 2>/dev/null || echo -n "$USERNAME+$HOSTNAME" | md5sum | head -c 32 | sed -E 's/(.{8})(.{4})(.{4})(.{4})(.{12})/\1-\2-\3-\4-\5/')}}
if ! [[ "$UUID" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]; then
    red "UUID 格式不合法(必须是标准 UUID 格式): $UUID"
    exit 1
fi
export RELAY_DOMAIN=${RELAY_DOMAIN:-${SAVED_RELAY_DOMAIN:-''}}
if [ -n "$RELAY_DOMAIN" ] && ! [[ "$RELAY_DOMAIN" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)+$ ]]; then
    red "RELAY_DOMAIN 格式不合法,不像一个域名: $RELAY_DOMAIN"
    exit 1
fi
export RELAY_AUTH=${RELAY_AUTH:-${SAVED_RELAY_AUTH:-''}}
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
WARP_PROFILE="${BIN_DIR}/warp.json"

# ---------------------------------------------------------------
# status 模式: 只读查看
# ---------------------------------------------------------------
do_status() {
    echo "===================== 节点状态 ====================="
    echo "平台         : serv00/ct8 (${CURRENT_DOMAIN})"
    echo "监听端口     : ${SAVED_PORT:-未安装}"
    echo "UUID         : ${SAVED_UUID:-未安装}"
    echo "订阅Token    : ${SAVED_SUB_TOKEN:-未安装}"
    echo "WARP出站     : $([ "$SAVED_WARP" = "1" ] && echo 开启 || echo 关闭)"
    if [ -f "${BIN_DIR}/core.pid" ] && kill -0 "$(cat "${BIN_DIR}/core.pid" 2>/dev/null)" >/dev/null 2>&1; then
        echo "核心进程     : 运行中 (pid $(cat "${BIN_DIR}/core.pid"))"
    else
        echo "核心进程     : 未运行"
    fi
    if [ -f "${BIN_DIR}/sync.pid" ] && kill -0 "$(cat "${BIN_DIR}/sync.pid" 2>/dev/null)" >/dev/null 2>&1; then
        echo "隧道进程     : 运行中 (pid $(cat "${BIN_DIR}/sync.pid"))"
    else
        echo "隧道进程     : 未运行"
    fi
    if command -v crontab >/dev/null 2>&1 && crontab -l 2>/dev/null | grep -q "$HEALTH_MARK"; then
        echo "心跳巡检     : 已启用(crontab 每2分钟)"
    else
        echo "心跳巡检     : 未启用"
    fi
    echo "订阅链接     : https://${USERNAME}.${CURRENT_DOMAIN}/${SAVED_SUB_TOKEN}_sub.log"
    echo "======================================================"
}
if [ "$ACTION" = "status" ]; then
    do_status
    exit 0
fi

# ---------------------------------------------------------------
# 端口检测(devil 共享主机限制: 一般只有1个可用TCP端口)
# ---------------------------------------------------------------
check_port() {
  port_list=$(devil port list)
  tcp_ports=$(echo "$port_list" | grep -c "tcp")
  if [[ $tcp_ports -ne 1 ]]; then
      red "端口规则不符合要求,正在调整..."
      if [[ $tcp_ports -gt 1 ]]; then
          tcp_to_delete=$((tcp_ports - 1))
          echo "$port_list" | awk '/tcp/ {print $1, $2}' | head -n $tcp_to_delete | while read port type; do
              devil port del $type $port >/dev/null 2>&1
          done
      fi
      if [[ $tcp_ports -lt 1 ]]; then
          while true; do
              tcp_port=$(shuf -i 10000-65535 -n 1)
              result=$(devil port add tcp $tcp_port 2>&1)
              if [[ $result == *"Ok"* ]]; then
                  green "已添加TCP端口: $tcp_port"
                  break
              else
                  yellow "端口 $tcp_port 不可用,尝试其他端口..."
              fi
          done
      fi
      devil binexec on >/dev/null 2>&1
      red "端口已调整完成! 5秒后将主动断开当前SSH连接以使新端口生效,请重新连接SSH后再次执行本脚本"
      sleep 5
      kill -9 $(ps -o ppid= -p $$) >/dev/null 2>&1
  else
      tcp_port=$(echo "$port_list" | awk '/tcp/ {print $1}' | sed -n '1p')
  fi
  export PORT=$tcp_port
  purple "本机监听使用的tcp端口为: $PORT"
}
step "检测可用端口"
check_port

# ---------------------------------------------------------------
# 判断 RELAY_AUTH 属于哪种模式
#   token        : Cloudflare Zero Trust 后台生成的 Tunnel Token
#   tunnelsecret : cloudflared tunnel create 生成的 JSON 凭证(含 TunnelSecret 字段)
#   quick        : 未设置,退回临时隧道
# ---------------------------------------------------------------
detect_relay_mode() {
    if [[ -z $RELAY_AUTH || -z $RELAY_DOMAIN ]]; then
        RELAY_MODE="quick"
    elif [[ $RELAY_AUTH =~ TunnelSecret ]]; then
        RELAY_MODE="tunnelsecret"
    elif [[ $RELAY_AUTH =~ ^[A-Za-z0-9=]{120,250}$ ]]; then
        RELAY_MODE="token"
    else
        red "无法识别 RELAY_AUTH 的格式,请检查该值是否正确"
        exit 1
    fi
}

relay_configure() {
  detect_relay_mode
  if [ "$RELAY_MODE" = "quick" ]; then
    green "RELAY_DOMAIN 或 RELAY_AUTH 为空,使用临时隧道(quick tunnel)"
    return
  fi
  if [ "$RELAY_MODE" = "tunnelsecret" ]; then
    echo $RELAY_AUTH > "${BIN_DIR}/cred.json"
    if command -v python3 >/dev/null 2>&1; then
        TUNNEL_ID=$(python3 -c "import json,sys; print(json.load(open('${BIN_DIR}/cred.json'))['TunnelID'])" 2>/dev/null)
    fi
    if [ -z "$TUNNEL_ID" ]; then
        TUNNEL_ID=$(sed -n 's/.*"TunnelID"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "${BIN_DIR}/cred.json" 2>/dev/null)
    fi
    if [ -z "$TUNNEL_ID" ]; then
        red "无法从 RELAY_AUTH 中解析出 TunnelID,请检查该 JSON 凭证是否完整"
        exit 1
    fi
    cat > "${BIN_DIR}/cred.yml" << EOF
tunnel: ${TUNNEL_ID}
credentials-file: ${BIN_DIR}/cred.json
protocol: http2

ingress:
  - hostname: $RELAY_DOMAIN
    service: http://localhost:$PORT
    originRequest:
      noTLSVerify: true
  - service: http_status:404
EOF
  else
    yellow "当前使用的是token,请在cloudflare后台设置隧道端口为${purple}${PORT}${re}"
  fi
}
step "配置隧道"
relay_configure

# ---------------------------------------------------------------
# 提前创建站点目录: devil www add 才是真正建出 public_html 目录的动作,
# 必须放在所有会往 $FILE_PATH 里写文件的步骤(主页占位/订阅文件)之前,
# 否则会出现 "No such file or directory"(参考 Servctx.sh 里 install_service
# 一开始就 devil www add + mkdir -p 的顺序)
# ---------------------------------------------------------------
step "创建站点目录"
devil www add "${USERNAME}.${CURRENT_DOMAIN}" php >/dev/null 2>&1
mkdir -p "$FILE_PATH" "$WORKDIR"

# ---------------------------------------------------------------
# 下载核心程序(freebsd 原生二进制,serv00/ct8 内核是 FreeBSD)
# !!! 请把下面两个 URL 换成你自己仓库/主机上的二进制下载地址 !!!
# ---------------------------------------------------------------
CORE_BASE_URL="https://github.com/Joshuagpt/Go_Real/releases/download/v1"

CORE_FILE_AMD64="runtime"
CORE_FILE_ARM64="runtime-arm64"

SYNC_FILE_AMD64="helper.so"
SYNC_FILE_ARM64="helper.so"

download_binaries() {
  ARCH=$(uname -m)
  cd "$BIN_DIR" || exit 1
  if [[ "$ARCH" =~ ^(arm|arm64|aarch64)$ ]]; then
      CORE_FILE="$CORE_FILE_ARM64"; SYNC_FILE="$SYNC_FILE_ARM64"
  else
      CORE_FILE="$CORE_FILE_AMD64"; SYNC_FILE="$SYNC_FILE_AMD64"
  fi

  if [ -x "${BIN_DIR}/core" ] && [ "$FORCE_REDOWNLOAD" != "1" ]; then
      green "core 已存在,跳过下载(如需强制重下载,用 update 子命令)"
  else
      purple "正在下载 core..."
      fetch_with_retry "${CORE_BASE_URL}/${CORE_FILE}" "${BIN_DIR}/core" || exit 1
      chmod +x "${BIN_DIR}/core"
  fi
  if [ -x "${BIN_DIR}/sync" ] && [ "$FORCE_REDOWNLOAD" != "1" ]; then
      green "sync 已存在,跳过下载"
  else
      purple "正在下载 sync..."
      fetch_with_retry "${CORE_BASE_URL}/${SYNC_FILE}" "${BIN_DIR}/sync" || exit 1
      chmod +x "${BIN_DIR}/sync"
  fi
  CORE_BIN="${BIN_DIR}/core"
  SYNC_BIN="${BIN_DIR}/sync"
}
step "下载核心程序"
download_binaries

# ---------------------------------------------------------------
# sync(即 helper.so)是共享库(.so),要通过 dlopen + 导出符号
# StartCloudflared(json_args)/StopCloudflared() 调用,不能像普通可执行文件
# 一样直接 nohup 执行(直接执行会 SIGSEGV,因为它没有兼容的入口点解析 argv)。
# 用 python3 ctypes 做一层极薄的 FFI 包装,不引入 Node.js/npm 依赖。
# ---------------------------------------------------------------
command -v python3 >/dev/null 2>&1 || { red "未找到 python3,sync(cloudflared)组件需要 python3 才能正常调用,请先安装"; exit 1; }

CF_RUNNER="${BIN_DIR}/cf_run.py"
cat > "$CF_RUNNER" <<'PYEOF'
#!/usr/bin/env python3
# 由主脚本自动生成,请勿手动编辑。
# 用法: cf_run.py <helper.so路径> <tunnel参数...>
# helper.so 是共享库,导出 StartCloudflared(json_str)/StopCloudflared(),
# 这里原样转发命令行参数为 {"args": [...]} 传给它,行为对齐 Servctx.sh 里
# koffi.load(...).func("int StartCloudflared(str)") 的调用方式。
import ctypes, json, sys, signal, os

if len(sys.argv) < 2:
    sys.exit("usage: cf_run.py <so_path> [tunnel args...]")

so_path = sys.argv[1]
tunnel_args = sys.argv[2:]

lib = ctypes.CDLL(so_path)
lib.StartCloudflared.argtypes = [ctypes.c_char_p]
lib.StartCloudflared.restype = ctypes.c_int
lib.StopCloudflared.argtypes = []
lib.StopCloudflared.restype = ctypes.c_int

def _graceful_stop(signum, frame):
    try:
        lib.StopCloudflared()
    finally:
        os._exit(0)

signal.signal(signal.SIGTERM, _graceful_stop)
signal.signal(signal.SIGINT, _graceful_stop)

payload = json.dumps({"args": tunnel_args}).encode("utf-8")
rc = lib.StartCloudflared(payload)
if rc != 0:
    # StartCloudflared 参数校验失败/致命错误时会同步返回非0,这种情况不需要保活,直接退出让上层重试逻辑接管
    sys.exit(rc)

# StartCloudflared 是"发射后不管"型调用: 它只是把隧道连接相关的 goroutine
# 启动起来就立刻返回 rc=0,真正的连接建立/保活/重连全部在后台 goroutine 里跑。
# 这些 goroutine 和本进程共享同一个地址空间,本进程一退出它们就被一起回收,
# 所以必须让本进程一直存活,不能在拿到 rc 之后就直接结束。
try:
    while True:
        signal.pause()
except AttributeError:
    # 部分平台没有 signal.pause,退化成轮询睡眠
    import time
    while True:
        time.sleep(3600)
PYEOF
chmod +x "$CF_RUNNER"

# ---------------------------------------------------------------
# WARP 出站(可选): 用 -test 校验模式实测二进制是否认识 wireguard 出站
# ---------------------------------------------------------------
check_warp_supported() {
    [ "$WARP" = "1" ] || return 0
    purple "正在检测当前二进制是否支持 WARP(wireguard outbound)..."
    local test_conf="${BIN_DIR}/.warp_probe.json" probe_out
    cat > "$test_conf" <<'EOF'
{
  "outbounds": [
    {
      "protocol": "wireguard",
      "tag": "warp-probe",
      "settings": {
        "secretKey": "wIol6i8Wl4Wp+i6PXVXwZBoTr6Ez2FZ3+Rjez7cvvV0=",
        "address": ["172.16.0.2/32"],
        "peers": [
          { "publicKey": "bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo=", "endpoint": "162.159.192.1:2408" }
        ]
      }
    }
  ]
}
EOF
    probe_out=$("${BIN_DIR}/core" run -test -c "$test_conf" 2>&1)
    rm -f "$test_conf"
    if echo "$probe_out" | grep -qiE "unknown (outbound )?protocol|not registered|invalid protocol|unknown config"; then
        red "当前二进制不支持 WARP(wireguard)出站,已自动关闭 WARP"
        export WARP=0; return 1
    fi
    if echo "$probe_out" | grep -qiE "flag provided but not defined|unknown (flag|command)|no such (flag|command)"; then
        red "当前二进制不支持 -test 配置校验模式,无法安全确认WARP是否受支持,出于稳妥已自动关闭 WARP"
        export WARP=0; return 1
    fi
    green "WARP(wireguard outbound)探测通过"
}

warp_register() {
    [ "$WARP" = "1" ] || return 0
    if [ -f "$WARP_PROFILE" ]; then
        purple "检测到已保存的 WARP 账号凭据,直接复用: ${WARP_PROFILE}"
        return 0
    fi
    purple "未找到已保存的 WARP 账号,正在自动注册一个新账号..."
    if ! command -v openssl >/dev/null 2>&1; then
        red "未找到 openssl,WARP 出站功能已跳过"
        export WARP=0; return 1
    fi
    local py_bin=""
    command -v python3 >/dev/null 2>&1 && py_bin="python3"
    if [ -z "$py_bin" ]; then
        red "未找到 python3(解析注册结果需要用到),WARP 出站功能已跳过"
        export WARP=0; return 1
    fi
    local tmpdir priv_pem priv_key_b64 pub_key_b64
    tmpdir=$(mktemp -d 2>/dev/null || echo "${BIN_DIR}/.warp_tmp")
    mkdir -p "$tmpdir"
    priv_pem="${tmpdir}/priv.pem"
    openssl genpkey -algorithm X25519 -out "$priv_pem" >/dev/null 2>&1
    if [ ! -s "$priv_pem" ]; then
        red "生成 WireGuard 密钥对失败,WARP 出站功能已跳过"
        rm -rf "$tmpdir"; export WARP=0; return 1
    fi
    priv_key_b64=$(openssl pkey -in "$priv_pem" -outform DER 2>/dev/null | tail -c 32 | base64 | tr -d '\n')
    pub_key_b64=$(openssl pkey -in "$priv_pem" -pubout -outform DER 2>/dev/null | tail -c 32 | base64 | tr -d '\n')
    rm -rf "$tmpdir"
    if [ -z "$priv_key_b64" ] || [ -z "$pub_key_b64" ]; then
        red "提取 WireGuard 密钥失败,WARP 出站功能已跳过"
        export WARP=0; return 1
    fi
    local reg_resp="${BIN_DIR}/.warp_reg_resp.json" tos_ts body
    tos_ts=$(date -u +%Y-%m-%dT%H:%M:%S.000Z 2>/dev/null || echo "2024-01-01T00:00:00.000Z")
    body=$(printf '{"key":"%s","tos":"%s","type":"PC","model":"PC","locale":"en_US"}' "$pub_key_b64" "$tos_ts")
    if [ "$HAVE_CURL" = 1 ]; then
        curl -fsSL -X POST "https://api.cloudflareclient.com/v0a2158/reg" \
            -H "Content-Type: application/json" -H "User-Agent: okhttp/3.12.1" \
            -d "$body" -o "$reg_resp" --connect-timeout 10 --max-time 20
    else
        wget -q -T 20 --header="Content-Type: application/json" --header="User-Agent: okhttp/3.12.1" \
            --post-data="$body" -O "$reg_resp" "https://api.cloudflareclient.com/v0a2158/reg"
    fi
    if [ ! -s "$reg_resp" ]; then
        red "WARP 账号注册请求失败,WARP 出站功能已跳过"
        rm -f "$reg_resp"; export WARP=0; return 1
    fi
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
    local parse_rc=$?
    rm -f "$reg_resp"
    if [ "$parse_rc" -ne 0 ] || [ ! -s "${WARP_PROFILE}.tmp" ]; then
        red "解析 WARP 注册返回结果失败,WARP 出站功能已跳过"
        rm -f "${WARP_PROFILE}.tmp"; export WARP=0; return 1
    fi
    mv "${WARP_PROFILE}.tmp" "$WARP_PROFILE"
    chmod 600 "$WARP_PROFILE" >/dev/null 2>&1
    green "WARP 账号注册成功,凭据已保存到 ${WARP_PROFILE}"
}
if [ "$WARP" = "1" ]; then
    step "配置 WARP 出站"
    check_warp_supported
    warp_register
fi

# ---------------------------------------------------------------
# 生成核心配置(协议字段必须原样保留为 vless,否则核心程序无法识别)
# ---------------------------------------------------------------
generate_config() {
  local uuid_json warp_outbound="" warp_routing=""
  uuid_json=$(json_escape "$UUID")

  if [ "$WARP" = "1" ] && [ -f "$WARP_PROFILE" ]; then
    if bash -n "$WARP_PROFILE" 2>/dev/null; then
        # shellcheck disable=SC1090
        source "$WARP_PROFILE"
    else
        red "WARP 凭据文件语法异常,本次跳过 WARP 出站;已隔离,下次 re/update 会自动重新注册"
        mv -f "$WARP_PROFILE" "${WARP_PROFILE}.corrupt.$(date +%s)" 2>/dev/null
    fi
    if [ -n "$WARP_PRIVATE_KEY" ] && [ -n "$WARP_PEER_PUBLIC_KEY" ]; then
        warp_outbound=",
        {
            \"protocol\": \"wireguard\",
            \"tag\": \"warp-out\",
            \"settings\": {
                \"secretKey\": \"${WARP_PRIVATE_KEY}\",
                \"address\": [\"${WARP_ADDRESS_V4:-172.16.0.2/32}\", \"${WARP_ADDRESS_V6:-::/128}\"],
                \"peers\": [
                    { \"publicKey\": \"${WARP_PEER_PUBLIC_KEY}\", \"endpoint\": \"${WARP_ENDPOINT:-engage.cloudflareclient.com:2408}\" }
                ],
                \"reserved\": [${WARP_RESERVED:-0,0,0}],
                \"mtu\": 1280
            }
        }"
        warp_routing=",
    \"routing\": {
        \"rules\": [
            { \"type\": \"field\", \"outboundTag\": \"warp-out\", \"network\": \"tcp,udp\" }
        ]
    }"
    fi
  fi

  cat > "${BIN_DIR}/config.json" << EOF
{
    "log": { "access": "/dev/null", "error": "/dev/null", "loglevel": "none" },
    "inbounds": [
        {
          "tag": "in-ws",
          "port": ${PORT},
          "listen": "127.0.0.1",
          "protocol": "vless",
          "settings": {
              "clients": [ { "id": "${uuid_json}", "level": 0 } ],
              "decryption": "none"
          },
          "streamSettings": {
              "network": "ws",
              "wsSettings": { "path": "/data-sync?ed=2560" }
          }
        }
    ],
    "dns": { "servers": [ "https+local://8.8.8.8/dns-query" ] },
    "outbounds": [
        { "protocol": "freedom", "tag": "direct" },
        { "protocol": "blackhole", "tag": "blocked" }${warp_outbound}
    ]${warp_routing}
}
EOF
}
step "生成节点配置"
generate_config

# ---------------------------------------------------------------
# 启动服务(nohup 后台进程 + pidfile)
# ---------------------------------------------------------------
start_services() {
  cd "$BIN_DIR" || exit 1
  nohup ./core -c config.json >/dev/null 2>&1 &
  echo $! > "${BIN_DIR}/core.pid"
  sleep 2
  if pgrep -f "core -c config.json" >/dev/null; then
      green "核心进程运行中"
  else
      red "核心进程未运行,重试中..."
      [ -f "${BIN_DIR}/core.pid" ] && kill -9 "$(cat "${BIN_DIR}/core.pid")" >/dev/null 2>&1
      nohup ./core -c config.json >/dev/null 2>&1 &
      echo $! > "${BIN_DIR}/core.pid"
      sleep 2
  fi

  detect_relay_mode
  case "$RELAY_MODE" in
      token)        tun_args="tunnel --edge-ip-version auto --no-autoupdate --protocol http2 run --token ${RELAY_AUTH}" ;;
      tunnelsecret) tun_args="tunnel --edge-ip-version auto --config ${BIN_DIR}/cred.yml run" ;;
      *)            tun_args="tunnel --edge-ip-version auto --no-autoupdate --protocol http2 --logfile ${WORKDIR}/boot.log --loglevel info --url http://localhost:$PORT" ;;
  esac
  nohup python3 "${BIN_DIR}/cf_run.py" "${BIN_DIR}/sync" $tun_args >/dev/null 2>&1 &
  echo $! > "${BIN_DIR}/sync.pid"
  sleep 2
  if pgrep -f "cf_run.py" >/dev/null; then
      green "隧道进程运行中"
  else
      red "隧道进程未运行,重试中..."
      [ -f "${BIN_DIR}/sync.pid" ] && kill -9 "$(cat "${BIN_DIR}/sync.pid")" >/dev/null 2>&1
      nohup python3 "${BIN_DIR}/cf_run.py" "${BIN_DIR}/sync" $tun_args >/dev/null 2>&1 &
      echo $! > "${BIN_DIR}/sync.pid"
      sleep 2
  fi
  save_state
}
step "启动服务"
start_services

# 取当前生效的隧道域名
get_current_domain() {
  if [ -n "$RELAY_AUTH" ]; then
    echo "$RELAY_DOMAIN"
  else
    local domain n=0
    for ((n=0; n<15; n++)); do
        domain=$(grep -oE 'https://[[:alnum:]+\.-]+\.trycloudflare\.com' "${WORKDIR}/boot.log" 2>/dev/null | sed 's@https://@@')
        [[ -n $domain ]] && break
        sleep 1
    done
    echo "$domain"
  fi
}

# ---------------------------------------------------------------
# 心跳巡检(TG_TOKEN + TG_ID 同时设置才启用): 独立脚本 + crontab,和被监控进程完全解耦
# ---------------------------------------------------------------
install_healthcheck() {
    if [ -z "$TG_TOKEN" ] || [ -z "$TG_ID" ]; then
        yellow "未设置 TG_TOKEN / TG_ID,跳过心跳巡检"
        remove_healthcheck_schedule
        safe_rm "$HEALTH_SCRIPT" "$HEALTH_STATE"
        return
    fi
    purple "检测到 TG_TOKEN/TG_ID,正在配置心跳巡检..."
    cat > "$HEALTH_SCRIPT" << 'HEALTHEOF'
#!/bin/bash
# 由主脚本自动生成,请勿手动编辑;重新执行主脚本会覆盖,de 卸载时会自动删除
export LC_ALL=C
STATE_FILE="__STATE_FILE__"
BIN_DIR="__BIN_DIR__"
HEALTH_STATE_FILE="__HEALTH_STATE__"

[ -f "$STATE_FILE" ] || exit 0
# shellcheck disable=SC1090
source "$STATE_FILE"

TG_TOKEN="$SAVED_TG_TOKEN"
TG_ID="$SAVED_TG_ID"
[ -z "$TG_TOKEN" ] || [ -z "$TG_ID" ] && [ -z "$TG_TOKEN$TG_ID" ] && exit 0
if [ -z "$TG_TOKEN" ] || [ -z "$TG_ID" ]; then
    exit 0
fi

urlencode() {
    local s="$1" out="" c i
    for (( i = 0; i < ${#s}; i++ )); do
        c="${s:i:1}"
        case "$c" in
            [a-zA-Z0-9.~_-]) out+="$c" ;;
            *) printf -v hex '%02X' "'$c"
               out+="%${hex}" ;;
        esac
    done
    printf '%s' "$out"
}

tg_send() {
    local text="$1" attempt=0 ok=1 resp_file
    resp_file="$(mktemp 2>/dev/null || echo "/tmp/.tgresp_$$")"
    while [ $attempt -lt 2 ]; do
        attempt=$((attempt + 1))
        if command -v curl >/dev/null 2>&1; then
            curl -s --max-time 10 "https://api.telegram.org/bot${TG_TOKEN}/sendMessage" \
                --data-urlencode "chat_id=${TG_ID}" \
                --data-urlencode "text=${text}" -o "$resp_file" 2>/dev/null
            grep -q '"ok":true' "$resp_file" 2>/dev/null && ok=0
        elif command -v wget >/dev/null 2>&1; then
            wget -q -T 10 -O "$resp_file" \
                "https://api.telegram.org/bot${TG_TOKEN}/sendMessage?chat_id=$(urlencode "$TG_ID")&text=$(urlencode "$text")" \
                >/dev/null 2>&1
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

is_alive_core() {
    [ -f "${BIN_DIR}/core.pid" ] && kill -0 "$(cat "${BIN_DIR}/core.pid" 2>/dev/null)" >/dev/null 2>&1 || return 1
    is_port_open "$SAVED_PORT"
}
is_alive_sync() {
    [ -f "${BIN_DIR}/sync.pid" ] && kill -0 "$(cat "${BIN_DIR}/sync.pid" 2>/dev/null)" >/dev/null 2>&1
}
restart_core() {
    [ -f "${BIN_DIR}/core.pid" ] && kill -9 "$(cat "${BIN_DIR}/core.pid" 2>/dev/null)" >/dev/null 2>&1
    ( cd "$BIN_DIR" && nohup ./core -c config.json >/dev/null 2>&1 & echo $! > "${BIN_DIR}/core.pid" )
    sleep 3
    is_alive_core
}
restart_sync() {
    [ -f "${BIN_DIR}/sync.pid" ] && kill -9 "$(cat "${BIN_DIR}/sync.pid" 2>/dev/null)" >/dev/null 2>&1
    ( cd "$BIN_DIR" && nohup python3 "${BIN_DIR}/cf_run.py" "${BIN_DIR}/sync" ${SAVED_TUN_ARGS} >/dev/null 2>&1 & echo $! > "${BIN_DIR}/sync.pid" )
    sleep 3
    is_alive_sync
}

get_current_domain() {
    local wait_retries="${1:-0}" n=0 d=""
    if [ -n "$SAVED_RELAY_AUTH" ]; then
        echo "$SAVED_RELAY_DOMAIN"
        return
    fi
    while :; do
        d=$(grep -oE 'https://[[:alnum:]+.-]+\.trycloudflare\.com' "${SAVED_WORKDIR}/boot.log" 2>/dev/null | tail -n1 | sed 's@https://@@')
        [ -n "$d" ] && break
        n=$((n + 1))
        [ "$n" -gt "$wait_retries" ] && break
        sleep 1
    done
    echo "$d"
}

prev_core="up"; prev_sync="up"; prev_domain=""
if [ -f "$HEALTH_STATE_FILE" ]; then
    # shellcheck disable=SC1090
    source "$HEALTH_STATE_FILE"
fi

cur_core="down"; is_alive_core && cur_core="up"
cur_sync="down"; is_alive_sync && cur_sync="up"
sync_restarted=0
msg=""

if [ "$cur_core" = "down" ] && [ "$prev_core" != "down" ]; then
    if restart_core; then
        cur_core="up"
        msg="${msg}⚠️ 核心进程 掉线,已自动重启成功 ✅"$'\n'
    else
        msg="${msg}🔴 核心进程 掉线,自动重启失败,请人工检查 ❌"$'\n'
    fi
elif [ "$cur_core" = "up" ] && [ "$prev_core" = "down" ]; then
    msg="${msg}✅ 核心进程 已恢复正常"$'\n'
fi

if [ "$cur_sync" = "down" ] && [ "$prev_sync" != "down" ]; then
    if restart_sync; then
        cur_sync="up"
        sync_restarted=1
        msg="${msg}⚠️ 隧道进程 掉线,已自动重启成功 ✅"$'\n'
    else
        msg="${msg}🔴 隧道进程 掉线,自动重启失败,请人工检查 ❌"$'\n'
    fi
elif [ "$cur_sync" = "up" ] && [ "$prev_sync" = "down" ]; then
    msg="${msg}✅ 隧道进程 已恢复正常"$'\n'
fi

if [ "$sync_restarted" -eq 1 ]; then
    cur_domain="$(get_current_domain 6)"
else
    cur_domain="$(get_current_domain 0)"
fi
[ -z "$cur_domain" ] && cur_domain="$prev_domain"

if [ -n "$prev_domain" ] && [ -n "$cur_domain" ] && [ "$prev_domain" != "$cur_domain" ]; then
    new_link="vless://${SAVED_UUID}@${SAVED_CFIP}:${SAVED_CFPORT}?encryption=none&security=tls&sni=${cur_domain}&type=ws&host=${cur_domain}&path=%2Fdata-sync%3Fed%3D2560#node-$(hostname)"
    msg="${msg}🔄 隧道域名已变化: ${prev_domain} → ${cur_domain}"$'\n'"新节点链接:"$'\n'"${new_link}"$'\n'
    if [ -n "$SAVED_FILE_PATH" ] && [ -n "$SAVED_SUB_TOKEN" ] && [ -d "$SAVED_FILE_PATH" ]; then
        echo "$new_link" > "${SAVED_FILE_PATH}/${SAVED_SUB_TOKEN}_sub.log" 2>/dev/null
    fi
fi

if [ -n "$msg" ]; then
    tg_send "$(hostname) 状态变化:"$'\n'"${msg}"
fi

cat > "$HEALTH_STATE_FILE" <<EOF2
prev_core=${cur_core}
prev_sync=${cur_sync}
prev_domain=${cur_domain}
EOF2
HEALTHEOF

    sed -i \
        -e "s#__STATE_FILE__#${STATE_FILE}#g" \
        -e "s#__BIN_DIR__#${BIN_DIR}#g" \
        -e "s#__HEALTH_STATE__#${HEALTH_STATE}#g" \
        "$HEALTH_SCRIPT"
    chmod +x "$HEALTH_SCRIPT"

    cat > "$HEALTH_STATE" <<EOF
prev_core=up
prev_sync=up
EOF

    remove_healthcheck_schedule
    if command -v crontab >/dev/null 2>&1; then
        ( crontab -l 2>/dev/null | grep -v "$HEALTH_MARK"; echo "*/2 * * * * ${HEALTH_SCRIPT} >/dev/null 2>&1 # ${HEALTH_MARK}" ) | crontab -
        green "已通过 crontab 启用心跳巡检(每2分钟探测一次)"
    else
        red "未找到 crontab 命令,巡检脚本已生成但未能自动加入定时任务"
    fi
}

# ---------------------------------------------------------------
# 全自动保活服务: 独立小型 Node 应用,唯一作用是让 devil/Passenger
# 认为账号下有存活的应用,不承载任何代理流量
# ---------------------------------------------------------------
install_keepalive() {
    purple "正在安装保活服务中,请稍等......"
    devil www del "hb.${USERNAME}.${CURRENT_DOMAIN}" > /dev/null 2>&1
    devil www add "hb.${USERNAME}.${CURRENT_DOMAIN}" nodejs /usr/local/bin/node18 > /dev/null 2>&1
    keep_path="$HOME/domains/hb.${USERNAME}.${CURRENT_DOMAIN}/public_nodejs"
    [ -d "$keep_path" ] || mkdir -p "$keep_path"

    # 极简保活应用: 只回应 devil 的健康探测,不含任何代理协议逻辑,自己写掉第三方脚本依赖
    cat > "${keep_path}/app.js" <<'HBEOF'
const http = require('http');
const PORT = process.env.PORT || 3000;
http.createServer((req, res) => {
  res.writeHead(200, { 'Content-Type': 'text/plain' });
  res.end('running');
}).listen(PORT, () => console.log('heartbeat app running on ' + PORT));
HBEOF

    devil www add "${USERNAME}.${CURRENT_DOMAIN}" php > /dev/null 2>&1
    ln -fs /usr/local/bin/node18 ~/bin/node > /dev/null 2>&1
    ln -fs /usr/local/bin/npm18 ~/bin/npm > /dev/null 2>&1
    mkdir -p ~/.npm-global
    npm config set prefix '~/.npm-global' 2>/dev/null
    echo 'export PATH=~/.npm-global/bin:~/bin:$PATH' >> "$HOME/.bash_profile" && source "$HOME/.bash_profile"
    rm -f "${keep_path}/public/index.html" > /dev/null 2>&1
    devil www restart "hb.${USERNAME}.${CURRENT_DOMAIN}" > /dev/null 2>&1

    check_url="http://hb.${USERNAME}.${CURRENT_DOMAIN}"
    if [ "$HAVE_CURL" = 1 ]; then
        check_result=$(curl -skL "$check_url")
    else
        check_result=$(wget -qO- "$check_url")
    fi
    if echo "$check_result" | grep -q "running"; then
        green "全自动保活服务安装成功"
    else
        red "保活服务安装可能未成功,请访问 ${check_url} 检查"
    fi
}

# ---------------------------------------------------------------
# 生成订阅链接
# ---------------------------------------------------------------
generate_links() {
  relaydomain=$(get_current_domain)
  echo -e "\e[1;32m隧道域名: \e[1;35m${relaydomain}\e[0m\n"

  NAME="node-${USERNAME}"
  LINK="vless://${UUID}@${CFIP}:${CFPORT}?encryption=none&security=tls&sni=${relaydomain}&type=ws&host=${relaydomain}&path=%2Fdata-sync%3Fed%3D2560#${NAME}"

  echo "$LINK" > "${FILE_PATH}/${SUB_TOKEN}_sub.log"
  echo "$LINK"

  green "\n订阅链接: https://${USERNAME}.${CURRENT_DOMAIN}/${SUB_TOKEN}_sub.log\n"
  rm -rf "${WORKDIR}/boot.log.old" 2>/dev/null

  step "安装保活服务"
  install_keepalive
}

# ---------------------------------------------------------------
# 主页伪装：德语个人博客
# ---------------------------------------------------------------
install_decoy_homepage() {
    [ -f "${FILE_PATH}/index.html" ] && return
    cat > "${FILE_PATH}/index.html" <<'HOMEEOF'
<!DOCTYPE html>
<html lang="de">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>Gedanken & Notizen</title>
<style>
body{
    font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",Arial,sans-serif;
    max-width:760px;
    margin:60px auto;
    padding:0 20px;
    color:#333;
    background:#fafafa;
    line-height:1.8;
}
header{
    border-bottom:1px solid #ddd;
    margin-bottom:30px;
}
h1{
    margin-bottom:8px;
    font-size:2rem;
}
.subtitle{
    color:#777;
    margin-bottom:20px;
}
article{
    margin-bottom:40px;
}
article h2{
    font-size:1.2rem;
    margin-bottom:6px;
}
.date{
    color:#999;
    font-size:.9rem;
    margin-bottom:12px;
}
footer{
    margin-top:50px;
    border-top:1px solid #ddd;
    padding-top:15px;
    color:#888;
    font-size:.9rem;
}
a{
    color:#2d6cdf;
    text-decoration:none;
}
a:hover{
    text-decoration:underline;
}
</style>
</head>
<body>

<header>
<h1>Gedanken & Notizen</h1>
<div class="subtitle">
Ein persönliches Blog über Technik, Programmierung und den digitalen Alltag.
</div>
</header>

<article>
<h2>Willkommen</h2>
<div class="date">8. Juli 2026</div>
<p>
Dieses Blog dient als Sammlung persönlicher Notizen und kleiner technischer
Experimente. Neue Beiträge erscheinen unregelmäßig, sobald interessante Themen
oder Ideen entstehen.
</p>
</article>

<article>
<h2>Aktuelle Projekte</h2>
<div class="date">30. Juni 2026</div>
<p>
Zurzeit beschäftige ich mich hauptsächlich mit Linux, Netzwerktechnik,
Automatisierung sowie einigen kleinen Open-Source-Projekten. Viele Beiträge
entstehen zunächst als persönliche Dokumentation und werden später veröffentlicht.
</p>
</article>

<article>
<h2>Über dieses Blog</h2>
<div class="date">15. Juni 2026</div>
<p>
Der Schwerpunkt liegt auf praktischen Erfahrungen statt langen theoretischen
Erklärungen. Ziel ist es, Lösungen nachvollziehbar zu dokumentieren und
interessante Entdeckungen festzuhalten.
</p>
</article>

<footer>
© <span id="year"></span> Gedanken & Notizen
</footer>

<script>
document.getElementById("year").textContent=new Date().getFullYear();
</script>

</body>
</html>
HOMEEOF
}

step "安装主页占位内容"
install_decoy_homepage

step "生成订阅链接"
generate_links

purple "\n[附加] 配置 TG 心跳巡检(节点/隧道保活状态通知)"
install_healthcheck
save_state

case "$ACTION" in
    re) green "\n重新配置完成! 已用新参数重启服务\n" ;;
    update) green "\n更新完成! 已重新下载二进制并重启服务\n" ;;
    *) green "\n部署完成!\n" ;;
esac
