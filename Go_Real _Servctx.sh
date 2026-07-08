#!/bin/bash
# ===================================================================
# 通用 VLESS+WS+Argo 一键部署脚本
# 兼容: Serv00/CT8 (共享主机, devil管理) 和 普通 Linux VPS (systemd/OpenRC管理)
# 生命周期: install(默认) / re(改参数重装) / update(强制更新二进制并重启) / de(卸载清理) / status(查看状态)
# ===================================================================

# Alpine 默认不装 bash(默认 shell 是 busybox ash), 若被 sh 调用则自举切换到 bash
if [ -z "$BASH_VERSION" ]; then
    if command -v apk >/dev/null 2>&1; then
        apk add --no-cache bash >/dev/null 2>&1
    fi
    if command -v bash >/dev/null 2>&1; then
        exec bash "$0" "$@"
    else
        echo "本脚本需要 bash, 且自动安装失败, 请手动安装 bash 后重试" >&2
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
#   bash <(curl -Ls .../Vless_Argo.sh)                                       # 安装
#   VLESS_PORT=9443 UUID=xxx bash <(curl -Ls .../Vless_Argo.sh) re           # 改参数重装(沿用未指定的旧配置)
#   WARP=1 bash <(curl -Ls .../Vless_Argo.sh) re                             # 开启WARP出站(账号凭据只注册一次、以后自动复用;但"是否启用"这个开关本身不会沿用,每次 re/update 都要带 WARP=1 才会保持开启,不带就会关闭)
#   bash <(curl -Ls .../Vless_Argo.sh) update                                # 强制重新下载二进制并重启
#   bash <(curl -Ls .../Vless_Argo.sh) status                                # 查看当前配置和运行状态
#   bash <(curl -Ls .../Vless_Argo.sh) de                                    # 卸载并清理
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
            "$BIN_DIR"|"$BIN_DIR"/*|"$WORKDIR"|"$WORKDIR"/*|"$FILE_PATH"|"$FILE_PATH"/*|\
            "${HOME}/domains/keep.${USERNAME}.${CURRENT_DOMAIN}"|"${HOME}/domains/keep.${USERNAME}.${CURRENT_DOMAIN}"/*)
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
# 平台探测
# ---------------------------------------------------------------
if command -v devil >/dev/null 2>&1; then
    PLATFORM="serv00"
elif [ -f /etc/os-release ] || [ -f /etc/alpine-release ]; then
    PLATFORM="vps"
else
    PLATFORM="other"
fi

if [ "$PLATFORM" = "other" ]; then
    red "未能识别当前平台(既非 serv00/ct8 也非常见 Linux 发行版),脚本退出"
    exit 1
fi

# VPS 场景下,init 系统不一定是 systemd(如 Alpine 默认用 OpenRC),需要单独探测
INIT_SYSTEM="none"
if [ "$PLATFORM" = "vps" ]; then
    if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
        INIT_SYSTEM="systemd"
    elif command -v rc-service >/dev/null 2>&1 && command -v rc-update >/dev/null 2>&1; then
        INIT_SYSTEM="openrc"
    else
        red "未能识别 init 系统(既非 systemd 也非 OpenRC),脚本退出"
        exit 1
    fi
fi

HOSTNAME=$(hostname)
USERNAME=$(whoami | tr '[:upper:]' '[:lower:]')

# ---------------------------------------------------------------
# 路径规划(纯计算,不做任何创建/删除动作;所有子命令都需要先知道这些路径)
# ---------------------------------------------------------------
if [ "$PLATFORM" = "serv00" ]; then
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
else
    [ "$(id -u)" -ne 0 ] && { red "VPS 模式请使用 root 权限运行本脚本"; exit 1; }
    WORKDIR="/var/log/xray-argo"
    FILE_PATH="/var/www/xray-argo"
    BIN_DIR="/etc/xray-argo"
fi
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
SAVED_REALITY_PORT=$(printf '%q' "$REALITY_PORT")
SAVED_REALITY_DEST=$(printf '%q' "$REALITY_DEST")
SAVED_REALITY_PRIVATE_KEY=$(printf '%q' "$REALITY_PRIVATE_KEY")
SAVED_REALITY_PUBLIC_KEY=$(printf '%q' "$REALITY_PUBLIC_KEY")
SAVED_REALITY_SHORT_ID=$(printf '%q' "$REALITY_SHORT_ID")
EOF
    # STATE_FILE 里明文保存了 TG_TOKEN 等敏感信息,收紧权限避免同机其他用户读取
    chmod 600 "$STATE_FILE" >/dev/null 2>&1
}
get_xray_version_string() {
    if [ "$PLATFORM" = "vps" ] && [ -x "${BIN_DIR}/xray-core/xray" ]; then
        "${BIN_DIR}/xray-core/xray" version 2>/dev/null | head -n1
    else
        echo "未知(serv00 使用的是第三方重命名二进制,不支持查询版本)"
    fi
}

# ---------------------------------------------------------------
# TG 心跳监控: 公共变量 + 定时任务清理函数
# 提前到这里定义(而不是放在脚本靠后位置),是因为 de 卸载分支会提前 exit,
# 必须保证清理逻辑在那之前就已经可用
# ---------------------------------------------------------------
HEALTH_MARK="vless-argo-health"                # crontab/systemd 单元的统一标识,用于精确清理,不影响用户自己的其他定时任务
HEALTH_SCRIPT="${BIN_DIR}/healthcheck.sh"
HEALTH_STATE="${BIN_DIR}/.health_state"

# 清理心跳监控的定时任务(crontab 条目 / systemd timer)。
# 卸载时无条件调用一次,不管本次是否启用了 TG 心跳,避免"以前装过、现在没传 TG_TOKEN"导致的任务残留。
# healthcheck.sh 本体和状态文件在 BIN_DIR 里,会随 BIN_DIR 一起被 safe_rm 删除,这里不用单独处理。
remove_healthcheck_schedule() {
    if command -v crontab >/dev/null 2>&1; then
        ( crontab -l 2>/dev/null | grep -v "$HEALTH_MARK" ) | crontab - 2>/dev/null
    fi
    if [ "$PLATFORM" = "vps" ] && [ "$INIT_SYSTEM" = "systemd" ]; then
        systemctl disable --now vless-argo-health.timer >/dev/null 2>&1
        rm -f /etc/systemd/system/vless-argo-health.service /etc/systemd/system/vless-argo-health.timer
        systemctl daemon-reload >/dev/null 2>&1
    fi
}

# Reality 端口的防火墙撤销,同样提前到这里定义,原因和上面 remove_healthcheck_schedule 一致:
# de 卸载分支会提前 exit,必须保证这个函数在那之前就可用。
# (对应的"放行"函数 reality_firewall_apply 只在安装/re/update 时用到,不受提前 exit 影响,留在后面定义即可)
reality_firewall_revoke() {
    local port="$1"
    [ -z "$port" ] && return 0
    if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -qi "Status: active"; then
        ufw delete allow "${port}/tcp" >/dev/null 2>&1
    fi
    if command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld 2>/dev/null; then
        firewall-cmd --permanent --remove-port="${port}/tcp" >/dev/null 2>&1
        firewall-cmd --reload >/dev/null 2>&1
    fi
}

# ---------------------------------------------------------------
# 卸载/清理(de 模式专用): 停服务、删配置、删站点,不做任何安装动作
# ---------------------------------------------------------------
do_uninstall() {
    purple "正在卸载 vless-argo 并清理相关文件..."
    # 防火墙规则是系统级配置,不在 BIN_DIR 里,后面整体 safe_rm 不会带上它,必须先读出上次保存的
    # REALITY_PORT 单独撤销;load_state 此时还没在别处调用过,这里提前读一次,不影响后续流程
    load_state
    if [ -n "$SAVED_REALITY_PORT" ]; then
        reality_firewall_revoke "$SAVED_REALITY_PORT"
        purple "已撤销 Reality 端口 ${SAVED_REALITY_PORT} 的防火墙放行规则(如有)"
    fi
    remove_healthcheck_schedule
    purple "已清理心跳监控定时任务(如有)"

    if [ "$PLATFORM" = "serv00" ]; then
        graceful_kill_pidfile "${BIN_DIR}/web.pid"
        graceful_kill_pidfile "${BIN_DIR}/bot.pid"
        pkill -f "${BIN_DIR}/web" >/dev/null 2>&1
        pkill -f "${BIN_DIR}/bot" >/dev/null 2>&1

        devil www del "${USERNAME}.${CURRENT_DOMAIN}" >/dev/null 2>&1
        devil www del "keep.${USERNAME}.${CURRENT_DOMAIN}" >/dev/null 2>&1

        safe_rm "$WORKDIR" "$FILE_PATH" "$BIN_DIR"
        safe_rm "$HOME/domains/keep.${USERNAME}.${CURRENT_DOMAIN}"

        green "serv00/ct8 上的节点服务、保活服务及相关文件已清理完毕"
    else
        if [ "$INIT_SYSTEM" = "systemd" ]; then
            systemctl disable --now xray-argo >/dev/null 2>&1
            systemctl disable --now cloudflared-argo >/dev/null 2>&1
            rm -f /etc/systemd/system/xray-argo.service /etc/systemd/system/cloudflared-argo.service
            systemctl daemon-reload >/dev/null 2>&1
        elif [ "$INIT_SYSTEM" = "openrc" ]; then
            rc-service xray-argo stop >/dev/null 2>&1
            rc-service cloudflared-argo stop >/dev/null 2>&1
            rc-update del xray-argo default >/dev/null 2>&1
            rc-update del cloudflared-argo default >/dev/null 2>&1
            rm -f /etc/init.d/xray-argo /etc/init.d/cloudflared-argo
        fi

        safe_rm "$WORKDIR" "$FILE_PATH" "$BIN_DIR"
        green "VPS 上的服务、配置文件和二进制已清理完毕"
    fi

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
# 用途: UUID、REALITY_DEST 这些值最终会被原样拼进 config.json 的字符串字段,
# 一旦用户传入的值恰好带有双引号或反斜杠,会直接破坏 JSON 语法导致 Xray 整个进程起不来
# (不只是相关功能失效,是所有 inbound 一起挂掉)。下面的格式校验负责挡掉明显不合法的输入,
# 这个函数负责给"格式校验没覆盖到、但理论上还是可能出现特殊字符"的字段做兜底转义,两者互补。
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
# 的格式要求很严格,格式不对轻则该 inbound 拒绝启动,重则直接影响到同一个 config.json 里
# 的其他 inbound(Reality),提前用一个清晰的报错拦下来,比让 Xray 自己报一个隐晦的启动失败更好排查。
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
# 仅 VPS 场景使用,serv00 端口由 devil 分配后覆盖
export VLESS_PORT=${VLESS_PORT:-${SAVED_PORT:-'443'}}
# 只要同时设置了这两项,就自动启用 TG 心跳监控,不需要额外开关
export TG_TOKEN=${TG_TOKEN:-${SAVED_TG_TOKEN:-''}}
export TG_ID=${TG_ID:-${SAVED_TG_ID:-''}}

# WARP 出站开关: 每次 install/re/update 都必须显式传 WARP=1 才算开启,
# 不传或传其他任何值(包括之前是开启状态)一律视为本次要关闭。
# 不采用"未传则沿用上次"的粘性逻辑,因为这是一个纯功能开关,误开/误关的代价低,
# 显式声明能避免"忘了传参导致某个开关状态被无声延续"这种更隐蔽的问题。
# 注意: SAVED_WARP 仍然会在 save_state 里写入,但只用于 status 命令回显"实际生效的状态",
# 不参与这里的开关判断,两者用途不同,不要混用。
if [ "$WARP" = "1" ]; then
    export WARP=1
else
    export WARP=0
fi
WARP_PROFILE="${BIN_DIR}/warp.json"

# ---------------------------------------------------------------
# Reality 直连节点开关(仅 VPS 场景可用): 和 WARP 一样采用"每次显式声明才开启"的模式。
#   REALITY_PORT=端口号  本次显式指定 -> 建立/维持这个端口上的 vless+tcp+reality 直连节点
#                        (不走 Argo,不隐藏源站IP,换取更低延迟和免证书维护)
#   不传 REALITY_PORT    -> 关闭(如果之前是开启状态,会连带清理: 撤销防火墙放行、清空已保存的密钥,
#                        下次重新开启会是全新的密钥对,不会复用旧的)
# 这里只做"格式是否合法"的基础校验;和 $PORT 是否冲突、端口是否被占用、密钥生成、
# 防火墙放行这些依赖 check_port()/download_binaries() 先跑完的逻辑,放在 reality_configure() 里,
# 在后面按正确的时序调用。
# ---------------------------------------------------------------
if [ "$PLATFORM" = "serv00" ] && [ -n "$REALITY_PORT" ]; then
    yellow "REALITY_PORT 仅支持 VPS 场景,serv00/ct8 已忽略该参数"
    unset REALITY_PORT
fi
if [ -n "$REALITY_PORT" ]; then
    if ! [[ "$REALITY_PORT" =~ ^[0-9]+$ ]] || [ "$REALITY_PORT" -lt 1 ] || [ "$REALITY_PORT" -gt 65535 ]; then
        red "REALITY_PORT 必须是 1-65535 之间的数字,当前传入的值无效: $REALITY_PORT"
        exit 1
    fi
    export REALITY_PORT
    export REALITY_DEST=${REALITY_DEST:-'www.microsoft.com'}
    if ! [[ "$REALITY_DEST" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)+$ ]]; then
        red "REALITY_DEST 格式不合法,不像一个域名: $REALITY_DEST"
        exit 1
    fi
else
    unset REALITY_PORT
fi

# 获取本机公网IP,Reality节点链接要用IP而不是域名(它不走Argo/CDN,没有域名可用)。
# 多个源轮询,任意一个成功就返回;全部失败返回空字符串,调用方需要自行处理"取不到"的情况。
get_public_ip() {
    local ip=""
    for url in "https://ip.sb" "https://ifconfig.me" "https://api.ipify.org"; do
        ip=$(curl -s --max-time 3 "$url" 2>/dev/null | tr -d '[:space:]')
        [[ "$ip" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] && { echo "$ip"; return 0; }
    done
    return 1
}

# ---------------------------------------------------------------
# status 模式: 只读查看,不改动任何东西
# ---------------------------------------------------------------
do_status() {
    echo "===================== vless-argo 状态 ====================="
    echo "平台         : ${PLATFORM}$( [ "$PLATFORM" = "vps" ] && echo " (init: ${INIT_SYSTEM})" )"
    if [ ! -f "$STATE_FILE" ]; then
        yellow "未找到安装记录(${STATE_FILE} 不存在),下面是本次会用到的默认值,不代表实际已部署的配置"
    fi
    echo "UUID         : ${UUID}"
    echo "端口(PORT)   : ${SAVED_PORT:-${VLESS_PORT}}"
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
            echo "  定时任务   : crontab 已注册 (每2分钟)"
        elif [ "$PLATFORM" = "vps" ] && [ "$INIT_SYSTEM" = "systemd" ] && systemctl is-active --quiet vless-argo-health.timer 2>/dev/null; then
            echo "  定时任务   : systemd timer 已注册 (每2分钟)"
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
    if [ "$PLATFORM" = "vps" ] && [ -n "$SAVED_REALITY_PORT" ]; then
        green "Reality直连  : 已启用(端口: ${SAVED_REALITY_PORT}, 伪装目标: ${SAVED_REALITY_DEST})"
        if [ -n "$SAVED_REALITY_PUBLIC_KEY" ]; then
            local _pub_ip
            _pub_ip=$(get_public_ip)
            if [ -n "$_pub_ip" ]; then
                echo "  节点链接   : vless://${SAVED_UUID}@${_pub_ip}:${SAVED_REALITY_PORT}?encryption=none&security=reality&sni=${SAVED_REALITY_DEST}&fp=chrome&pbk=${SAVED_REALITY_PUBLIC_KEY}&sid=${SAVED_REALITY_SHORT_ID}&type=tcp&flow=xtls-rprx-vision#reality-${HOSTNAME}"
            else
                yellow "  节点链接   : 获取公网IP失败,请手动查看本机IP后自行拼接"
            fi
        fi
    elif [ "$PLATFORM" = "vps" ]; then
        echo "Reality直连  : 未启用(每次 install/re/update 时加上 REALITY_PORT=端口号 才会开启,不会沿用上次的状态)"
    fi
    echo "---------------------------------------------------------------"
    if [ "$PLATFORM" = "serv00" ]; then
        for name in web bot; do
            pidfile="${BIN_DIR}/${name}.pid"
            if [ -f "$pidfile" ] && kill -0 "$(cat "$pidfile" 2>/dev/null)" >/dev/null 2>&1; then
                green "${name}: 运行中 (PID $(cat "$pidfile"))"
            else
                red "${name}: 未运行"
            fi
        done
        [ -f "${FILE_PATH}/${SAVED_SUB_TOKEN:-$SUB_TOKEN}_vless.log" ] && echo "订阅链接文件: https://${USERNAME}.${CURRENT_DOMAIN}/${SAVED_SUB_TOKEN:-$SUB_TOKEN}_vless.log"
    else
        if [ "$INIT_SYSTEM" = "systemd" ]; then
            systemctl is-active --quiet xray-argo && green "xray-argo: 运行中" || red "xray-argo: 未运行"
            systemctl is-active --quiet cloudflared-argo && green "cloudflared-argo: 运行中" || red "cloudflared-argo: 未运行"
        elif [ "$INIT_SYSTEM" = "openrc" ]; then
            rc-service xray-argo status 2>/dev/null | grep -q started && green "xray-argo: 运行中" || red "xray-argo: 未运行"
            rc-service cloudflared-argo status 2>/dev/null | grep -q started && green "cloudflared-argo: 运行中" || red "cloudflared-argo: 未运行"
        fi
        [ -f "${FILE_PATH}/${SAVED_SUB_TOKEN:-$SUB_TOKEN}_vless.log" ] && echo "订阅文件: ${FILE_PATH}/${SAVED_SUB_TOKEN:-$SUB_TOKEN}_vless.log"
    fi
    echo "==============================================================="
}

if [ "$ACTION" = "status" ]; then
    do_status
    exit 0
fi

purple "检测到运行平台: ${PLATFORM}$( [ "$PLATFORM" = "vps" ] && echo " (init: ${INIT_SYSTEM})" )"
case "$ACTION" in
    re) purple "模式: 重新配置(未显式指定的参数沿用上次安装的值,套用新的环境变量并重启服务)" ;;
    update) purple "模式: 强制更新(重新下载 xray/cloudflared 二进制,沿用已保存的配置并重启)" ;;
esac

# serv00 多一步"安装保活服务",VPS 没有这一步
[ "$PLATFORM" = "serv00" ] && TOTAL_STEPS=7 || TOTAL_STEPS=6
[ "$WARP" = "1" ] && TOTAL_STEPS=$((TOTAL_STEPS + 1))
[ "$PLATFORM" = "vps" ] && { [ -n "$REALITY_PORT" ] || [ -n "$SAVED_REALITY_PORT" ]; } && TOTAL_STEPS=$((TOTAL_STEPS + 1))
STEP_NUM=0
step() {
    STEP_NUM=$((STEP_NUM + 1))
    purple "\n[步骤 ${STEP_NUM}/${TOTAL_STEPS}] $1"
}

# ---------------------------------------------------------------
# 目录初始化(install/re/update 都要走到这里,de/status 前面已经 exit 了)
# ---------------------------------------------------------------
if [ "$PLATFORM" = "serv00" ]; then
    # 只清理上一次由本脚本启动、且记录在 pid 文件里的进程,不再广撒网 kill 当前用户下所有进程
    graceful_kill_pidfile "${BIN_DIR}/web.pid"
    graceful_kill_pidfile "${BIN_DIR}/bot.pid"
    safe_rm "$WORKDIR" "$FILE_PATH"
    mkdir -p "$WORKDIR" "$FILE_PATH" "$BIN_DIR"
    # 755 而不是 777: public_html 需要让 devil 起的 web 服务进程能"读"到订阅文件,
    # 但不应该允许同机其他用户"写"这个目录(777 会导致任意用户可篡改/植入文件)
    chmod 755 "$WORKDIR" "$FILE_PATH" >/dev/null 2>&1
else
    mkdir -p "$WORKDIR" "$FILE_PATH" "$BIN_DIR"
fi

# ---------------------------------------------------------------
# 端口选择
# ---------------------------------------------------------------
check_port() {
  if [ "$PLATFORM" = "serv00" ]; then
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
  else
    # VPS: re/update 时旧服务本来就还占着这个端口,跳过占用检测,否则会把自己误判成端口冲突
    if [ "$ACTION" != "re" ] && [ "$ACTION" != "update" ] && command -v ss >/dev/null 2>&1 && ss -ltn 2>/dev/null | grep -q ":${VLESS_PORT} "; then
        red "端口 ${VLESS_PORT} 已被占用,请通过 VLESS_PORT=xxxx 环境变量指定其他端口后重试"
        exit 1
    fi
    export PORT=$VLESS_PORT
  fi
  purple "vless-argo 使用端口: $PORT"
}
step "检测可用端口"
check_port

# ---------------------------------------------------------------
# 统一判断 ARGO_AUTH 属于哪种模式,避免同一个正则/关键字判断在
# argo_configure / start_services(serv00) / start_services(VPS) 三处重复。
#   token        : Cloudflare Zero Trust 后台生成的 Tunnel Token(纯 base64 风格长字符串)
#   tunnelsecret : cloudflared tunnel create 生成的 JSON 凭证(含 TunnelSecret 字段)
#   quick        : 未设置 ARGO_AUTH/ARGO_DOMAIN,退回临时隧道
# ---------------------------------------------------------------
# 注意: 故意不用 "echo 结果 + $(...)  命令替换" 的写法——那样 detect_argo_mode
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
# Argo 隧道配置(两平台共用同一份逻辑,只是文件落地目录不同)
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
    # 没有 python3 时退化为 sed 基础正则匹配(不依赖 PCRE, busybox sed/grep 也兼容,
    # 不像 grep -P 在 Alpine 等 musl+busybox 系统上大概率不支持),
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
# 下载核心程序
#   serv00: 沿用原先的 freebsd 二进制(eooce/test)
#   vps   : 官方 XTLS/Xray-core + cloudflare/cloudflared
# ---------------------------------------------------------------
download_binaries() {
  ARCH=$(uname -m)
  cd "$BIN_DIR" || exit 1

  if [ "$PLATFORM" = "serv00" ]; then
    if [[ "$ARCH" =~ ^(arm|arm64|aarch64)$ ]]; then
        BASE_URL="https://github.com/eooce/test/releases/download/freebsd-arm64"
    else
        BASE_URL="https://github.com/eooce/test/releases/download/freebsd"
    fi

    if [ -x "${BIN_DIR}/web" ] && [ "$FORCE_REDOWNLOAD" != "1" ]; then
        green "web 已存在,跳过下载(如需强制重下载,用 update 子命令或设置 FORCE_REDOWNLOAD=1)"
    else
        purple "正在下载 web(xray)..."
        fetch_with_retry "${BASE_URL}/web" "${BIN_DIR}/web" || exit 1
        chmod +x "${BIN_DIR}/web"
    fi
    if [ -x "${BIN_DIR}/bot" ] && [ "$FORCE_REDOWNLOAD" != "1" ]; then
        green "bot 已存在,跳过下载"
    else
        purple "正在下载 bot(cloudflared)..."
        fetch_with_retry "${BASE_URL}/server" "${BIN_DIR}/bot" || exit 1
        chmod +x "${BIN_DIR}/bot"
    fi
    XRAY_BIN="${BIN_DIR}/web"
    CLOUDFLARED_BIN="${BIN_DIR}/bot"
  else
    case "$ARCH" in
        x86_64|amd64) XARCH="64"; CF_ARCH="amd64" ;;
        aarch64|arm64) XARCH="arm64-v8a"; CF_ARCH="arm64" ;;
        *) red "不支持的架构: $ARCH"; exit 1 ;;
    esac

    if [ -x "${BIN_DIR}/xray-core/xray" ] && [ "$FORCE_REDOWNLOAD" != "1" ]; then
        green "xray 已存在,跳过下载(如需强制重下载,用 update 子命令或设置 FORCE_REDOWNLOAD=1)"
    else
        purple "正在查询 Xray-core 最新版本号(GitHub API)..."
        fetch_with_retry "https://api.github.com/repos/XTLS/Xray-core/releases/latest" "${BIN_DIR}/xray_latest.json" || exit 1
        XRAY_VER=$(grep -oE '"tag_name"[[:space:]]*:[[:space:]]*"[^"]+"' "${BIN_DIR}/xray_latest.json" | head -n1 | cut -d'"' -f4)
        rm -f "${BIN_DIR}/xray_latest.json"
        [ -z "$XRAY_VER" ] && { red "获取 Xray-core 版本号失败(可能是 GitHub API 限流或网络问题),请检查网络后重试"; exit 1; }

        purple "正在下载 Xray-core ${XRAY_VER} (约10-20MB,视网络情况需要几秒到几十秒)..."
        fetch_with_retry "https://github.com/XTLS/Xray-core/releases/download/${XRAY_VER}/Xray-linux-${XARCH}.zip" "${BIN_DIR}/xray.zip" || exit 1

        # 校验和验证:需要本机有 sha256sum 且能拿到官方 .dgst 摘要文件,任一条件不满足则跳过校验(不阻断部署,只是降级为无校验下载)
        purple "正在校验 Xray-core 完整性..."
        if command -v sha256sum >/dev/null 2>&1 && fetch_with_retry "https://github.com/XTLS/Xray-core/releases/download/${XRAY_VER}/Xray-linux-${XARCH}.zip.dgst" "${BIN_DIR}/xray.zip.dgst"; then
            expected_sha256=$(grep -i '^SHA256' "${BIN_DIR}/xray.zip.dgst" | awk '{print $NF}')
            actual_sha256=$(sha256sum "${BIN_DIR}/xray.zip" | awk '{print $1}')
            if [ -n "$expected_sha256" ] && [ "$expected_sha256" != "$actual_sha256" ]; then
                red "Xray-core 压缩包 sha256 校验失败!预期 ${expected_sha256},实际 ${actual_sha256}。为安全起见终止部署。"
                exit 1
            elif [ -n "$expected_sha256" ]; then
                green "Xray-core sha256 校验通过"
            fi
        else
            yellow "本机无 sha256sum 或未能获取官方校验和文件,跳过完整性校验(不影响部署,但建议人工确认下载来源可信)"
        fi

        command -v unzip >/dev/null 2>&1 || (apt-get update -y && apt-get install -y unzip) >/dev/null 2>&1 || yum install -y unzip >/dev/null 2>&1 || apk add --no-cache unzip >/dev/null 2>&1
        mkdir -p "${BIN_DIR}/xray-core"
        unzip -o "${BIN_DIR}/xray.zip" -d "${BIN_DIR}/xray-core" >/dev/null && rm -f "${BIN_DIR}/xray.zip" "${BIN_DIR}/xray.zip.dgst"
        chmod +x "${BIN_DIR}/xray-core/xray"
    fi
    XRAY_BIN="${BIN_DIR}/xray-core/xray"

    if [ -x "${BIN_DIR}/cloudflared" ] && [ "$FORCE_REDOWNLOAD" != "1" ]; then
        green "cloudflared 已存在,跳过下载"
    else
        purple "正在下载 cloudflared (约40-50MB,是本脚本里最大的一个文件,请耐心等待)..."
        fetch_with_retry "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${CF_ARCH}" "${BIN_DIR}/cloudflared" || exit 1
        chmod +x "${BIN_DIR}/cloudflared"
    fi
    CLOUDFLARED_BIN="${BIN_DIR}/cloudflared"
  fi
}
step "下载并校验核心程序(网络耗时最长的一步,请耐心等待)"
download_binaries

# ---------------------------------------------------------------
# WARP 出站: 平台能力检测
#   VPS   : 官方 Xray-core v1.8+ 默认内置 wireguard outbound,直接放行
#   serv00: eooce/test 是第三方重命名的 freebsd 二进制,协议支持情况未知,
#           不能假设它和官方行为一致,必须用 -test 校验模式实测一份最小 wireguard 配置。
#           探测本身失败(比如二进制根本不认 -test 这个参数)时,出于稳妥也当作不支持处理,
#           而不是冒险继续——这是可选增强功能,宁可关掉也不要让它拖垮整个安装。
# ---------------------------------------------------------------
check_warp_supported() {
    [ "$WARP" = "1" ] || return 0

    if [ "$PLATFORM" = "vps" ]; then
        return 0
    fi

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
    else
        (apt-get update -y && apt-get install -y python3) >/dev/null 2>&1 \
            || yum install -y python3 >/dev/null 2>&1 \
            || apk add --no-cache python3 >/dev/null 2>&1
        command -v python3 >/dev/null 2>&1 && py_bin="python3"
    fi
    if [ -z "$py_bin" ]; then
        red "未找到 python3 且自动安装失败(解析注册结果需要用到),WARP 出站功能已跳过"
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
# Reality 直连节点: 端口冲突/占用检测 + 密钥生成或复用 + 防火墙放行/撤销
#   - REALITY_PORT 有值 -> 开启分支; 端口和上次相同且已有保存的密钥则直接复用(避免链接无意义地反复失效),
#     端口变了或者是第一次开启则重新生成一套密钥
#   - REALITY_PORT 为空 -> 关闭分支; 如果之前开着,撤销防火墙规则、清空已保存的密钥,
#     下次重新开启会拿到全新的密钥对
# ---------------------------------------------------------------
reality_firewall_apply() {
    local port="$1" done=0
    if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -qi "Status: active"; then
        if ufw allow "${port}/tcp" >/dev/null 2>&1; then
            green "已通过 ufw 放行端口 ${port}/tcp"
            done=1
        fi
    fi
    if command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld 2>/dev/null; then
        firewall-cmd --permanent --add-port="${port}/tcp" >/dev/null 2>&1
        firewall-cmd --reload >/dev/null 2>&1
        green "已通过 firewalld 放行端口 ${port}/tcp"
        done=1
    fi
    if [ "$done" -eq 0 ]; then
        yellow "未检测到运行中的 ufw/firewalld,如果你的 VPS 还有其他防火墙(如云厂商控制台的安全组),请自行放行 TCP 端口 ${port}"
    fi
}

reality_configure() {
    if [ -n "$REALITY_PORT" ]; then
        if [ "$REALITY_PORT" = "$PORT" ]; then
            red "REALITY_PORT(${REALITY_PORT}) 不能和 vless-argo 使用的端口(${PORT})相同,请换一个端口"
            exit 1
        fi
        # re/update 时如果端口没变(还是上次那个 Reality 端口),跳过占用检测,
        # 否则会把自己正在用的端口误判成"被占用"
        if [ "$REALITY_PORT" != "$SAVED_REALITY_PORT" ] && command -v ss >/dev/null 2>&1 && ss -ltn 2>/dev/null | grep -q ":${REALITY_PORT} "; then
            red "端口 ${REALITY_PORT} 已被占用,请换一个 REALITY_PORT 后重试"
            exit 1
        fi

        if [ "$REALITY_PORT" = "$SAVED_REALITY_PORT" ] && [ -n "$SAVED_REALITY_PRIVATE_KEY" ] && [ -n "$SAVED_REALITY_PUBLIC_KEY" ] && [ -n "$SAVED_REALITY_SHORT_ID" ]; then
            export REALITY_PRIVATE_KEY="$SAVED_REALITY_PRIVATE_KEY"
            export REALITY_PUBLIC_KEY="$SAVED_REALITY_PUBLIC_KEY"
            export REALITY_SHORT_ID="$SAVED_REALITY_SHORT_ID"
            purple "检测到已保存的 Reality 密钥对(端口未变),直接复用,不重新生成"
        else
            purple "正在生成 Reality 密钥对..."
local keypair rc

keypair=$("$XRAY_BIN" x25519 2>&1)
rc=$?

if [ $rc -ne 0 ]; then
    red "xray x25519 执行失败："
    echo "$keypair"
    unset REALITY_PORT
    return
fi

purple "xray x25519 输出："
echo "$keypair"
            # 兼容多种 xray x25519 输出格式:
            #   旧版: "Private key: xxx" / "Public key: xxx"
            #   新版(v25.3.6+): "PrivateKey: xxx" / "Password (PublicKey): xxx"
            #   (官方把公钥这行改名/加注释是为了提醒用户它能被用来探测 Reality 服务端,不代表可随意分享)
            # 只按"行首关键字"匹配,不假设关键字和冒号之间的内容(空格、括号注释等),
            # 取值时直接截掉第一个冒号之前的所有内容,避免因为标签格式变化(如中间插入的括号说明)导致匹配失败
            export REALITY_PRIVATE_KEY
            REALITY_PRIVATE_KEY=$(echo "$keypair" | grep -iE '^Private' | sed -E 's/^[^:]*:[[:space:]]*//' | tr -d '[:space:]')
            export REALITY_PUBLIC_KEY
            REALITY_PUBLIC_KEY=$(echo "$keypair" | grep -iE '^(Public|Password)' | sed -E 's/^[^:]*:[[:space:]]*//' | tr -d '[:space:]')
            export REALITY_SHORT_ID
            REALITY_SHORT_ID=$(openssl rand -hex 8 2>/dev/null || head -c8 /dev/urandom | od -An -tx1 | tr -d ' \n')
            if [ -z "$REALITY_PRIVATE_KEY" ] || [ -z "$REALITY_PUBLIC_KEY" ]; then
                red "生成 Reality 密钥对失败(xray x25519 命令输出格式可能已变化,新旧两种已知格式都尝试过仍无法解析),Reality 功能已跳过,其余部分正常安装。原始输出如下,可反馈给开发者:"
                echo "$keypair"
                unset REALITY_PORT
                return
            fi
            green "Reality 密钥对生成成功"
        fi

        # 端口变了才需要撤销旧端口的防火墙规则,避免残留一个不再使用的开放端口
        if [ -n "$SAVED_REALITY_PORT" ] && [ "$SAVED_REALITY_PORT" != "$REALITY_PORT" ]; then
            reality_firewall_revoke "$SAVED_REALITY_PORT"
        fi
        reality_firewall_apply "$REALITY_PORT"
    else
        if [ -n "$SAVED_REALITY_PORT" ]; then
            purple "本次未指定 REALITY_PORT,关闭并清理上次的 Reality 直连节点(端口: ${SAVED_REALITY_PORT})"
            reality_firewall_revoke "$SAVED_REALITY_PORT"
        fi
        export REALITY_PRIVATE_KEY=""
        export REALITY_PUBLIC_KEY=""
        export REALITY_SHORT_ID=""
    fi
}
if [ "$PLATFORM" = "vps" ] && { [ -n "$REALITY_PORT" ] || [ -n "$SAVED_REALITY_PORT" ]; }; then
    step "配置 Reality 直连节点(端口检测 + 密钥生成/复用 + 防火墙)"
    reality_configure
fi

# ---------------------------------------------------------------
# 生成 Xray 配置(协议改为 vless)
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

  # REALITY_PORT 且密钥齐全时,才拼接第二个 inbound;任何一项缺失都安静跳过,
  # 不会因为半残的 Reality 配置导致整个 Xray 起不来
  local reality_inbound="" reality_dest_json
  reality_dest_json=$(json_escape "$REALITY_DEST")
  if [ -n "$REALITY_PORT" ] && [ -n "$REALITY_PRIVATE_KEY" ] && [ -n "$REALITY_SHORT_ID" ]; then
    reality_inbound=",
        {
          \"tag\": \"vless-reality\",
          \"port\": ${REALITY_PORT},
          \"listen\": \"0.0.0.0\",
          \"protocol\": \"vless\",
          \"settings\": {
              \"clients\": [
                  { \"id\": \"${uuid_json}\", \"flow\": \"xtls-rprx-vision\" }
              ],
              \"decryption\": \"none\"
          },
          \"streamSettings\": {
              \"network\": \"tcp\",
              \"security\": \"reality\",
              \"realitySettings\": {
                  \"show\": false,
                  \"dest\": \"${reality_dest_json}:443\",
                  \"xver\": 0,
                  \"serverNames\": [\"${reality_dest_json}\"],
                  \"privateKey\": \"${REALITY_PRIVATE_KEY}\",
                  \"shortIds\": [\"${REALITY_SHORT_ID}\"]
              }
          }
        }"
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
                  "path": "/vless-argo?ed=2560"
              }
          }
        }${reality_inbound}
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
# 启动服务
#   serv00: nohup 后台进程(受共享主机限制,无 systemd 权限)
#   vps   : systemd 服务,自带开机自启 + 崩溃重启
# ---------------------------------------------------------------
start_services() {
  if [ "$PLATFORM" = "serv00" ]; then
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
  else
    detect_argo_mode
    case "$ARGO_MODE" in
        token)        cf_args="tunnel --edge-ip-version auto --no-autoupdate --protocol http2 run --token ${ARGO_AUTH}" ;;
        tunnelsecret) cf_args="tunnel --edge-ip-version auto --config ${BIN_DIR}/tunnel.yml run" ;;
        *)            cf_args="tunnel --edge-ip-version auto --no-autoupdate --protocol http2 --logfile ${WORKDIR}/boot.log --loglevel info --url http://localhost:${PORT}" ;;
    esac

    if [ "$INIT_SYSTEM" = "systemd" ]; then
        cat > /etc/systemd/system/xray-argo.service << EOF
[Unit]
Description=Xray VLESS-WS Service
After=network.target
StartLimitIntervalSec=60
StartLimitBurst=5

[Service]
Type=simple
ExecStart=${XRAY_BIN} run -c ${BIN_DIR}/config.json
Restart=on-failure
RestartSec=3
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF

        cat > /etc/systemd/system/cloudflared-argo.service << EOF
[Unit]
Description=Cloudflared Argo Tunnel
After=network.target xray-argo.service
StartLimitIntervalSec=60
StartLimitBurst=5

[Service]
Type=simple
ExecStart=${CLOUDFLARED_BIN} ${cf_args}
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

        systemctl daemon-reload
        systemctl enable xray-argo >/dev/null 2>&1
        systemctl enable cloudflared-argo >/dev/null 2>&1
        systemctl restart xray-argo >/dev/null 2>&1
        systemctl restart cloudflared-argo >/dev/null 2>&1
        sleep 2
        systemctl is-active --quiet xray-argo && green "xray-argo.service 运行中" || red "xray-argo.service 启动失败,请用 journalctl -u xray-argo 查看日志"
        systemctl is-active --quiet cloudflared-argo && green "cloudflared-argo.service 运行中" || red "cloudflared-argo.service 启动失败,请用 journalctl -u cloudflared-argo 查看日志"

    elif [ "$INIT_SYSTEM" = "openrc" ]; then
        # Alpine 等使用 OpenRC 的发行版,没有 systemd,用 /etc/init.d 脚本 + rc-service 管理
        cat > /etc/init.d/xray-argo << EOF
#!/sbin/openrc-run
name="xray-argo"
description="Xray VLESS-WS Service"
command="${XRAY_BIN}"
command_args="run -c ${BIN_DIR}/config.json"
command_background=true
pidfile="/run/\${RC_SVCNAME}.pid"
output_log="${WORKDIR}/xray.log"
error_log="${WORKDIR}/xray.err.log"
respawn_max=0

depend() {
    need net
}
EOF
        chmod +x /etc/init.d/xray-argo

        cat > /etc/init.d/cloudflared-argo << EOF
#!/sbin/openrc-run
name="cloudflared-argo"
description="Cloudflared Argo Tunnel"
command="${CLOUDFLARED_BIN}"
command_args="${cf_args}"
command_background=true
pidfile="/run/\${RC_SVCNAME}.pid"
output_log="${WORKDIR}/cloudflared.log"
error_log="${WORKDIR}/cloudflared.err.log"
respawn_max=0

depend() {
    need net
    after xray-argo
}
EOF
        chmod +x /etc/init.d/cloudflared-argo

        rc-update add xray-argo default >/dev/null 2>&1
        rc-update add cloudflared-argo default >/dev/null 2>&1
        rc-service xray-argo restart >/dev/null 2>&1
        rc-service cloudflared-argo restart >/dev/null 2>&1
        sleep 2
        rc-service xray-argo status 2>/dev/null | grep -q started && green "xray-argo (OpenRC) 运行中" || red "xray-argo (OpenRC) 启动失败,请查看 ${WORKDIR}/xray.err.log"
        rc-service cloudflared-argo status 2>/dev/null | grep -q started && green "cloudflared-argo (OpenRC) 运行中" || red "cloudflared-argo (OpenRC) 启动失败,请查看 ${WORKDIR}/cloudflared.err.log"
    fi
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
# TG 心跳监控: 只要 TG_TOKEN + TG_ID 同时设置就自动启用,无需额外开关
#   - 生成独立的 healthcheck.sh,定时探测 xray/cloudflared 是否存活
#   - 只在状态变化时(正常->异常 / 异常->恢复)推送消息,不会每次检查都刷屏
#   - 检测到异常先自动尝试重启,重启成功/失败的结果一并发送
#   - 调度: VPS 有 systemd 就用 systemd timer,serv00 和 OpenRC(Alpine)用标准 crontab
#   - 卸载(de)时由前面定义的 remove_healthcheck_schedule 统一清理,不留定时任务垃圾
# ---------------------------------------------------------------
install_healthcheck() {
    if [ -z "$TG_TOKEN" ] || [ -z "$TG_ID" ]; then
        yellow "未设置 TG_TOKEN / TG_ID,跳过心跳监控(如需启用,带上这两个环境变量重新执行本脚本即可)"
        # 防止"之前启用过、这次没传"导致旧的定时任务和脚本残留
        remove_healthcheck_schedule
        safe_rm "$HEALTH_SCRIPT" "$HEALTH_STATE"
        return
    fi

    purple "检测到 TG_TOKEN/TG_ID,正在配置心跳监控..."

    # 用占位符写文件,再用 sed 替换成真实路径/平台信息,避免直接在 heredoc 里插值时
    # BIN_DIR 等变量万一包含特殊字符导致生成的子脚本语法出错
    cat > "$HEALTH_SCRIPT" << 'HEALTHEOF'
#!/bin/bash
# 由 vless-argo 主脚本自动生成,请勿手动编辑;重新执行主脚本会覆盖,de 卸载时会自动删除
# LC_ALL=C: cron/systemd timer 启动的是全新环境,不会继承主脚本 export 的 LC_ALL,
# 这里必须显式重设,否则下面 urlencode() 按字节遍历中文/emoji 时会出现编码错误
export LC_ALL=C
STATE_FILE="__STATE_FILE__"
PLATFORM="__PLATFORM__"
INIT_SYSTEM="__INIT_SYSTEM__"
BIN_DIR="__BIN_DIR__"
HEALTH_STATE_FILE="__HEALTH_STATE__"

[ -f "$STATE_FILE" ] || exit 0
# shellcheck disable=SC1090
source "$STATE_FILE"

TG_TOKEN="$SAVED_TG_TOKEN"
TG_ID="$SAVED_TG_ID"
if [ -z "$TG_TOKEN" ] || [ -z "$TG_ID" ]; then
    exit 0
fi

# 发送失败(网络超时/被限流等)时重试一次;判断是否成功以 Telegram 返回体里的 "ok":true 为准,
# 而不是只看 curl/wget 退出码——因为 HTTP 200 但业务失败(比如被限流 429、chat_id 错误)时,退出码通常仍是 0

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

# xray 是否真正可用:进程/服务存活是前提,但存活不代表能用(配置错、内部异常都可能导致端口没起来),
# 所以额外加一层本地端口连通性探测,两者都过才算真的"up"
is_alive_xray() {
    if [ "$PLATFORM" = "serv00" ]; then
        [ -f "${BIN_DIR}/web.pid" ] && kill -0 "$(cat "${BIN_DIR}/web.pid" 2>/dev/null)" >/dev/null 2>&1 || return 1
    elif [ "$INIT_SYSTEM" = "systemd" ]; then
        systemctl is-active --quiet xray-argo || return 1
    else
        rc-service xray-argo status 2>/dev/null | grep -q started || return 1
    fi
    is_port_open "$SAVED_PORT"
}

is_alive_cf() {
    if [ "$PLATFORM" = "serv00" ]; then
        [ -f "${BIN_DIR}/bot.pid" ] && kill -0 "$(cat "${BIN_DIR}/bot.pid" 2>/dev/null)" >/dev/null 2>&1
    elif [ "$INIT_SYSTEM" = "systemd" ]; then
        systemctl is-active --quiet cloudflared-argo
    else
        rc-service cloudflared-argo status 2>/dev/null | grep -q started
    fi
}

restart_xray() {
    if [ "$PLATFORM" = "serv00" ]; then
        [ -f "${BIN_DIR}/web.pid" ] && kill -9 "$(cat "${BIN_DIR}/web.pid" 2>/dev/null)" >/dev/null 2>&1
        ( cd "$BIN_DIR" && nohup ./web -c config.json >/dev/null 2>&1 & echo $! > "${BIN_DIR}/web.pid" )
    elif [ "$INIT_SYSTEM" = "systemd" ]; then
        systemctl restart xray-argo >/dev/null 2>&1
    else
        rc-service xray-argo restart >/dev/null 2>&1
    fi
    sleep 3
    is_alive_xray
}

restart_cf() {
    if [ "$PLATFORM" = "serv00" ]; then
        [ -f "${BIN_DIR}/bot.pid" ] && kill -9 "$(cat "${BIN_DIR}/bot.pid" 2>/dev/null)" >/dev/null 2>&1
        ( cd "$BIN_DIR" && nohup ./bot ${SAVED_BOT_ARGS} >/dev/null 2>&1 & echo $! > "${BIN_DIR}/bot.pid" )
    elif [ "$INIT_SYSTEM" = "systemd" ]; then
        systemctl restart cloudflared-argo >/dev/null 2>&1
    else
        rc-service cloudflared-argo restart >/dev/null 2>&1
    fi
    sleep 3
    is_alive_cf
}

# 取当前生效的 Argo 域名。
# 固定隧道(设置了 ARGO_AUTH,token 或 TunnelSecret 模式)域名是绑定好的,不会变,直接返回。
# quick tunnel(未设置 ARGO_AUTH)模式下,每次 cloudflared 重启域名都会重新随机分配,需要从 boot.log 里解析;
# wait_retries>0 时会重试等待(用于刚重启完、隧道还没建立好的情况),平时每轮只读一次不等待,避免每2分钟都白等几秒。
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
    new_link="vless://${SAVED_UUID}@${SAVED_CFIP}:${SAVED_CFPORT}?encryption=none&security=tls&sni=${cur_domain}&type=ws&host=${cur_domain}&path=%2Fvless-argo%3Fed%3D2560#vless-argo-__PLATFORM__-$(hostname)"
    msg="${msg}🔄 Argo隧道域名已变化: ${prev_domain} → ${cur_domain}"$'\n'"新节点链接:"$'\n'"${new_link}"$'\n'
    # 同步刷新本地订阅文件内容,避免文件里存的还是老域名的链接
    if [ -n "$SAVED_FILE_PATH" ] && [ -n "$SAVED_SUB_TOKEN" ] && [ -d "$SAVED_FILE_PATH" ]; then
        echo "$new_link" > "${SAVED_FILE_PATH}/${SAVED_SUB_TOKEN}_vless.log" 2>/dev/null
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
        -e "s#__PLATFORM__#${PLATFORM}#g" \
        -e "s#__INIT_SYSTEM__#${INIT_SYSTEM}#g" \
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

    if [ "$PLATFORM" = "vps" ] && [ "$INIT_SYSTEM" = "systemd" ]; then
        cat > /etc/systemd/system/vless-argo-health.service << EOF
[Unit]
Description=vless-argo healthcheck (${HEALTH_MARK})

[Service]
Type=oneshot
ExecStart=${HEALTH_SCRIPT}
EOF
        cat > /etc/systemd/system/vless-argo-health.timer << EOF
[Unit]
Description=Run vless-argo healthcheck every 2 minutes (${HEALTH_MARK})

[Timer]
OnBootSec=1min
OnUnitActiveSec=2min

[Install]
WantedBy=timers.target
EOF
        systemctl daemon-reload
        systemctl enable --now vless-argo-health.timer >/dev/null 2>&1
        if systemctl is-active --quiet vless-argo-health.timer; then
            green "已通过 systemd timer 启用心跳监控(每2分钟探测一次)"
        else
            red "vless-argo-health.timer 启动失败,请用 systemctl status vless-argo-health.timer 查看"
        fi
    else
        if command -v crontab >/dev/null 2>&1; then
            ( crontab -l 2>/dev/null | grep -v "$HEALTH_MARK"; echo "*/2 * * * * ${HEALTH_SCRIPT} >/dev/null 2>&1 # ${HEALTH_MARK}" ) | crontab -
            green "已通过 crontab 启用心跳监控(每2分钟探测一次)"
        else
            red "未找到 crontab 命令,心跳脚本已生成但未能自动加入定时任务,请手动配置: */2 * * * * ${HEALTH_SCRIPT}"
        fi
    fi
}

# ---------------------------------------------------------------
# serv00 专属:全自动保活服务(VPS 用 systemd 自带保活,无需此步骤)
# ---------------------------------------------------------------
install_keepalive() {
    [ "$PLATFORM" != "serv00" ] && return
    purple "正在安装保活服务中,请稍等......"
    devil www del "keep.${USERNAME}.${CURRENT_DOMAIN}" > /dev/null 2>&1
    devil www add "keep.${USERNAME}.${CURRENT_DOMAIN}" nodejs /usr/local/bin/node18 > /dev/null 2>&1
    keep_path="$HOME/domains/keep.${USERNAME}.${CURRENT_DOMAIN}/public_nodejs"
    [ -d "$keep_path" ] || mkdir -p "$keep_path"
    purple "正在下载保活脚本..."
    fetch_with_retry "https://xray.ssss.nyc.mn/vmess.js" "${keep_path}/app.js"

    cat > "${keep_path}/.env" <<EOF
UUID=${UUID}
CFIP=${CFIP}
CFPORT=${CFPORT}
SUB_TOKEN=${SUB_TOKEN}
ARGO_DOMAIN=${ARGO_DOMAIN}
ARGO_AUTH=$([[ -z "$ARGO_AUTH" ]] && echo "" || ([[ "$ARGO_AUTH" =~ ^\{.* ]] && echo "'$ARGO_AUTH'" || echo "$ARGO_AUTH"))
EOF
    devil www add "${USERNAME}.${CURRENT_DOMAIN}" php > /dev/null 2>&1
    [ -f "${FILE_PATH}/index.html" ] || fetch_with_retry "https://github.com/eooce/Sing-box/releases/download/00/index.html" "${FILE_PATH}/index.html"
    ln -fs /usr/local/bin/node18 ~/bin/node > /dev/null 2>&1
    ln -fs /usr/local/bin/npm18 ~/bin/npm > /dev/null 2>&1
    mkdir -p ~/.npm-global
    npm config set prefix '~/.npm-global'
    echo 'export PATH=~/.npm-global/bin:~/bin:$PATH' >> "$HOME/.bash_profile" && source "$HOME/.bash_profile"
    rm -rf "$HOME/.npmrc" > /dev/null 2>&1
    purple "正在安装 npm 依赖(dotenv/axios),共享主机上这一步可能比较慢..."
    (cd "${keep_path}" && npm install dotenv axios --silent > /dev/null 2>&1)
    rm -f "$HOME/domains/keep.${USERNAME}.${CURRENT_DOMAIN}/public_nodejs/public/index.html" > /dev/null 2>&1
    devil www restart "keep.${USERNAME}.${CURRENT_DOMAIN}" > /dev/null 2>&1
    check_url="http://keep.${USERNAME}.${CURRENT_DOMAIN}/${USERNAME}"
    if [ "$HAVE_CURL" = 1 ]; then
        check_result=$(curl -skL "$check_url")
    else
        check_result=$(wget -qO- "$check_url")
    fi
    if echo "$check_result" | grep -q "running"; then
        green "全自动保活服务安装成功"
    else
        red "保活服务安装可能未成功,请访问 http://keep.${USERNAME}.${CURRENT_DOMAIN}/status 检查"
    fi
}

# ---------------------------------------------------------------
# 生成订阅链接(vless://)
# ---------------------------------------------------------------
generate_links() {
  argodomain=$(get_argodomain)
  echo -e "\e[1;32mArgoDomain: \e[1;35m${argodomain}\e[0m\n"

  NAME="vless-argo-${PLATFORM}-${USERNAME}"
  LINK="vless://${UUID}@${CFIP}:${CFPORT}?encryption=none&security=tls&sni=${argodomain}&type=ws&host=${argodomain}&path=%2Fvless-argo%3Fed%3D2560#${NAME}"

  echo "$LINK" > "${FILE_PATH}/${SUB_TOKEN}_vless.log"
  echo "$LINK"

  # Reality 直连节点是独立于 Argo 的第二个节点,不走隧道,不需要域名,用公网IP拼接;
  # 只在本次实际生效(REALITY_PORT 有值且密钥齐全)时才生成,关闭状态下不追加
  if [ "$PLATFORM" = "vps" ] && [ -n "$REALITY_PORT" ] && [ -n "$REALITY_PUBLIC_KEY" ]; then
    local pub_ip reality_link
    pub_ip=$(get_public_ip)
    if [ -n "$pub_ip" ]; then
        reality_link="vless://${UUID}@${pub_ip}:${REALITY_PORT}?encryption=none&security=reality&sni=${REALITY_DEST}&fp=chrome&pbk=${REALITY_PUBLIC_KEY}&sid=${REALITY_SHORT_ID}&type=tcp&flow=xtls-rprx-vision#reality-${HOSTNAME}"
        echo "$reality_link" >> "${FILE_PATH}/${SUB_TOKEN}_vless.log"
        green "\nReality 直连节点(不走Argo,延迟更低,但会暴露真实IP):"
        echo "$reality_link"
    else
        yellow "\nReality 节点已启用,但获取公网IP失败,暂时无法生成链接;可稍后执行 status 命令重试获取"
    fi
  fi

  if [ "$PLATFORM" = "serv00" ]; then
    green "\n订阅链接: https://${USERNAME}.${CURRENT_DOMAIN}/${SUB_TOKEN}_vless.log\n"
    # 注意: 这里只删 boot.log(避免重启cloudflared后读到旧的隧道域名)。
    # config.json/tunnel.json/tunnel.yml 不能删——心跳监控掉线自动重启时(./web -c config.json / ./bot --config tunnel.yml)还需要用到它们。
    rm -rf "${WORKDIR}/boot.log"
    step "安装保活服务"
    install_keepalive
  else
    green "\n节点信息已保存到: ${FILE_PATH}/${SUB_TOKEN}_vless.log"
    yellow "VPS 模式下服务由 systemd 托管(xray-argo / cloudflared-argo),无需额外保活。"
    yellow "如需通过域名访问该订阅文件,请自行用 Nginx/Caddy 反代 ${FILE_PATH} 目录。\n"
  fi
}
step "生成订阅链接"
generate_links

purple "\n[附加] 配置 TG 心跳监控(节点/隧道保活状态通知)"
install_healthcheck

case "$ACTION" in
    re) green "\n重新配置完成! 已用新参数重启服务 (platform: ${PLATFORM})\n" ;;
    update) green "\n更新完成! 已重新下载二进制并重启服务 (platform: ${PLATFORM})\n" ;;
    *) green "\nRunning done! (platform: ${PLATFORM})\n" ;;
esac