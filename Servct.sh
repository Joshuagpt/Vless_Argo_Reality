#!/bin/bash
# ===================================================================
# VLESS+WS+Argo 一键部署脚本 —— serv00/ct8 专版
# 平台: 仅支持 Serv00/CT8 共享主机(devil 管理),不含普通 Linux VPS 相关代码
# 生命周期: install(默认) / re(改参数重装) / update(强制更新二进制并重启) / de(卸载清理) / status(查看状态)
# 保活方案: 内部 cron 每10分钟巡检一次 + 订阅请求(Token.php)触发式唤醒双保险
# ===================================================================

# Alpine/其他环境下若被 sh 调用则自举切换到 bash(serv00 默认自带 bash,这里仅作兜底)
if [ -z "$BASH_VERSION" ]; then
    if command -v bash >/dev/null 2>&1; then
        exec bash "$0" "$@"
    else
        echo "本脚本需要 bash, 请先确认 bash 可用后重试" >&2
        exit 1
    fi
fi

re="\033[0m"
red() { echo -e "\e[1;91m$1\033[0m"; }
green() { echo -e "\e[1;32m$1\033[0m"; }
yellow() { echo -e "\e[1;33m$1\033[0m"; }
purple() { echo -e "\e[1;35m$1\033[0m"; }
export LC_ALL=C

# ---------------------------------------------------------------
# 子命令解析
# 用法示例:
#   bash <(curl -Ls .../Go_Real_Serv00.sh)                                    # 安装
#   VLESS_PORT=... UUID=xxx bash <(curl -Ls .../Go_Real_Serv00.sh) re         # 改参数重装(沿用未指定的旧配置; serv00端口由devil分配,VLESS_PORT无效)
#   WARP=1 bash <(curl -Ls .../Go_Real_Serv00.sh) re                          # 开启WARP出站(账号凭据只注册一次、以后自动复用;开关本身每次都要显式带 WARP=1)
#   bash <(curl -Ls .../Go_Real_Serv00.sh) update                             # 强制重新下载二进制并重启
#   bash <(curl -Ls .../Go_Real_Serv00.sh) status                             # 查看当前配置和运行状态
#   bash <(curl -Ls .../Go_Real_Serv00.sh) de                                 # 卸载并清理
# ---------------------------------------------------------------
ACTION="${1:-install}"
case "$ACTION" in
    install|re|update|de|status) ;;
    *) red "未知参数: ${ACTION} (支持: 留空=安装, re=用新参数重装, update=强制更新二进制, status=查看状态, de=卸载并清理)"; exit 1 ;;
esac

# 下载工具探测: 优先 curl, 没有则用 wget(含 busybox wget, 用短参数保证兼容)
HAVE_CURL=0; command -v curl >/dev/null 2>&1 && HAVE_CURL=1
HAVE_WGET=0; command -v wget >/dev/null 2>&1 && HAVE_WGET=1
if [ "$HAVE_CURL" = 0 ] && [ "$HAVE_WGET" = 0 ]; then
    red "Error: 需要 curl 或 wget, 请先安装其中之一"
    exit 1
fi

# 是否连着交互终端:是的话下载时显示原生进度条(百分比/速度/剩余时间),
# 不是的话(比如日志重定向、CI)保持静默,避免大量 \r 刷新行写进日志文件
IS_TTY=0; [ -t 1 ] && IS_TTY=1

# 统一的下载函数:自带超时 + 重试,避免网络抖动时脚本直接卡死或静默失败
# 用法: fetch_with_retry <URL> <输出路径>
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
    # 白名单本身是拿 BIN_DIR/WORKDIR/FILE_PATH 这几个变量拼出来的,如果其中任何一个
    # 意外变成空值,对应的通配符(比如 "$BIN_DIR/*")会退化成"/*"这种几乎匹配一切路径的
    # 模式,白名单就形同虚设、跟没做限制一样危险。这里先做一次前置检查,只要有一个
    # 关键目录变量是空的,这次调用的所有删除操作整体跳过,不尝试"部分安全"。
    if [ -z "$BIN_DIR" ] || [ -z "$WORKDIR" ] || [ -z "$FILE_PATH" ] || [ -z "$HOME" ]; then
        red "safe_rm: 检测到 BIN_DIR/WORKDIR/FILE_PATH/HOME 中有变量意外为空,为安全起见本次调用已全部跳过,不执行任何删除: $*"
        return 1
    fi
    for target in "$@"; do
        case "$target" in
            "$BIN_DIR"|"$BIN_DIR"/*|"$WORKDIR"|"$WORKDIR"/*|"$FILE_PATH"|"$FILE_PATH"/*)
                rm -rf -- "$target"
                ;;
            *)
                yellow "safe_rm: 拒绝删除不在白名单内的路径 [${target:-<空>}],已跳过(如需清理请手动检查)"
                ;;
        esac
    done
}

# 先礼后兵:普通 kill 给进程一点时间自行退出,超时仍未退出再 -9 强杀
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
# 平台探测: 本脚本是 serv00/ct8 专版,非该平台直接拒绝运行
# ---------------------------------------------------------------
if ! command -v devil >/dev/null 2>&1; then
    red "未检测到 devil 命令,本脚本是 serv00/ct8 专版,无法在当前环境运行"
    exit 1
fi
PLATFORM="serv00"

HOSTNAME=$(hostname)
USERNAME=$(whoami | tr '[:upper:]' '[:lower:]')

# ---------------------------------------------------------------
# 路径规划(纯计算,不做任何创建/删除动作;所有子命令都需要先知道这些路径)
# ---------------------------------------------------------------
if [[ "$HOSTNAME" =~ ct8 ]]; then
    CURRENT_DOMAIN="ct8.pl"
elif [[ "$HOSTNAME" =~ hostuno ]]; then
    CURRENT_DOMAIN="useruno.com"
else
    CURRENT_DOMAIN="serv00.net"
fi
WORKDIR="${HOME}/domains/${USERNAME}.${CURRENT_DOMAIN}/logs"
FILE_PATH="${HOME}/domains/${USERNAME}.${CURRENT_DOMAIN}/public_html"
BIN_DIR="${HOME}/.vless_argo_bin"
STATE_FILE="${BIN_DIR}/.vless_argo.env"

# ---------------------------------------------------------------
# 状态持久化: install 时保存本次生效的关键参数,re/update/status 时读取,
# 用于实现"改参数重装时,没显式指定的项目沿用上次的值"而不是每次都退回硬编码默认值
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
EOF
    # STATE_FILE 里明文保存了 TG_TOKEN 等敏感信息,收紧权限避免同机其他用户读取
    chmod 600 "$STATE_FILE" >/dev/null 2>&1
}
get_xray_version_string() {
    echo "未知(serv00 使用的是第三方重命名二进制,不支持查询版本)"
}

# ---------------------------------------------------------------
# 心跳监控: 公共变量 + 定时任务清理函数
# 提前到这里定义(而不是放在脚本靠后位置),是因为 de 卸载分支会提前 exit,
# 必须保证清理逻辑在那之前就已经可用
# ---------------------------------------------------------------
HEALTH_MARK="px_health"                        # crontab 条目的统一标识,用于精确清理,不影响用户自己的其他定时任务
HEALTH_SCRIPT="${BIN_DIR}/healthcheck.sh"
HEALTH_STATE="${BIN_DIR}/.health_state"

# 清理心跳监控的 crontab 条目。
# 卸载时无条件调用一次,不管本次是否启用了 TG 心跳,避免"以前装过、现在没传 TG_TOKEN"导致的任务残留。
# healthcheck.sh 本体和状态文件在 BIN_DIR 里,会随 BIN_DIR 一起被 safe_rm 删除,这里不用单独处理。
remove_healthcheck_schedule() {
    if command -v crontab >/dev/null 2>&1; then
        ( crontab -l 2>/dev/null | grep -v "$HEALTH_MARK" ) | crontab - 2>/dev/null
    fi
}

# ---------------------------------------------------------------
# 卸载/清理(de 模式专用): 停服务、删配置、删站点,不做任何安装动作
# ---------------------------------------------------------------
do_uninstall() {
    purple "正在卸载 vless-argo 并清理相关文件..."
    remove_healthcheck_schedule
    purple "已清理心跳监控定时任务(如有)"

    graceful_kill_pidfile "${BIN_DIR}/web.pid"
    graceful_kill_pidfile "${BIN_DIR}/bot.pid"
    pkill -f "${BIN_DIR}/web" >/dev/null 2>&1
    pkill -f "${BIN_DIR}/bot" >/dev/null 2>&1

    devil www del "${USERNAME}.${CURRENT_DOMAIN}" >/dev/null 2>&1
    # 兼容清理旧版本(Node.js 保活方案)可能残留的 keep 子域名站点
    devil www del "keep.${USERNAME}.${CURRENT_DOMAIN}" >/dev/null 2>&1

    safe_rm "$WORKDIR" "$FILE_PATH" "$BIN_DIR"

    green "serv00/ct8 上的节点服务、订阅站点及相关文件已清理完毕"
    green "卸载完成"
}

if [ "$ACTION" = "de" ]; then
    do_uninstall
    exit 0
fi

# re/update/status 需要先读取上次保存的配置,作为未显式指定环境变量时的回退值
if [ "$ACTION" = "re" ] || [ "$ACTION" = "update" ] || [ "$ACTION" = "status" ]; then
    load_state
fi
# update = re + 强制重新下载二进制,复用同一套"沿用旧配置"的逻辑
[ "$ACTION" = "update" ] && FORCE_REDOWNLOAD=1

# ---------------------------------------------------------------
# 公共变量 / 环境变量
# 优先级: 本次显式传入的环境变量 > 上次安装保存的值(仅 re/update/status) > 硬编码默认值
# ---------------------------------------------------------------

# 把任意字符串转成能安全嵌进 JSON 字符串值里的形式(反斜杠/双引号/换行/制表符转义)。
# 用途: UUID 这个值最终会被原样拼进 config.json 的字符串字段,一旦用户传入的值恰好带有
# 双引号或反斜杠,会直接破坏 JSON 语法导致 Xray 整个进程起不来。下面的格式校验负责挡掉
# 明显不合法的输入,这个函数负责给"格式校验没覆盖到、但理论上还是可能出现特殊字符"的字段
# 做兜底转义,两者互补。
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
# UUID 格式校验: 只在用户"自己显式传了一个不合规的值"时才会失败(自动生成的分支本身格式一定合法)。
# 之所以在这里就拦截、而不是留到写 config.json 时才发现,是因为 Xray 对 vless client id
# 的格式要求很严格,格式不对轻则该 inbound 拒绝启动,提前用一个清晰的报错拦下来,比让 Xray
# 自己报一个隐晦的启动失败更好排查。
if ! [[ "$UUID" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]; then
    red "UUID 格式不合法(必须是标准 UUID 格式,如 xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx): $UUID"
    exit 1
fi
export ARGO_DOMAIN=${ARGO_DOMAIN:-${SAVED_ARGO_DOMAIN:-''}}
# ARGO_DOMAIN 格式校验(为空表示用 quick tunnel,合法,跳过校验;非空则必须像一个域名)
if [ -n "$ARGO_DOMAIN" ] && ! [[ "$ARGO_DOMAIN" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)+$ ]]; then
    red "ARGO_DOMAIN 格式不合法,不像一个域名: $ARGO_DOMAIN"
    exit 1
fi
export ARGO_AUTH=${ARGO_AUTH:-${SAVED_ARGO_AUTH:-''}}
export CFIP=${CFIP:-${SAVED_CFIP:-'saas.sin.fan'}}
export CFPORT=${CFPORT:-${SAVED_CFPORT:-'443'}}
export SUB_TOKEN=${SUB_TOKEN:-${SAVED_SUB_TOKEN:-${UUID:0:8}}}
# 只要同时设置了这两项,就自动启用 TG 心跳监控,不需要额外开关
export TG_TOKEN=${TG_TOKEN:-${SAVED_TG_TOKEN:-''}}
export TG_ID=${TG_ID:-${SAVED_TG_ID:-''}}

# WARP 出站开关: 每次 install/re/update 都必须显式传 WARP=1 才算开启,
# 不传或传其他任何值(包括之前是开启状态)一律视为本次要关闭。
# 不采用"未传则沿用上次"的粘性逻辑,因为这是一个纯功能开关,误开/误关的代价低,
# 显式声明能避免"忘了传参导致某个开关状态被无声延续"这种更隐蔽的问题。
# 注意: SAVED_WARP 仍然会在 save_state 里写入,只用于 status 命令回显"实际生效的状态"。
if [ "$WARP" = "1" ]; then
    export WARP=1
else
    export WARP=0
fi
WARP_PROFILE="${BIN_DIR}/warp.json"

# ---------------------------------------------------------------
# status 模式: 只读查看,不改动任何东西
# ---------------------------------------------------------------
do_status() {
    echo "===================== vless-argo 状态(serv00/ct8) ====================="
    if [ ! -f "$STATE_FILE" ]; then
        yellow "未找到安装记录(${STATE_FILE} 不存在),下面是本次会用到的默认值,不代表实际已部署的配置"
    fi
    echo "UUID         : ${UUID}"
    echo "端口(PORT)   : ${SAVED_PORT:-<尚未分配>}"
    echo "ARGO_DOMAIN  : ${ARGO_DOMAIN:-<未设置,使用quick tunnel>}"
    echo "ARGO_AUTH    : $([ -n "$ARGO_AUTH" ] && echo '已设置(内容不显示)' || echo '<未设置>')"
    echo "Xray 版本     : $(get_xray_version_string)"
    if [ -n "$TG_TOKEN" ] && [ -n "$TG_ID" ]; then
        if [ -x "$HEALTH_SCRIPT" ]; then
            green "TG心跳监控   : 已启用 (TG_ID=${TG_ID}, 脚本: ${HEALTH_SCRIPT})"
        else
            yellow "TG心跳监控   : 已配置TG_TOKEN/TG_ID,但未找到心跳脚本(可能尚未 install/re 过),请重新执行一次脚本"
        fi
        if command -v crontab >/dev/null 2>&1 && crontab -l 2>/dev/null | grep -q "$HEALTH_MARK"; then
            echo "  定时任务   : crontab 已注册 (每10分钟巡检 + 订阅请求触发式唤醒)"
        else
            yellow "  定时任务   : 未检测到(可能需要重新执行脚本以注册)"
        fi
    else
        echo "TG心跳监控   : 未启用(设置 TG_TOKEN + TG_ID 环境变量后重新执行即可自动开启)"
    fi
    if [ "$SAVED_WARP" = "1" ]; then
        if [ -f "$WARP_PROFILE" ]; then
            green "WARP出站     : 已启用(凭据: ${WARP_PROFILE})"
        else
            yellow "WARP出站     : 已请求启用,但尚未找到凭据文件(可能上次注册失败,重新执行脚本会再次尝试注册)"
        fi
    else
        echo "WARP出站     : 未启用(每次 install/re/update 时加上 WARP=1 环境变量才会开启,不会沿用上次的状态)"
    fi
    echo "---------------------------------------------------------------"
    for name in web bot; do
        pidfile="${BIN_DIR}/${name}.pid"
        if [ -f "$pidfile" ] && kill -0 "$(cat "$pidfile" 2>/dev/null)" >/dev/null 2>&1; then
            green "${name}: 运行中 (PID $(cat "$pidfile"))"
        else
            red "${name}: 未运行"
        fi
    done
    if [ -f "${FILE_PATH}/${SAVED_SUB_TOKEN:-$SUB_TOKEN}_sync.log" ]; then
        echo "订阅链接文件: https://${USERNAME}.${CURRENT_DOMAIN}/${SAVED_SUB_TOKEN:-$SUB_TOKEN}_sync.log"
        echo "订阅触发地址: https://${USERNAME}.${CURRENT_DOMAIN}/${SAVED_SUB_TOKEN:-$SUB_TOKEN}.php  (客户端订阅请填这个地址,自带保活唤醒)"
    fi
    echo "==============================================================="
}

if [ "$ACTION" = "status" ]; then
    do_status
    exit 0
fi

purple "检测到运行平台: serv00/ct8"
case "$ACTION" in
    re) purple "模式: 重新配置(未显式指定的参数沿用上次安装的值,套用新的环境变量并重启服务)" ;;
    update) purple "模式: 强制更新(重新下载 xray/cloudflared 二进制,沿用已保存的配置并重启)" ;;
esac

TOTAL_STEPS=7
[ "$WARP" = "1" ] && TOTAL_STEPS=$((TOTAL_STEPS + 1))
STEP_NUM=0
step() {
    STEP_NUM=$((STEP_NUM + 1))
    purple "\n[步骤 ${STEP_NUM}/${TOTAL_STEPS}] $1"
}

# ---------------------------------------------------------------
# 目录初始化(install/re/update 都要走到这里,de/status 前面已经 exit 了)
# ---------------------------------------------------------------
# 只清理上一次由本脚本启动、且记录在 pid 文件里的进程,不再广撒网 kill 当前用户下所有进程
graceful_kill_pidfile "${BIN_DIR}/web.pid"
graceful_kill_pidfile "${BIN_DIR}/bot.pid"
safe_rm "$WORKDIR" "$FILE_PATH"
mkdir -p "$WORKDIR" "$FILE_PATH" "$BIN_DIR"
# 755 而不是 777: public_html 需要让 devil 起的 web 服务进程能"读"到订阅文件,
# 但不应该允许同机其他用户"写"这个目录(777 会导致任意用户可篡改/植入文件)
chmod 755 "$WORKDIR" "$FILE_PATH" >/dev/null 2>&1

# ---------------------------------------------------------------
# 端口选择(serv00 端口由 devil 分配,一个账号只能有一个可用 TCP 端口)
# ---------------------------------------------------------------
check_port() {
  if { [ "$ACTION" = "re" ] || [ "$ACTION" = "update" ]; } && [ -n "$SAVED_PORT" ]; then
      export PORT="$SAVED_PORT"
      purple "沿用已分配端口: $PORT (serv00 端口由 devil 分配,如需换端口请先 de 卸载再重新 install)"
      return
  fi
  clear
  purple "正在检测可用端口,请稍等..."
  port_list=$(devil port list)
  tcp_ports=$(echo "$port_list" | grep -c "tcp")
  udp_ports=$(echo "$port_list" | grep -c "udp")

  if [[ $tcp_ports -lt 1 ]]; then
      red "没有可用的TCP端口,需要自动调整端口配额(此操作具有破坏性,会删除一个现有UDP端口并断开当前SSH会话)"
      if [[ $udp_ports -ge 3 ]]; then
          if [ "$ALLOW_PORT_ADJUST" != "1" ]; then
              red "即将删除的UDP端口可能正被你其他服务占用,脚本不会未经确认擅自删除。"
              red "如确认可以删除一个现有UDP端口来腾出TCP配额,请加上环境变量 ALLOW_PORT_ADJUST=1 重新运行本脚本。"
              exit 1
          fi
          udp_port_to_delete=$(echo "$port_list" | awk '/udp/ {print $1}' | head -n 1)
          yellow "5秒后将删除UDP端口: $udp_port_to_delete (Ctrl+C 可取消)"
          sleep 5
          devil port del udp $udp_port_to_delete
          green "已删除udp端口: $udp_port_to_delete"
      else
          red "UDP端口数不足3个,无法通过删除UDP端口来腾出TCP配额,请手动在devil面板处理后重试"
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
      # serv00 的已知限制: 新分配的 TCP 端口往往要断开当前 SSH 会话重新连接后才会真正生效,
      # 这里主动杀掉父进程(SSH shell)逼迫断线,不是误操作,是社区里对付这个限制的规避手段;
      # 由于会直接掐断当前会话,提前给出明显倒计时提示,避免用户一头雾水
      red "端口已调整完成! 5秒后将主动断开当前SSH连接以使新端口生效,请重新连接SSH后再次执行本脚本"
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

# ---------------------------------------------------------------
# 统一判断 ARGO_AUTH 属于哪种模式
#   token        : Cloudflare Zero Trust 后台生成的 Tunnel Token(纯 base64 风格长字符串)
#   tunnelsecret : cloudflared tunnel create 生成的 JSON 凭证(含 TunnelSecret 字段)
#   quick        : 未设置 ARGO_AUTH/ARGO_DOMAIN,退回临时隧道
# ---------------------------------------------------------------
# 注意: 故意不用 "echo 结果 + $(...) 命令替换" 的写法——那样 detect_argo_mode
# 会在子 shell 里执行,函数内部的 exit 1 只能杀掉子 shell,报错信息(red 的输出)
# 还会被一起捕获进返回值里,导致外层拿到的 ARGO_MODE 变成一堆颜色转义序列而不是
# 预期的 token/tunnelsecret/quick,并且校验失败时脚本根本不会真正退出。
# 所以这里直接设置全局变量 ARGO_MODE,调用处直接读取该变量,不做命令替换。
detect_argo_mode() {
    if [[ -z $ARGO_AUTH || -z $ARGO_DOMAIN ]]; then
        ARGO_MODE="quick"
    elif [[ $ARGO_AUTH =~ TunnelSecret ]]; then
        ARGO_MODE="tunnelsecret"
    elif [[ $ARGO_AUTH =~ ^[A-Za-z0-9=]{120,250}$ ]]; then
        ARGO_MODE="token"
    else
        # 两种已知格式都不匹配时,不要静默当成 quick tunnel(会导致用户以为自己配置生效了,
        # 实际上却在用临时隧道),明确报错让用户检查 ARGO_AUTH 内容
        red "无法识别 ARGO_AUTH 的格式(既不是 Tunnel Token,也不是包含 TunnelSecret 的 JSON 凭证),请检查该值是否正确"
        exit 1
    fi
}

# ---------------------------------------------------------------
# Argo 隧道配置
# ---------------------------------------------------------------
argo_configure() {
  detect_argo_mode
  if [ "$ARGO_MODE" = "quick" ]; then
    green "ARGO_DOMAIN 或 ARGO_AUTH 为空,使用临时隧道(quick tunnel)"
    return
  fi

  if [ "$ARGO_MODE" = "tunnelsecret" ]; then
    echo $ARGO_AUTH > "${BIN_DIR}/tunnel.json"

    # 提取 TunnelID:优先用 python3 做正规 JSON 解析,不依赖字段固定顺序;
    # 没有 python3 时退化为 sed 基础正则匹配(不依赖 PCRE),
    # 两者都失败才报错退出,避免生成一个 tunnel id 为空的坏配置。
    if command -v python3 >/dev/null 2>&1; then
        TUNNEL_ID=$(python3 -c "import json,sys; print(json.load(open('${BIN_DIR}/tunnel.json'))['TunnelID'])" 2>/dev/null)
    fi
    if [ -z "$TUNNEL_ID" ]; then
        TUNNEL_ID=$(sed -n 's/.*"TunnelID"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "${BIN_DIR}/tunnel.json" 2>/dev/null)
    fi
    if [ -z "$TUNNEL_ID" ]; then
        red "无法从 ARGO_AUTH 中解析出 TunnelID,请检查该 JSON 凭证是否完整(需包含 TunnelID 字段)"
        exit 1
    fi

    cat > "${BIN_DIR}/tunnel.yml" << EOF
tunnel: ${TUNNEL_ID}
credentials-file: ${BIN_DIR}/tunnel.json
protocol: http2

ingress:
  - hostname: $ARGO_DOMAIN
    service: http://localhost:$PORT
    originRequest:
      noTLSVerify: true
  - service: http_status:404
EOF
  else
    yellow "当前使用的是token,请在cloudflare后台设置隧道端口为${purple}${PORT}${re}"
  fi
}
step "配置 Argo 隧道"
argo_configure

# ---------------------------------------------------------------
# 下载核心程序(serv00 FreeBSD 二进制,来源: Joshuagpt/Go_Real release v1)
#   runtime -> 本地保存为 web (xray)
#   serv    -> 本地保存为 bot (cloudflared)
# ---------------------------------------------------------------
download_binaries() {
  ARCH=$(uname -m)
  cd "$BIN_DIR" || exit 1

  BASE_URL="https://github.com/Joshuagpt/Go_Real/releases/download/v1"
  if [[ "$ARCH" =~ ^(arm|arm64|aarch64)$ ]]; then
      WEB_ASSET="runtime-arm64"
      BOT_ASSET="serv-arm64"
  else
      WEB_ASSET="runtime"
      BOT_ASSET="serv"
  fi

  if [ -x "${BIN_DIR}/web" ] && [ "$FORCE_REDOWNLOAD" != "1" ]; then
      green "web 已存在,跳过下载(如需强制重下载,用 update 子命令或设置 FORCE_REDOWNLOAD=1)"
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
  XRAY_BIN="${BIN_DIR}/web"
  CLOUDFLARED_BIN="${BIN_DIR}/bot"
}
step "下载并校验核心程序(网络耗时最长的一步,请耐心等待)"
download_binaries

# ---------------------------------------------------------------
# WARP 出站: 平台能力检测
#   eooce/test 是第三方重命名的 freebsd 二进制(现已换源为 Joshuagpt/Go_Real,
#   但依旧是第三方编译产物,协议支持情况未知),不能假设它和官方行为一致,
#   必须用 -test 校验模式实测一份最小 wireguard 配置。
#   探测本身失败(比如二进制根本不认 -test 这个参数)时,出于稳妥也当作不支持处理,
#   而不是冒险继续——这是可选增强功能,宁可关掉也不要让它拖垮整个安装。
# ---------------------------------------------------------------
check_warp_supported() {
    [ "$WARP" = "1" ] || return 0

    purple "正在检测当前 serv00 二进制是否支持 WARP(wireguard outbound)..."
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
    probe_out=$("${BIN_DIR}/web" run -test -c "$test_conf" 2>&1)
    rm -f "$test_conf"

    if echo "$probe_out" | grep -qiE "unknown (outbound )?protocol|not registered|invalid protocol|unknown config"; then
        red "当前 serv00 平台使用的二进制不支持 WARP(wireguard)出站,已自动关闭 WARP,其余部分正常安装"
        export WARP=0
        return 1
    fi
    if echo "$probe_out" | grep -qiE "flag provided but not defined|unknown (flag|command)|no such (flag|command)"; then
        red "当前 serv00 二进制不支持 -test 配置校验模式,无法安全确认 WARP 是否受支持,出于稳妥考虑已自动关闭 WARP"
        export WARP=0
        return 1
    fi
    green "WARP(wireguard outbound)探测通过"
}

# ---------------------------------------------------------------
# WARP 出站: 自动注册凭据(仅在 WARP=1 且尚未注册过时执行)
#   - 已存在 WARP_PROFILE 时直接复用,绝不重复注册,避免每次 re/update 都换一个新账号
#   - 需要生成 X25519 密钥对: 用 openssl 生成后直接从 DER 编码尾部截取 32 字节原始密钥,
#     不依赖额外的 wg 命令行工具(共享主机上大概率没有)
#   - 注册走的是 Cloudflare WARP 客户端使用的非公开接口,不是正式公开 API,
#     接口细节以后可能变化,因此注册/解析失败时一律优雅降级为关闭 WARP,不阻断其余部分的安装
# ---------------------------------------------------------------
warp_register() {
    [ "$WARP" = "1" ] || return 0

    if [ -f "$WARP_PROFILE" ]; then
        purple "检测到已保存的 WARP 账号凭据,直接复用: ${WARP_PROFILE}(不会重新注册)"
        return 0
    fi

    purple "未找到已保存的 WARP 账号,正在自动注册一个新账号..."

    if ! command -v openssl >/dev/null 2>&1; then
        red "未找到 openssl,无法生成 WARP 所需的密钥对,WARP 出站功能已跳过(其余部分正常安装)"
        export WARP=0; return 1
    fi

    local py_bin=""
    if command -v python3 >/dev/null 2>&1; then
        py_bin="python3"
    fi
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
        red "生成 WireGuard 密钥对失败(openssl 版本可能过旧,不支持 X25519),WARP 出站功能已跳过"
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
        red "WARP 账号注册请求失败(网络问题或接口暂不可达),WARP 出站功能已跳过"
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
        red "解析 WARP 注册返回结果失败(接口返回格式可能已变化),WARP 出站功能已跳过"
        rm -f "${WARP_PROFILE}.tmp"; export WARP=0; return 1
    fi

    mv "${WARP_PROFILE}.tmp" "$WARP_PROFILE"
    chmod 600 "$WARP_PROFILE" >/dev/null 2>&1
    green "WARP 账号注册成功,凭据已保存到 ${WARP_PROFILE}(以后 re/update 会直接复用,不会重新注册)"
}
if [ "$WARP" = "1" ]; then
    step "配置 WARP 出站(平台兼容性检测 + 账号凭据)"
    check_warp_supported
    warp_register
fi

# ---------------------------------------------------------------
# 生成 Xray 配置(协议 vless+ws)
# ---------------------------------------------------------------
generate_config() {
  # UUID 已经在前面做过格式校验,这里再套一层 json_escape 纯粹是双保险,不依赖单一防线
  local uuid_json
  uuid_json=$(json_escape "$UUID")

  # WARP=1 且凭据文件存在有效时,才真正拼接 wireguard 出站;
  # 任何一个条件不满足都安静地退回纯直连(freedom),不生成半残的 WARP 配置
  local warp_outbound="" warp_routing=""
  if [ "$WARP" = "1" ] && [ -f "$WARP_PROFILE" ]; then
    # source 之前先做一次纯语法检查(不会执行文件内容),避免文件损坏/被篡改时
    # source 中途出错导致变量只被部分赋值、还继续带着这个半残状态往下跑。
    # 检查不通过就把这份坏文件隔离改名,下次 warp_register() 会把它当成"没有凭据"
    # 重新走一遍注册流程,相当于自动恢复,不需要用户手动介入。
    if bash -n "$WARP_PROFILE" 2>/dev/null; then
        # shellcheck disable=SC1090
        source "$WARP_PROFILE"
    else
        red "WARP 凭据文件语法异常(可能被篡改或损坏),本次跳过 WARP 出站;已将坏文件隔离,下次 re/update 会自动重新注册"
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
        # 所有非本地流量都走 warp-out;direct 仍保留,供以后需要按域名/IP 分流时使用
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
    "log": {
        "access": "/dev/null",
        "error": "/dev/null",
        "loglevel": "none"
    },
    "inbounds": [
        {
          "tag": "vless-ws",
          "port": ${PORT},
          "listen": "127.0.0.1",
          "protocol": "vless",
          "settings": {
              "clients": [
                  { "id": "${uuid_json}", "level": 0 }
              ],
              "decryption": "none"
          },
          "streamSettings": {
              "network": "ws",
              "wsSettings": {
                  "path": "/data-sync?ed=2560"
              }
          }
        }
    ],
    "dns": {
        "servers": [
            "https+local://8.8.8.8/dns-query"
        ]
    },
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
# 启动服务(serv00 无 systemd 权限,用 nohup 后台进程 + cron 巡检保活)
# ---------------------------------------------------------------
start_services() {
  cd "$BIN_DIR" || exit 1
  nohup ./web -c config.json >/dev/null 2>&1 &
  echo $! > "${BIN_DIR}/web.pid"
  sleep 2
  if pgrep -f "web -c config.json" >/dev/null; then
      green "xray(web) 运行中"
  else
      red "xray(web) 未运行,重试中..."
      [ -f "${BIN_DIR}/web.pid" ] && kill -9 "$(cat "${BIN_DIR}/web.pid")" >/dev/null 2>&1
      nohup ./web -c config.json >/dev/null 2>&1 &
      echo $! > "${BIN_DIR}/web.pid"
      sleep 2
  fi

  detect_argo_mode
  case "$ARGO_MODE" in
      token)        args="tunnel --edge-ip-version auto --no-autoupdate --protocol http2 run --token ${ARGO_AUTH}" ;;
      tunnelsecret) args="tunnel --edge-ip-version auto --config ${BIN_DIR}/tunnel.yml run" ;;
      *)            args="tunnel --edge-ip-version auto --no-autoupdate --protocol http2 --logfile ${WORKDIR}/boot.log --loglevel info --url http://localhost:$PORT" ;;
  esac
  nohup ./bot $args >/dev/null 2>&1 &
  echo $! > "${BIN_DIR}/bot.pid"
  sleep 2
  if pgrep -f "bot" >/dev/null; then
      green "cloudflared(bot) 运行中"
  else
      red "cloudflared(bot) 未运行,重试中..."
      [ -f "${BIN_DIR}/bot.pid" ] && kill -9 "$(cat "${BIN_DIR}/bot.pid")" >/dev/null 2>&1
      nohup ./bot $args >/dev/null 2>&1 &
      echo $! > "${BIN_DIR}/bot.pid"
      sleep 2
  fi
}
step "启动服务"
start_services
save_state

# ---------------------------------------------------------------
# 获取 Argo 域名
# ---------------------------------------------------------------
get_argodomain() {
  if [[ -n $ARGO_AUTH ]]; then
    echo "$ARGO_DOMAIN"
  else
    purple "正在等待 Cloudflare 分配临时隧道域名(最多等待约 6 秒)..." >&2
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

# ---------------------------------------------------------------
# 心跳监控: 只要 TG_TOKEN + TG_ID 同时设置就自动启用,无需额外开关
#   - 生成独立的 healthcheck.sh,探测 xray/cloudflared 是否存活
#   - 只在状态变化时(正常->异常 / 异常->恢复)推送 TG 消息,不会每次检查都刷屏
#   - 检测到异常先自动尝试重启,重启成功/失败的结果一并发送
#   - 调度双保险:
#       1) crontab 每 10 分钟主动巡检一次(兜底,不依赖订阅是否被访问)
#       2) 订阅地址 Token.php 每次被客户端请求时,也会用 nohup 非阻塞方式唤醒同一份
#          healthcheck.sh(见 install_subscription_trigger),两者共用同一个脚本、
#          同一份状态文件,互不冲突,谁先探测到异常谁负责拉起并推送通知
#   - 卸载(de)时由前面定义的 remove_healthcheck_schedule 统一清理,不留定时任务垃圾
# ---------------------------------------------------------------
install_healthcheck() {
    if [ -z "$TG_TOKEN" ] || [ -z "$TG_ID" ]; then
        yellow "未设置 TG_TOKEN / TG_ID,跳过 TG 通知(健康检查脚本仍会安装,供订阅触发式保活使用;如需 TG 通知,带上这两个环境变量重新执行本脚本即可)"
    else
        purple "检测到 TG_TOKEN/TG_ID,已启用心跳异常的 TG 通知"
    fi

    # 用占位符写文件,再用 sed 替换成真实路径,避免直接在 heredoc 里插值时
    # BIN_DIR 等变量万一包含特殊字符导致生成的子脚本语法出错
    cat > "$HEALTH_SCRIPT" << 'HEALTHEOF'
#!/bin/bash
# 由 vless-argo 主脚本自动生成,请勿手动编辑;重新执行主脚本会覆盖,de 卸载时会自动删除
# LC_ALL=C: cron/PHP exec() 启动的是全新环境,不会继承主脚本 export 的 LC_ALL,
# 这里必须显式重设,否则下面 urlencode() 按字节遍历中文/emoji 时会出现编码错误
export LC_ALL=C
STATE_FILE="__STATE_FILE__"
BIN_DIR="__BIN_DIR__"
HEALTH_STATE_FILE="__HEALTH_STATE__"

# 避免 crontab 巡检和 PHP 触发式唤醒同时并发执行造成重复重启/重复通知:
# 用 mkdir 实现一把简单的原子锁(比 flock 更兼容 FreeBSD 共享主机环境,不依赖额外命令),
# 拿不到锁直接退出(不排队等待),因为这本来就是"过一会儿再探测一次"的周期性任务,
# 错过一次没关系,下一次巡检/下一次订阅请求会再探测。锁目录若因异常残留超过2分钟,
# 视为陈旧锁自动清除,避免一次崩溃就永久卡死后续所有探测。
LOCK_DIR="${BIN_DIR}/.health.lock"
if [ -d "$LOCK_DIR" ]; then
    lock_age=$(( $(date +%s) - $(stat -f %m "$LOCK_DIR" 2>/dev/null || stat -c %Y "$LOCK_DIR" 2>/dev/null || echo 0) ))
    [ "$lock_age" -gt 120 ] && rm -rf "$LOCK_DIR" 2>/dev/null
fi
mkdir "$LOCK_DIR" 2>/dev/null || exit 0
trap 'rmdir "$LOCK_DIR" 2>/dev/null' EXIT

[ -f "$STATE_FILE" ] || exit 0
# shellcheck disable=SC1090
source "$STATE_FILE"

TG_TOKEN="$SAVED_TG_TOKEN"
TG_ID="$SAVED_TG_ID"

# 纯 bash 实现的 urlencode,不依赖 python/perl,逐字节处理(兼容 UTF-8 多字节字符,
# 因为未保留字符会被原样透传,只有 ASCII 保留字符才需要转义,多字节 UTF-8 序列本身
# 不含这些保留字符,可以安全地按字节遍历)
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
    [ -z "$TG_TOKEN" ] && return 0
    [ -z "$TG_ID" ] && return 0
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

# 判断本地端口是否真的在监听(/dev/tcp 是 bash 内建能力,不依赖额外装 nc)
is_port_open() {
    local port="$1"
    [ -z "$port" ] && return 1
    if command -v timeout >/dev/null 2>&1; then
        timeout 3 bash -c "echo >/dev/tcp/127.0.0.1/${port}" >/dev/null 2>&1
    else
        (exec 3<>"/dev/tcp/127.0.0.1/${port}") >/dev/null 2>&1
    fi
}

# xray 是否真正可用:进程存活是前提,但存活不代表能用(配置错、内部异常都可能导致端口没起来),
# 所以额外加一层本地端口连通性探测,两者都过才算真的"up"
is_alive_xray() {
    [ -f "${BIN_DIR}/web.pid" ] && kill -0 "$(cat "${BIN_DIR}/web.pid" 2>/dev/null)" >/dev/null 2>&1 || return 1
    is_port_open "$SAVED_PORT"
}

is_alive_cf() {
    [ -f "${BIN_DIR}/bot.pid" ] && kill -0 "$(cat "${BIN_DIR}/bot.pid" 2>/dev/null)" >/dev/null 2>&1
}

restart_xray() {
    [ -f "${BIN_DIR}/web.pid" ] && kill -9 "$(cat "${BIN_DIR}/web.pid" 2>/dev/null)" >/dev/null 2>&1
    ( cd "$BIN_DIR" && nohup ./web -c config.json >/dev/null 2>&1 & echo $! > "${BIN_DIR}/web.pid" )
    sleep 3
    is_alive_xray
}

restart_cf() {
    [ -f "${BIN_DIR}/bot.pid" ] && kill -9 "$(cat "${BIN_DIR}/bot.pid" 2>/dev/null)" >/dev/null 2>&1
    ( cd "$BIN_DIR" && nohup ./bot ${SAVED_BOT_ARGS} >/dev/null 2>&1 & echo $! > "${BIN_DIR}/bot.pid" )
    sleep 3
    is_alive_cf
}

# 取当前生效的 Argo 域名。
# 固定隧道(设置了 ARGO_AUTH,token 或 TunnelSecret 模式)域名是绑定好的,不会变,直接返回。
# quick tunnel(未设置 ARGO_AUTH)模式下,每次 cloudflared 重启域名都会重新随机分配,需要从 boot.log 里解析;
# wait_retries>0 时会重试等待(用于刚重启完、隧道还没建立好的情况),平时每轮只读一次不等待,避免每次巡检都白等几秒。
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
    echo "$d"
}

# 读取上一次记录的状态,文件不存在(首次运行)时视为"up"且域名未知,避免刚装好第一次检测就误报
prev_xray="up"; prev_cf="up"; prev_domain=""
if [ -f "$HEALTH_STATE_FILE" ]; then
    # shellcheck disable=SC1090
    source "$HEALTH_STATE_FILE"
fi

cur_xray="down"; is_alive_xray && cur_xray="up"
cur_cf="down"; is_alive_cf && cur_cf="up"
cf_restarted=0
msg=""

if [ "$cur_xray" = "down" ] && [ "$prev_xray" != "down" ]; then
    if restart_xray; then
        cur_xray="up"
        msg="${msg}⚠️ xray(节点) 掉线,已自动重启成功 ✅"$'\n'
    else
        msg="${msg}🔴 xray(节点) 掉线,自动重启失败,请人工检查 ❌"$'\n'
    fi
elif [ "$cur_xray" = "up" ] && [ "$prev_xray" = "down" ]; then
    msg="${msg}✅ xray(节点) 已恢复正常"$'\n'
fi

if [ "$cur_cf" = "down" ] && [ "$prev_cf" != "down" ]; then
    if restart_cf; then
        cur_cf="up"
        cf_restarted=1
        msg="${msg}⚠️ cloudflared(隧道) 掉线,已自动重启成功 ✅"$'\n'
    else
        msg="${msg}🔴 cloudflared(隧道) 掉线,自动重启失败,请人工检查 ❌"$'\n'
    fi
elif [ "$cur_cf" = "up" ] && [ "$prev_cf" = "down" ]; then
    msg="${msg}✅ cloudflared(隧道) 已恢复正常"$'\n'
fi

# 隧道刚重启完,新域名可能还没写进日志,多等几秒;平时(没重启)只读一次,读不到就沿用旧值,不当成"变化"
if [ "$cf_restarted" -eq 1 ]; then
    cur_domain="$(get_current_domain 6)"
else
    cur_domain="$(get_current_domain 0)"
fi
[ -z "$cur_domain" ] && cur_domain="$prev_domain"

if [ -n "$prev_domain" ] && [ -n "$cur_domain" ] && [ "$prev_domain" != "$cur_domain" ]; then
    # 域名变了,直接拼出新的 vless:// 链接一起推送,不用让用户自己去猜怎么改;
    # 拼接公式必须和主脚本 generate_links() 里的保持完全一致,否则两边生成的链接会不一样
    new_link="vless://${SAVED_UUID}@${SAVED_CFIP}:${SAVED_CFPORT}?encryption=none&security=tls&sni=${cur_domain}&type=ws&host=${cur_domain}&path=%2Fdata-sync%3Fed%3D2560#vless-argo-serv00-$(hostname)"
    msg="${msg}🔄 Argo隧道域名已变化: ${prev_domain} → ${cur_domain}"$'\n'"新节点链接:"$'\n'"${new_link}"$'\n'
    # 同步刷新本地订阅文件内容,避免文件里存的还是老域名的链接(Token.php 每次请求都会实时读取这个文件)
    if [ -n "$SAVED_FILE_PATH" ] && [ -n "$SAVED_SUB_TOKEN" ] && [ -d "$SAVED_FILE_PATH" ]; then
        echo "$new_link" > "${SAVED_FILE_PATH}/${SAVED_SUB_TOKEN}_sync.log" 2>/dev/null
    fi
fi

if [ -n "$msg" ]; then
    tg_send "$(hostname) vless-argo 状态变化:"$'\n'"${msg}"
fi

cat > "$HEALTH_STATE_FILE" <<EOF2
prev_xray=${cur_xray}
prev_cf=${cur_cf}
prev_domain=${cur_domain}
EOF2
HEALTHEOF

    sed -i \
        -e "s#__STATE_FILE__#${STATE_FILE}#g" \
        -e "s#__BIN_DIR__#${BIN_DIR}#g" \
        -e "s#__HEALTH_STATE__#${HEALTH_STATE}#g" \
        "$HEALTH_SCRIPT"
    chmod +x "$HEALTH_SCRIPT"

    # 首次安装/每次重装都重置为"正常",避免用旧状态触发一次多余的通知
    cat > "$HEALTH_STATE" <<EOF
prev_xray=up
prev_cf=up
EOF

    remove_healthcheck_schedule   # 先清一遍旧的,防止 re/update 反复执行时重复叠加

    if command -v crontab >/dev/null 2>&1; then
        ( crontab -l 2>/dev/null | grep -v "$HEALTH_MARK"; echo "*/10 * * * * ${HEALTH_SCRIPT} >/dev/null 2>&1 # ${HEALTH_MARK}" ) | crontab -
        green "已通过 crontab 启用内部巡检保活(每10分钟一次,作为订阅触发式保活的兜底)"
    else
        red "未找到 crontab 命令,心跳脚本已生成但未能自动加入定时任务,请手动配置: */10 * * * * ${HEALTH_SCRIPT}"
    fi
}

# ---------------------------------------------------------------
# 订阅触发式保活(PHP 动态下发方案)
#   逻辑: 客户端通过 https://你的域名/${SUB_TOKEN}.php 发起订阅更新请求
#         -> serv00 的 Web 引擎(PHP)执行该文件
#         -> 第一步用 exec() 以 nohup ... & 的方式非阻塞唤醒 healthcheck.sh 去巡逻,
#            xray/cloudflared 如果掉线会在后台被自动拉起,不阻塞本次请求
#         -> 同时 PHP 继续往下走,把最新的节点订阅内容原样下发给客户端,整个过程无缝衔接
#   前提: 需要该域名已经用 devil www add ... php 挂到 PHP 引擎上(此函数内部会确保)
# ---------------------------------------------------------------
install_subscription_trigger() {
    purple "正在配置订阅触发式保活(PHP)..."
    devil www add "${USERNAME}.${CURRENT_DOMAIN}" php > /dev/null 2>&1

    local php_file="${FILE_PATH}/${SUB_TOKEN}.php"
    cat > "$php_file" << 'PHPEOF'
<?php
// 由 vless-argo 主脚本自动生成,请勿手动编辑;重新执行主脚本会覆盖,de 卸载时会自动删除
// 逻辑: 先非阻塞唤醒健康巡检脚本(掉线自动拉起),再把最新订阅内容原样返回给客户端
$health_script = '__HEALTH_SCRIPT__';
$sub_file = '__SUB_FILE__';

if (function_exists('exec') && is_file($health_script) && is_executable($health_script)) {
    @exec('nohup ' . escapeshellarg($health_script) . ' > /dev/null 2>&1 &');
}

header('Content-Type: text/plain; charset=utf-8');
if (is_file($sub_file)) {
    readfile($sub_file);
} else {
    http_response_code(404);
    echo '';
}
PHPEOF

    sed -i \
        -e "s#__HEALTH_SCRIPT__#${HEALTH_SCRIPT}#g" \
        -e "s#__SUB_FILE__#${FILE_PATH}/${SUB_TOKEN}_sync.log#g" \
        "$php_file"
    chmod 644 "$php_file" >/dev/null 2>&1

    devil www restart "${USERNAME}.${CURRENT_DOMAIN}" > /dev/null 2>&1

    local check_url="http://${USERNAME}.${CURRENT_DOMAIN}/${SUB_TOKEN}.php" check_result
    if [ "$HAVE_CURL" = 1 ]; then
        check_result=$(curl -skL "$check_url")
    else
        check_result=$(wget -qO- "$check_url")
    fi
    if echo "$check_result" | grep -q "vless://"; then
        green "订阅触发式保活配置成功,订阅地址: https://${USERNAME}.${CURRENT_DOMAIN}/${SUB_TOKEN}.php"
    else
        yellow "订阅地址已生成,但首次自检未读到预期内容,请稍后手动访问确认: ${check_url}"
    fi
}

# ---------------------------------------------------------------
# 生成订阅链接(vless://)
# ---------------------------------------------------------------
generate_links() {
  argodomain=$(get_argodomain)
  echo -e "\e[1;32mArgoDomain: \e[1;35m${argodomain}\e[0m\n"

  NAME="vless-argo-serv00-${USERNAME}"
  LINK="vless://${UUID}@${CFIP}:${CFPORT}?encryption=none&security=tls&sni=${argodomain}&type=ws&host=${argodomain}&path=%2Fdata-sync%3Fed%3D2560#${NAME}"

  echo "$LINK" > "${FILE_PATH}/${SUB_TOKEN}_sync.log"
  echo "$LINK"

  green "\n订阅链接(静态文件): https://${USERNAME}.${CURRENT_DOMAIN}/${SUB_TOKEN}_sync.log"
  # 注意: 这里只删 boot.log(避免重启cloudflared后读到旧的隧道域名)。
  # config.json/tunnel.json/tunnel.yml 不能删——心跳监控掉线自动重启时(./web -c config.json / ./bot --config tunnel.yml)还需要用到它们。
  rm -rf "${WORKDIR}/boot.log"
  step "配置订阅触发保活(PHP)"
  install_subscription_trigger
}
step "生成订阅链接"
generate_links

purple "\n[附加] 配置心跳监控(内部巡检 + 订阅触发双保险, TG通知可选)"
install_healthcheck

case "$ACTION" in
    re) green "\n重新配置完成! 已用新参数重启服务 (platform: serv00/ct8)\n" ;;
    update) green "\n更新完成! 已重新下载二进制并重启服务 (platform: serv00/ct8)\n" ;;
    *) green "\nRunning done! (platform: serv00/ct8)\n" ;;
esac

green "订阅地址(推荐,自带保活唤醒): https://${USERNAME}.${CURRENT_DOMAIN}/${SUB_TOKEN}.php"
