#!/bin/bash

re="\033[0m"
red="\033[1;91m"
green="\e[1;32m"
yellow="\e[1;33m"
purple="\e[1;35m"
red() { echo -e "\e[1;91m$1\033[0m"; }
green() { echo -e "\e[1;32m$1\033[0m"; }
yellow() { echo -e "\e[1;33m$1\033[0m"; }
purple() { echo -e "\e[1;35m$1\033[0m"; }
reading() { read -p "$(red "$1")" "$2"; }
export LC_ALL=C
HOSTNAME=$(hostname)
USERNAME=$(whoami | tr '[:upper:]' '[:lower:]')
export UUID=${UUID:-$(uuidgen -r)}
export SUB_PATH=${SUB_PATH:-${UUID:0:8}}
if [[ "$HOSTNAME" =~ ct8 ]]; then CURRENT_DOMAIN="ct8.pl"; elif [[ "$HOSTNAME" =~ hostuno ]]; then CURRENT_DOMAIN="useruno.com"; else CURRENT_DOMAIN="serv00.net"; fi
command -v curl &>/dev/null && COMMAND="curl -so" || command -v wget &>/dev/null && COMMAND="wget -qO" || { red "Error: neither curl nor wget found, please install one of them." >&2; exit 1; }
WORKDIR="$HOME/domains/${USERNAME}.${CURRENT_DOMAIN}/public_nodejs"

# VLESS-WS-Argo 只需要一个本地 TCP 端口给 Argo 隧道用，不需要额外的 UDP 端口
check_port () {
port_list=$(devil port list)
tcp_ports=$(echo "$port_list" | grep -c "tcp")
if [[ $tcp_ports -ne 1 ]]; then
    red "端口规则不符合要求，正在调整..."
    if [[ $tcp_ports -gt 1 ]]; then
        tcp_to_delete=$((tcp_ports - 1))
        echo "$port_list" | awk '/tcp/ {print $1, $2}' | head -n $tcp_to_delete | while read port type; do
            devil port del $type $port >/dev/null 2>&1
            green "已删除TCP端口: $port"
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
                yellow "端口 $tcp_port 不可用，尝试其他端口..."
            fi
        done
    fi
    green "端口已调整完成,将断开ssh连接,请重新连接shh重新执行脚本"
    quick_command
    devil binexec on >/dev/null 2>&1
    kill -9 $(ps -o ppid= -p $$) >/dev/null 2>&1
else
    tcp_port=$(echo "$port_list" | awk '/tcp/ {print $1}')
fi
purple "vless-ws-argo使用的tcp端口为: $tcp_port"
export ARGO_PORT=$tcp_port
}

install_vless() {
bash -c 'ps aux | grep $(whoami) | grep -v "sshd\|bash\|grep" | awk "{print \$2}" | xargs -r kill -9 >/dev/null 2>&1' >/dev/null 2>&1
echo -e "${yellow}本脚本仅安装单协议${purple}vless-ws-tls(argo)${re}"
reading "\n确定继续安装吗？(直接回车即确认安装)【y/n】: " choice
  case "${choice:-y}" in
    [Yy]|"")
    	clear
        check_port
        argo_configure
        warp_configure
        monitor_configure
        install_service
      ;;
    [Nn]) exit 0 ;;
    *) red "无效的选择，请输入y或n" && menu ;;
  esac
}

uninstall_vless() {
  reading "\n确定要卸载吗？【y/n】: " choice
    case "$choice" in
        [Yy])
	          bash -c 'ps aux | grep $(whoami) | grep -v "sshd\|bash\|grep" | awk "{print \$2}" | xargs -r kill -9 >/dev/null 2>&1' >/dev/null 2>&1
            remove_keepalive_cron
            devil www del ${USERNAME}.${CURRENT_DOMAIN} 2>/dev/null || true
            rm -rf ${HOME}/domains/${USERNAME}.${CURRENT_DOMAIN} 2>/dev/null || true
            rm -rf "${HOME}/bin/00" >/dev/null 2>&1
            [ -d "${HOME}/bin" ] && [ -z "$(ls -A "${HOME}/bin")" ] && rmdir "${HOME}/bin"
            sed -i '/export PATH="\$HOME\/bin:\$PATH"/d' "${HOME}/.bashrc" >/dev/null 2>&1
            source "${HOME}/.bashrc"
	          clear
       	    green "代理服务已完全卸载"
          ;;
        [Nn]) exit 0 ;;
    	  *) red "无效的选择,请输入y或n" && menu ;;
    esac
}

reset_system() {
reading "\n确定重置系统吗吗？【y/n】: " choice
  case "$choice" in
    [Yy]) yellow "\n初始化系统中,请稍后...\n"
          bash -c 'ps aux | grep $(whoami) | grep -v "sshd\|bash\|grep" | awk "{print \$2}" | xargs -r kill -9 >/dev/null 2>&1' >/dev/null 2>&1
          remove_keepalive_cron
          find "${HOME}" -mindepth 1 ! -name "domains" ! -name "mail" ! -name "repo" ! -name "backups" -exec rm -rf {} + > /dev/null 2>&1
          devil www list | awk 'NF>=2 && $1 ~ /\./ {print $1}' | while read -r domain; do devil www del "$domain"; done
          rm -rf $HOME/domains/* > /dev/null 2>&1
          green "\n初始化系统完成!\n"
         ;;
       *) menu ;;
  esac
}

argo_configure() {
  reading "是否需要使用固定argo隧道？(直接回车将使用临时隧道)【y/n】: " argo_choice
  [[ -z $argo_choice ]] && return
  [[ "$argo_choice" != "y" && "$argo_choice" != "Y" && "$argo_choice" != "n" && "$argo_choice" != "N" ]] && { red "无效的选择, 请输入y或n"; return; }
  if [[ "$argo_choice" == "y" || "$argo_choice" == "Y" ]]; then
      reading "请输入argo固定隧道域名: " ARGO_DOMAIN
      green "你的argo固定隧道域名为: $ARGO_DOMAIN"
      reading "请输入argo固定隧道密钥（Json或Token）: " ARGO_AUTH
      green "你的argo固定隧道密钥为: $ARGO_AUTH"
  else
      green "ARGO隧道变量未设置，将使用临时隧道"
      return
  fi

  if [[ $ARGO_AUTH =~ TunnelSecret ]]; then
    echo $ARGO_AUTH > tunnel.json
    cat > tunnel.yml << EOF
tunnel: $(cut -d\" -f12 <<< "$ARGO_AUTH")
credentials-file: tunnel.json
protocol: http2

ingress:
  - hostname: $ARGO_DOMAIN
    service: http://localhost:$ARGO_PORT
    originRequest:
      noTLSVerify: true
  - service: http_status:404
EOF
  else
    yellow "\n当前使用的是token,请在cloudflare里设置隧道端口为${purple}${ARGO_PORT}${re}"
  fi
}

warp_configure() {
  reading "是否启用全局WARP出站？(直接回车默认不启用)【y/n】: " warp_choice
  if [[ "$warp_choice" == "y" || "$warp_choice" == "Y" ]]; then
    export GLOBAL_WARP=true
    green "已启用全局WARP出站(基于xray wireguard outbound;若UDP出站不可用或注册失败会自动降级为direct)"
  else
    export GLOBAL_WARP=false
    green "未启用WARP,出站全部走direct"
  fi
}

monitor_configure() {
  reading "是否启用Telegram健康告警？(xray/cloudflared多次重启仍失败、或服务长时间无法访问时会推送通知；直接回车默认不启用)【y/n】: " tg_choice
  if [[ "$tg_choice" == "y" || "$tg_choice" == "Y" ]]; then
    reading "请输入Telegram Bot Token: " TG_BOT_TOKEN
    reading "请输入Telegram Chat ID: " TG_CHAT_ID
    export TG_BOT_TOKEN TG_CHAT_ID
    green "已启用Telegram健康告警"
  else
    export TG_BOT_TOKEN="" TG_CHAT_ID=""
    green "未启用Telegram健康告警(可稍后重装时补充)"
  fi
}

setup_keepalive_cron() {
  local cron_tag="# vless_argo_keepalive"
  local monitor_script="$HOME/bin/vless_argo_monitor.sh"
  mkdir -p "$HOME/bin"

  # 独立的探测脚本: 除了原有的"访问自身域名保活"，
  # 额外做连续失败计数;达到阈值(3次≈30分钟)时通过Telegram告警一次，
  # 恢复后再发一条恢复通知，避免刷屏。TG_BOT_TOKEN/TG_CHAT_ID留空则静默跳过通知。
  cat > "$monitor_script" <<MONEOF
#!/bin/bash
URL="https://${USERNAME}.${CURRENT_DOMAIN}"
ENV_FILE="${WORKDIR}/.env"
STATE_FILE="\$HOME/.vless_argo_health_state"
[ -f "\$ENV_FILE" ] && source "\$ENV_FILE"

fail_count=0
alerted=0
[ -f "\$STATE_FILE" ] && source "\$STATE_FILE"

notify() {
  [ -z "\$TG_BOT_TOKEN" ] && return
  [ -z "\$TG_CHAT_ID" ] && return
  curl -s -m 10 -X POST "https://api.telegram.org/bot\${TG_BOT_TOKEN}/sendMessage" \\
    -d chat_id="\${TG_CHAT_ID}" -d text="[\$(hostname)] \$1" >/dev/null 2>&1
}

code=\$(curl -s -o /dev/null -m 10 -w "%{http_code}" "\$URL")

if [ "\$code" == "200" ]; then
  if [ "\$alerted" == "1" ]; then
    notify "服务已恢复正常(http 200): \$URL"
  fi
  fail_count=0
  alerted=0
else
  fail_count=\$((fail_count + 1))
  if [ "\$fail_count" -ge 3 ] && [ "\$alerted" != "1" ]; then
    notify "服务疑似异常: \$URL 连续\${fail_count}次探测失败(最近状态码 \${code:-无响应})，请检查"
    alerted=1
  fi
fi

echo "fail_count=\$fail_count" > "\$STATE_FILE"
echo "alerted=\$alerted" >> "\$STATE_FILE"
MONEOF
  chmod +x "$monitor_script"

  local cron_line="*/10 * * * * $monitor_script >/dev/null 2>&1 ${cron_tag}"
  (crontab -l 2>/dev/null | grep -vF "${cron_tag}"; echo "${cron_line}") | crontab -
  green "已添加保活+健康监控定时任务(每10分钟探测一次，连续3次失败将尝试Telegram告警)"
}

remove_keepalive_cron() {
  local cron_tag="# vless_argo_keepalive"
  crontab -l 2>/dev/null | grep -vF "${cron_tag}" | crontab -
  rm -f "$HOME/bin/vless_argo_monitor.sh" "$HOME/.vless_argo_health_state" 2>/dev/null
}

write_app_js() {
  cat > "$1" <<'JSEOF'
#!/usr/bin/env node

const fs = require('fs');
const path = require('path');
const os = require('os');
const http = require('http');
const crypto = require('crypto');
const dgram = require('dgram');
const axios = require('axios');
const koffi = require('koffi');
const { spawn, spawnSync } = require('child_process');

try { require('dotenv').config(); } catch { /* ignore if dotenv unavailable */ }

// ======================== 环境变量定义 ========================
const FILE_PATH      = process.env.FILE_PATH      || '.npm';     // sub.txt订阅文件路径
const SUB_PATH       = process.env.SUB_PATH       || 'sub';      // 订阅sub路径，默认为sub
const UUID           = process.env.UUID           || '68aa231f-703e-4547-967e-12ed0b36420f'; // UUID
const ARGO_DOMAIN    = process.env.ARGO_DOMAIN    || '';         // argo固定隧道域名,留空即使用临时隧道
const ARGO_AUTH      = process.env.ARGO_AUTH      || '';         // argo固定隧道token或json,留空即使用临时隧道
const ARGO_PORT      = Number(process.env.ARGO_PORT) || 8001;    // argo固定隧道端口(本地vless-ws监听端口)
const CFIP           = process.env.CFIP           || 'ali.ztyawc.de'; // 优选域名或优选IP
const CFPORT         = Number(process.env.CFPORT) || 443;        // 优选域名或优选IP对应端口
const PORT           = Number(process.env.PORT)   || 3000;       // http订阅端口
const NAME           = process.env.NAME           || '';         // 节点名称
const DISABLE_ARGO   = process.env.DISABLE_ARGO   || false;      // 设置为true时禁用argo
const GLOBAL_WARP    = String(process.env.GLOBAL_WARP).toLowerCase() === 'true'; // true时全部出站走WARP，否则不启用WARP
const TG_BOT_TOKEN    = process.env.TG_BOT_TOKEN    || '';        // Telegram Bot Token,留空则不发送告警
const TG_CHAT_ID      = process.env.TG_CHAT_ID      || '';        // Telegram Chat ID,留空则不发送告警
// ==============================================================

const ROOT = process.cwd();
const runtimeFilePath = path.resolve(ROOT, FILE_PATH);
const libraryDir = runtimeFilePath;
const xrayConfigPath = path.resolve(runtimeFilePath, 'config.json');
const warpConfigPath = path.resolve(runtimeFilePath, 'warp.json'); // 独立WARP身份持久化文件，注册一次后复用
const bootLogPath = path.resolve(runtimeFilePath, 'boot.log');
const subPath = path.resolve(runtimeFilePath, 'sub.txt');
const listPath = path.resolve(runtimeFilePath, 'list.txt');
const subscribePath = '/' + SUB_PATH.replace(/^\//, '');

const arch = (() => {
  const a = os.arch().toLowerCase();
  if (a === 'arm64' || a === 'aarch64') return 'arm64';
  return 'amd64';
})();

// ======================== 文件清理 ========================

const pathsToDelete = ['boot.log', 'list.txt', 'config.json', 'tunnel.json', 'tunnel.yml'];
function cleanupOldFiles() {
  pathsToDelete.forEach(file => {
    const filePath = path.join(FILE_PATH, file);
    fs.unlink(filePath, () => {});
  });
  const tmpDir = path.resolve(ROOT, '.tmp');
  if (fs.existsSync(tmpDir)) {
    try { fs.rmSync(tmpDir, { recursive: true, force: true }); } catch (e) { }
  }
}

function cleanupFiles(options = {}) {
  const keepFiles = new Set(['warp.json']);
  if (options.keepSub) keepFiles.add('sub.txt');
  if (fs.existsSync(runtimeFilePath)) {
    try {
      const files = fs.readdirSync(runtimeFilePath);
      for (const file of files) {
        if (keepFiles.has(file)) continue;
        const filePath = path.resolve(runtimeFilePath, file);
        try {
          const stat = fs.statSync(filePath);
          if (stat.isDirectory()) {
            fs.rmSync(filePath, { recursive: true, force: true });
          } else {
            fs.unlinkSync(filePath);
          }
        } catch (e) { /* skip locked/in-use files */ }
      }
    } catch (e) {
      console.error('Cleanup failed:', e.message);
    }
  }
  const tmpDir = path.resolve(ROOT, '.tmp');
  if (fs.existsSync(tmpDir)) {
    try { fs.rmSync(tmpDir, { recursive: true, force: true }); } catch (e) { }
  }
}

function clearConsole() {
  process.stdout.write('\x1Bc');
}

// ======================== Argo 隧道配置 ========================

function argoType() {
  if (DISABLE_ARGO === 'true' || DISABLE_ARGO === true) {
    console.log("DISABLE_ARGO is set to true, disable argo tunnel");
    return;
  }
  if (!ARGO_AUTH || !ARGO_DOMAIN) {
    console.log("ARGO_DOMAIN or ARGO_AUTH variable is empty, use quick tunnel");
    return;
  }
  if (ARGO_AUTH.includes('TunnelSecret')) {
    fs.writeFileSync(path.join(FILE_PATH, 'tunnel.json'), ARGO_AUTH);
    const tunnelYaml = `
  tunnel: ${ARGO_AUTH.split('"')[11]}
  credentials-file: ${path.join(FILE_PATH, 'tunnel.json')}
  protocol: http2
  
  ingress:
    - hostname: ${ARGO_DOMAIN}
      service: http://localhost:${ARGO_PORT}
      originRequest:
        noTLSVerify: true
    - service: http_status:404
  `;
    fs.writeFileSync(path.join(FILE_PATH, 'tunnel.yml'), tunnelYaml);
  } else {
    console.log(`Using token connect to tunnel, please set ${ARGO_PORT} in cloudflare`);
  }
}

// ======================== WARP 身份(注册/复用) ========================
// 基于 wgcf 同款接口 (api.cloudflareclient.com/v0a884/reg) 独立注册一个 WARP 身份，
// 而不是使用写死/共享的 WireGuard 密钥。注册结果落盘到 warp.json，之后每次启动优先复用，
// 避免频繁注册触发 Cloudflare 风控/限流。
// 注：这部分逻辑跟用 sing-box 还是 xray 无关，是独立于代理内核的通用WARP账号获取流程，
// 已经过实测验证可以正常注册成功，这里原样保留。

const WARP_REG_URL = 'https://api.cloudflareclient.com/v0a884/reg';
const WARP_API_HEADERS = {
  'User-Agent': 'okhttp/3.12.1',
  'CF-Client-Version': 'a-6.10-2158',
  'Content-Type': 'application/json;charset=UTF-8'
};

// 生成一对 X25519 (Curve25519) 密钥，转成 WireGuard 使用的原始 32 字节 base64 格式。
function generateWireguardKeyPair() {
  const { publicKey, privateKey } = crypto.generateKeyPairSync('x25519', {
    publicKeyEncoding: { type: 'spki', format: 'der' },
    privateKeyEncoding: { type: 'pkcs8', format: 'der' }
  });
  const rawPrivateKey = privateKey.subarray(privateKey.length - 32);
  const rawPublicKey = publicKey.subarray(publicKey.length - 32);
  return {
    privateKey: Buffer.from(rawPrivateKey).toString('base64'),
    publicKey: Buffer.from(rawPublicKey).toString('base64')
  };
}

// 调用 Cloudflare 注册接口，拿到属于自己的 client_id(reserved)、分配的内网地址、以及对端公钥
async function registerWarp() {
  const { privateKey, publicKey } = generateWireguardKeyPair();

  const resp = await axios.post(WARP_REG_URL, {
    key: publicKey,
    install_id: '',
    fcm_token: '',
    tos: new Date().toISOString(),
    type: 'PC',
    model: 'PC',
    locale: 'en_US'
  }, {
    headers: WARP_API_HEADERS,
    timeout: 10000
  });

  const data = resp.data;
  if (!data || !data.config || !data.config.peers || !data.config.peers[0]) {
    throw new Error('WARP注册接口返回数据格式异常');
  }

  const cfg = data.config;
  const peer = cfg.peers[0];
  const reserved = Array.from(Buffer.from(cfg.client_id, 'base64'));

  let endpointHost = 'engage.cloudflareclient.com';
  let endpointPort = 2408;
  if (peer.endpoint && peer.endpoint.host) {
    const idx = peer.endpoint.host.lastIndexOf(':');
    if (idx !== -1) {
      endpointHost = peer.endpoint.host.slice(0, idx);
      endpointPort = Number(peer.endpoint.host.slice(idx + 1)) || 2408;
    } else {
      endpointHost = peer.endpoint.host;
    }
  }

  return {
    private_key: privateKey,
    public_key: peer.public_key,
    endpoint_host: endpointHost,
    endpoint_port: endpointPort,
    address_v4: cfg.interface && cfg.interface.addresses ? cfg.interface.addresses.v4 : null,
    address_v6: cfg.interface && cfg.interface.addresses ? cfg.interface.addresses.v6 : null,
    reserved,
    account_id: data.id || null,
    registered_at: new Date().toISOString()
  };
}

// 校验本地 warp.json 内容是否完整可用
function isValidWarpConfig(cfg) {
  return !!(cfg && cfg.private_key && cfg.public_key && cfg.endpoint_host &&
    Array.isArray(cfg.reserved) && cfg.reserved.length === 3 && cfg.address_v4);
}

// 探测出站 UDP 是否可用：向公共 DNS(1.1.1.1/8.8.8.8) 的 53 端口发一个标准 DNS 查询包，
// 能收到任意响应即说明本机允许 UDP 出站；serv00/ct8 这类共享托管沙箱通常只放行 TCP，
// UDP 出站会被直接丢弃，导致 WireGuard(UDP)握手永远无法完成。
function udpEgressProbe(host, port, timeoutMs) {
  return new Promise((resolve) => {
    let socket;
    try {
      socket = dgram.createSocket('udp4');
    } catch (e) {
      resolve(false);
      return;
    }
    let settled = false;
    const finish = (ok) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      try { socket.close(); } catch (e) { /* ignore */ }
      resolve(ok);
    };
    const timer = setTimeout(() => finish(false), timeoutMs);
    socket.once('error', () => finish(false));
    socket.once('message', () => finish(true));
    const query = Buffer.from([
      0x12, 0x34, 0x01, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
      0x0a, 0x63, 0x6c, 0x6f, 0x75, 0x64, 0x66, 0x6c, 0x61, 0x72, 0x65,
      0x03, 0x63, 0x6f, 0x6d, 0x00,
      0x00, 0x01, 0x00, 0x01
    ]);
    socket.send(query, port, host, (err) => {
      if (err) finish(false);
    });
  });
}

async function detectUdpEgress() {
  console.log('WARP: 正在检测本机出站 UDP 连通性（WireGuard 依赖 UDP）...');
  const targets = [
    { host: '1.1.1.1', port: 53 },
    { host: '8.8.8.8', port: 53 }
  ];
  for (const t of targets) {
    const ok = await udpEgressProbe(t.host, t.port, 3000);
    console.log(`WARP: UDP探测 ${t.host}:${t.port} -> ${ok ? '成功(有响应)' : '失败(超时/无响应)'}`);
    if (ok) {
      console.log('WARP: 检测结果 -> 本机支持出站UDP，将继续安装/使用WARP');
      return true;
    }
  }
  console.log('WARP: 检测结果 -> 本机不支持出站UDP（大概率是VPS/托管商限制），WireGuard无法工作，将跳过WARP，自动使用纯direct出站');
  return false;
}

// 用 xray 自带的 `-test` 配置校验模式，实测一份只含 wireguard 出站的最小配置，判断
// 当前这份 xray 二进制是否认识这套 wireguard outbound 字段结构。
// 相比之前 sing-box .so 方案：这里是真正独立的子进程调用(spawnSync)，即使这份二进制
// 完全不认识 wireguard/不支持 -test，最多是这次调用失败返回错误，绝不会连累 Node 主进程。
function probeXrayWarpSupport(xrayBinPath) {
  const probeConfigPath = path.resolve(runtimeFilePath, '.warp-probe.json');
  const probeConfig = {
    outbounds: [{
      protocol: 'wireguard',
      tag: 'warp-probe',
      settings: {
        secretKey: 'wIol6i8Wl4Wp+i6PXVXwZBoTr6Ez2FZ3+Rjez7cvvV0=',
        address: ['172.16.0.2/32'],
        peers: [{ publicKey: 'bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo=', endpoint: '162.159.192.1:2408' }]
      }
    }]
  };

  let result;
  try {
    fs.writeFileSync(probeConfigPath, JSON.stringify(probeConfig));
    result = spawnSync(xrayBinPath, ['run', '-test', '-c', probeConfigPath], { encoding: 'utf8', timeout: 10000 });
  } catch (e) {
    console.log('WARP: xray兼容性探测调用异常(' + e.message + ')，出于稳妥判定为不支持');
    try { fs.unlinkSync(probeConfigPath); } catch (e2) { /* ignore */ }
    return false;
  }
  try { fs.unlinkSync(probeConfigPath); } catch (e) { /* ignore */ }

  const output = ((result && result.stdout) || '') + ((result && result.stderr) || '');
  if (/unknown (outbound )?protocol|not registered|invalid protocol|unknown config/i.test(output)) {
    console.log('WARP: 当前 xray 二进制不支持 wireguard 出站，已自动关闭 WARP，其余部分正常安装');
    return false;
  }
  if (/flag provided but not defined|unknown (flag|command)|no such (flag|command)/i.test(output)) {
    console.log('WARP: 当前 xray 二进制不支持 -test 配置校验模式，无法安全确认WARP是否受支持，出于稳妥已自动关闭 WARP');
    return false;
  }
  console.log('WARP: xray 兼容性探测通过，支持 wireguard 出站');
  return true;
}

// 针对性探测：给已注册到的真实 WARP endpoint(host:port) 发一个 UDP 包，仅用于打印更明确的
// 排障信息，不影响是否启用WARP的决策(WireGuard对非法握手包本身也不会回应，收不到响应不代表被墙)
function probeWarpEndpoint(host, port, timeoutMs) {
  return new Promise((resolve) => {
    let socket;
    try {
      socket = dgram.createSocket('udp4');
    } catch (e) {
      resolve('error');
      return;
    }
    let settled = false;
    const finish = (result) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      try { socket.close(); } catch (e) { /* ignore */ }
      resolve(result);
    };
    const timer = setTimeout(() => finish('no_response'), timeoutMs);
    socket.once('error', () => finish('rejected'));
    socket.once('message', () => finish('responded'));
    const probe = Buffer.from([0x01, 0x00, 0x00, 0x00, 0x00]);
    socket.send(probe, port, host, (err) => {
      if (err) finish('rejected');
    });
  });
}

async function diagnoseWarpEndpoint(cfg) {
  console.log(`WARP: 正在针对性探测 WARP 端点 ${cfg.endpoint_host}:${cfg.endpoint_port} ...`);
  const result = await probeWarpEndpoint(cfg.endpoint_host, cfg.endpoint_port, 3000);
  if (result === 'responded') {
    console.log('WARP: 端点探测 -> 收到响应，WARP端点大概率可达');
  } else if (result === 'rejected') {
    console.log('WARP: 端点探测 -> 收到明确拒绝(ICMP不可达等)，该主机很可能专门限制了WARP端点，即使继续尝试WARP大概率也无法生效');
  } else {
    console.log('WARP: 端点探测 -> 未收到任何响应。这不能100%证明被墙，仍会继续尝试使用WARP；如果实际测试WARP始终未生效，大概率是针对性限制了WARP端点(而非通用UDP出站问题)');
  }
}

// 综合流程：探测UDP -> 探测xray是否支持wireguard -> 复用/注册WARP身份
async function getOrCreateWarpIdentity(xrayBinPath) {
  if (!GLOBAL_WARP) {
    return null;
  }

  const udpOk = await detectUdpEgress();
  if (!udpOk) {
    return null;
  }

  const supported = probeXrayWarpSupport(xrayBinPath);
  if (!supported) {
    return null;
  }

  let cfg = null;
  try {
    if (fs.existsSync(warpConfigPath)) {
      const loaded = JSON.parse(fs.readFileSync(warpConfigPath, 'utf8'));
      if (isValidWarpConfig(loaded)) {
        console.log('WARP: 检测到本地 warp.json，复用已注册身份');
        cfg = loaded;
      } else {
        console.log('WARP: 本地 warp.json 内容不完整，将重新注册');
      }
    }
  } catch (e) {
    console.log('WARP: 读取 warp.json 失败(' + e.message + ')，将重新注册');
  }

  if (!cfg) {
    try {
      console.log('WARP: 未找到可用身份，正在向 Cloudflare 注册新的 WARP 身份...');
      cfg = await registerWarp();
      fs.writeFileSync(warpConfigPath, JSON.stringify(cfg, null, 2));
      console.log('WARP: 注册成功，已保存到 warp.json，后续将直接复用');
    } catch (e) {
      console.error('WARP: 注册失败(' + e.message + ')，本次运行将禁用 WARP，自动降级为纯 direct 出站');
      return null;
    }
  }

  await diagnoseWarpEndpoint(cfg);
  return cfg;
}

// ======================== 下载库文件 ========================

async function sha256Matches(filePath, expected) {
  if (!expected) return true;
  const actual = await sha256(filePath);
  return actual.toLowerCase() === expected.toLowerCase();
}

function sha256(filePath) {
  return new Promise((resolve, reject) => {
    const hash = crypto.createHash('sha256');
    const stream = fs.createReadStream(filePath);
    stream.on('data', chunk => hash.update(chunk));
    stream.on('end', () => resolve(hash.digest('hex')));
    stream.on('error', reject);
  });
}

async function downloadLibrary(url, fileName, expectedSha256) {
  const target = path.resolve(libraryDir, fileName);
  if (fs.existsSync(target) && await sha256Matches(target, expectedSha256)) {
    console.log(`Using cached native library: ${target}`);
    return target;
  }
  await fs.promises.mkdir(libraryDir, { recursive: true });
  const tmp = path.resolve(libraryDir, `${fileName}.download`);
  const writer = fs.createWriteStream(tmp);
  console.log(`Downloading ${url} -> ${target}`);
  const response = await axios.get(url, { responseType: 'stream', timeout: 3 * 60 * 1000 });
  if (response.status < 200 || response.status >= 300) {
    throw new Error(`Failed to download ${url}: HTTP ${response.status}`);
  }
  response.data.pipe(writer);
  await new Promise((resolve, reject) => writer.on('finish', resolve).on('error', reject));
  if (!(await sha256Matches(tmp, expectedSha256))) {
    throw new Error(`SHA-256 mismatch for ${tmp}`);
  }
  await fs.promises.rename(tmp, target);
  return target;
}

// ======================== 告警通知 ========================
// 仅在 Node 主进程仍存活、但某个子组件反复崩溃/重启耗尽时使用；
// 若 Node 主进程本身挂了，这里发不出任何东西——那种情况由 bash 侧的
// vless_argo_monitor.sh(crontab 每10分钟探测一次)负责兜底告警。
async function notifyFatal(message) {
  if (!TG_BOT_TOKEN || !TG_CHAT_ID) return;
  try {
    await axios.post(`https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage`, {
      chat_id: TG_CHAT_ID,
      text: `[${os.hostname()}] ${message}`
    }, { timeout: 5000 });
  } catch (e) {
    console.error('Telegram 通知发送失败:', e.message);
  }
}

// ======================== 重启节流器(滑动窗口式) ========================
// 与"从进程启动至今累计崩溃次数"不同: 只要这一次运行存活时间达到 stableMs，
// 就说明期间是健康的，重启计数清零。这样只有短时间内反复崩溃才会耗尽重启次数，
// 长期运行、偶尔崩一次的场景不会被历史记录拖累到最终放弃重启。
function createRestartGuard(maxRestarts = 5, stableMs = 5 * 60 * 1000) {
  let restarts = 0;
  return {
    shouldRestart(aliveMs) {
      if (aliveMs >= stableMs) restarts = 0;
      if (restarts >= maxRestarts) return false;
      restarts++;
      return true;
    },
    get count() { return restarts; },
    get max() { return maxRestarts; }
  };
}

// ======================== Koffi 服务管理 ========================

function createService(name, libraryPath, startSymbol, stopSymbol, payload, restartOptions = {}) {
  const lib = koffi.load(libraryPath);
  const startFn = lib.func(`int ${startSymbol}(str)`);
  const stopFn = lib.func(`int ${stopSymbol}()`);
  const { autoRestart = false, maxRestarts = 5, stableMs = 5 * 60 * 1000 } = restartOptions;
  const guard = createRestartGuard(maxRestarts, stableMs);
  let stopped = false;

  function launch() {
    const startedAt = Date.now();
    startFn.async(payload || '', (err, code) => {
      if (stopped) return; // 主动调用了 stop()，不算崩溃，不重启
      const aliveMs = Date.now() - startedAt;
      if (err) {
        console.error(`${name} native service failed: ${err.message}`);
      } else if (code !== 0) {
        console.warn(`${name} native service exited with code ${code}(存活${Math.round(aliveMs / 1000)}秒)`);
      } else {
        return; // code === 0 视为正常退出，不重启
      }
      if (!autoRestart) return;
      if (guard.shouldRestart(aliveMs)) {
        console.warn(`${name} 将在3秒后自动重启(第${guard.count}/${guard.max}次)`);
        setTimeout(launch, 3000);
      } else {
        console.error(`${name} 短时间内反复退出且重启次数已达上限，不再重启`);
        notifyFatal(`${name} 反复退出，已停止自动重启(连续在${Math.round(stableMs / 60000)}分钟内失败${guard.max}次)`);
      }
    });
  }

  return {
    name,
    start: () => launch(),
    stop: () => new Promise((resolve, reject) => {
      stopped = true;
      try {
        stopFn.async((err, code) => {
          if (err) return reject(err);
          resolve(code);
        });
      } catch (error) {
        resolve(-1);
      }
    })
  };
}

// ======================== xray 子进程管理 ========================
// 与 cloudflared(koffi进程内加载)不同，xray 作为 Node 的子进程启动:
// - 配置解析失败/崩溃只会导致这个子进程退出，不会带崩 Node 主进程(首页、订阅接口不受影响)
// - 能通过 exit 事件感知到崩溃并自动重启，重启计数采用与 cloudflared 相同的滑动窗口逻辑
function startXray(xrayBinPath, configPath) {
  const guard = createRestartGuard(5, 5 * 60 * 1000);

  function spawnOnce() {
    const startedAt = Date.now();
    const child = spawn(xrayBinPath, ['run', '-c', configPath], {
      cwd: runtimeFilePath,
      stdio: ['ignore', 'pipe', 'pipe']
    });

    child.stdout.on('data', d => process.stdout.write(`[xray] ${d}`));
    child.stderr.on('data', d => process.stderr.write(`[xray] ${d}`));

    child.on('error', err => {
      console.error('xray 子进程启动失败:', err.message);
    });

    child.on('exit', (code, signal) => {
      const aliveMs = Date.now() - startedAt;
      console.error(`xray 子进程退出(code=${code}, signal=${signal}, 存活${Math.round(aliveMs / 1000)}秒)`);
      if (guard.shouldRestart(aliveMs)) {
        console.error(`xray 将在2秒后自动重启(第${guard.count}/${guard.max}次)`);
        setTimeout(spawnOnce, 2000);
      } else {
        console.error('xray 短时间内反复崩溃且重启次数已达上限，不再重启，请检查 config.json 或上面的 [xray] 日志排查原因');
        notifyFatal(`xray 反复崩溃，已停止自动重启(连续在5分钟内失败${guard.max}次)`);
      }
    });

    return child;
  }

  return spawnOnce();
}

// ======================== xray 配置生成 ========================

function generateXrayConfig(warpConfig) {
  const inbounds = [];

  // VLESS+WS inbound (for argo reverse proxy)
  // 只绑回环地址(127.0.0.1 + ::1)，不对外网监听；cloudflared 通过本机 localhost 反向连过来。
  inbounds.push({
    listen: '127.0.0.1',
    port: ARGO_PORT,
    protocol: 'vless',
    settings: { clients: [{ id: UUID }], decryption: 'none' },
    streamSettings: {
      network: 'ws',
      wsSettings: { path: '/vless-argo' }
    }
  });
  inbounds.push({
    listen: '::1',
    port: ARGO_PORT,
    protocol: 'vless',
    settings: { clients: [{ id: UUID }], decryption: 'none' },
    streamSettings: {
      network: 'ws',
      wsSettings: { path: '/vless-argo' }
    }
  });

  const outbounds = [];

  // GLOBAL_WARP 且身份可用时，把 wireguard-out 放在 outbounds[0]，
  // xray 没有显式路由规则匹配时默认走第一个 outbound，等价于"全局走WARP"；
  // 不满足条件时只保留 direct，行为与不开WARP完全一致。
  if (warpConfig) {
    outbounds.push({
      protocol: 'wireguard',
      tag: 'wireguard-out',
      settings: {
        secretKey: warpConfig.private_key,
        address: warpConfig.address_v6
          ? [`${warpConfig.address_v4}/32`, `${warpConfig.address_v6}/128`]
          : [`${warpConfig.address_v4}/32`],
        peers: [{
          publicKey: warpConfig.public_key,
          endpoint: `${warpConfig.endpoint_host}:${warpConfig.endpoint_port}`
        }],
        reserved: warpConfig.reserved,
        mtu: 1280
      }
    });
  }
  outbounds.push({ protocol: 'freedom', tag: 'direct' });

  return {
    log: { loglevel: 'none' },
    inbounds,
    outbounds
  };
}

// ======================== Cloudflared Payload ========================

function cloudflaredPayload() {
  if (DISABLE_ARGO === 'true' || DISABLE_ARGO === true) return null;
  if (ARGO_AUTH && ARGO_DOMAIN) {
    if (ARGO_AUTH.match(/^[A-Z0-9a-z=]{120,250}$/)) {
      return JSON.stringify({
        args: ['tunnel', '--edge-ip-version', 'auto', '--no-autoupdate', '--protocol', 'http2', 'run', '--token', ARGO_AUTH]
      });
    } else if (ARGO_AUTH.match(/TunnelSecret/)) {
      return JSON.stringify({
        args: ['tunnel', '--edge-ip-version', 'auto', '--config', path.join(FILE_PATH, 'tunnel.yml'), 'run']
      });
    }
  }
  // Quick tunnel
  return JSON.stringify({
    args: [
      'tunnel', '--edge-ip-version', 'auto', '--no-autoupdate',
      '--protocol', 'http2', '--logfile', bootLogPath,
      '--loglevel', 'info', '--url', `http://localhost:${ARGO_PORT}`
    ]
  });
}

// ======================== 隧道域名检测 ========================

function waitForQuickTunnelDomain(logPath, timeoutMs) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    try {
      if (fs.existsSync(logPath)) {
        const content = fs.readFileSync(logPath, 'utf8');
        const matches = [...content.matchAll(/https:\/\/([A-Za-z0-9.-]+\.trycloudflare\.com)/g)];
        if (matches.length > 0) {
          return matches[matches.length - 1][1];
        }
      }
    } catch (e) { /* file may not exist yet */ }
    const remaining = deadline - Date.now();
    if (remaining <= 0) break;
    const sleepMs = Math.min(1000, remaining);
    Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, sleepMs);
  }
  return null;
}

async function extractDomain() {
  if (DISABLE_ARGO === 'true' || DISABLE_ARGO === true) return null;
  if (ARGO_AUTH && ARGO_DOMAIN) {
    console.log('ARGO_DOMAIN:', ARGO_DOMAIN + '\n');
    return ARGO_DOMAIN;
  }
  // Quick tunnel
  console.log('Waiting for quick tunnel domain in log...');
  let domain = waitForQuickTunnelDomain(bootLogPath, 30000);
  if (!domain) {
    console.log('Quick tunnel domain not found, retrying...');
    try { fs.unlinkSync(bootLogPath); } catch (e) { }
    await new Promise(r => setTimeout(r, 5000));
    domain = waitForQuickTunnelDomain(bootLogPath, 30000);
  }
  if (domain) {
    console.log('ArgoDomain:', domain + '\n');
  } else {
    console.log('ArgoDomain not found');
  }
  return domain;
}

// ======================== ISP 信息 ========================

async function getMetaInfo() {
  try {
    const response1 = await axios.get('https://api.ip.sb/geoip', { headers: { 'User-Agent': 'Mozilla/5.0', timeout: 3000 } });
    if (response1.data && response1.data.country_code && response1.data.isp) {
      return `${response1.data.country_code}-${response1.data.isp}`.replace(/\s+/g, '_');
    }
  } catch (error) {
    try {
      const response2 = await axios.get('http://ip-api.com/json', { headers: { 'User-Agent': 'Mozilla/5.0', timeout: 3000 } });
      if (response2.data && response2.data.status === 'success' && response2.data.countryCode && response2.data.org) {
        return `${response2.data.countryCode}-${response2.data.org}`.replace(/\s+/g, '_');
      }
    } catch (error) { /* backup also failed */ }
  }
  return 'Unknown';
}

// ======================== 节点链接生成 ========================

async function generateLinks(argoDomain) {
  const ISP = await getMetaInfo();
  const nodeName = NAME ? `${NAME}-${ISP}` : ISP;

  await new Promise(r => setTimeout(r, 2000));

  let subTxt = '';

  // VLESS+WS (argo)
  if ((DISABLE_ARGO !== 'true' && DISABLE_ARGO !== true) && argoDomain) {
    const vlessPath = encodeURIComponent('/vless-argo?ed=2560');
    subTxt = `vless://${UUID}@${CFIP}:${CFPORT}?encryption=none&security=tls&sni=${argoDomain}&fp=chrome&type=ws&host=${argoDomain}&path=${vlessPath}#${encodeURIComponent(nodeName)}`;
  }

  // 打印绿色 base64 编码
  console.log('\x1b[32m' + Buffer.from(subTxt).toString('base64') + '\x1b[0m');
  console.log('\n\x1b[35m' + 'Logs will be deleted in 45 seconds, you can copy the above nodes' + '\x1b[0m');

  const subTxtWithNewline = subTxt ? subTxt + '\n' : subTxt;
  fs.writeFileSync(subPath, Buffer.from(subTxtWithNewline).toString('base64'));
  fs.writeFileSync(listPath, subTxtWithNewline, 'utf8');
  console.log(`${FILE_PATH}/sub.txt saved successfully`);

  return subTxtWithNewline;
}

// ======================== HTTP 服务器 ========================

function startHttpServer(subTxt) {
  const server = http.createServer((req, res) => {
    if (req.method !== 'GET') {
      res.statusCode = 405;
      res.end('Method Not Allowed');
      return;
    }
    const url = new URL(req.url, `http://localhost`);
    if (url.pathname === subscribePath) {
      res.setHeader('Content-Type', 'text/plain; charset=utf-8');
      const encodedContent = Buffer.from(subTxt).toString('base64');
      res.end(encodedContent);
    } else if (url.pathname === '/') {
        try {
            const filePath = path.join(__dirname, 'index.html');
            const data = fs.readFileSync(filePath, 'utf8');
            res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8' });
            res.end(data);
        } catch (err) {
            res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8' });
            res.end("Hello world!<br><br>You can access /{SUB_PATH}(Default: /sub) to get your nodes!");
        }
    } else {
      res.statusCode = 404;
      res.end('Not Found');
    }
  });

  server.listen(PORT, '0.0.0.0', () => {
    console.log(`HTTP server is listening on ${PORT}`);
  });

  server.on('error', err => {
    if (err.code === 'EADDRINUSE') {
      console.error(`Port ${PORT} is already in use.`);
    } else {
      console.error('HTTP server error:', err.message);
    }
  });
}

// ======================== 主流程 ========================

async function startServer() {
  // 1. 创建运行目录 + 清理文件
  if (!fs.existsSync(FILE_PATH)) {
    fs.mkdirSync(FILE_PATH);
    console.log(`${FILE_PATH} is created`);
  }
  cleanupOldFiles();

  // 2. 生成 Argo 隧道配置
  argoType();

  // 3. 下载核心程序: xray 是可执行二进制(子进程启动)，cloudflared 仍沿用 koffi 的 .so

const xrayBaseUrl = 'https://github.com/Joshuagpt/Go_Real/releases/download/v1';

const xrayBinPath =
await downloadLibrary(
    arch === 'arm64'
        ? `${xrayBaseUrl}/runtime-arm64`
        : `${xrayBaseUrl}/runtime`,
    'runtime'
);

try { 
  fs.chmodSync(xrayBinPath, 0o755); 
} catch (e) {}


let cloudflaredLib = null;

if (DISABLE_ARGO !== 'true' && DISABLE_ARGO !== true) {

    const baseUrl =
    'https://github.com/Joshuagpt/Go_Real/releases/download/v1';

    cloudflaredLib =
    await downloadLibrary(
        `${baseUrl}/helper.so`,
        'helper.so'
    );

}

  // 4. WARP 身份(仅 GLOBAL_WARP=true 时会走完整流程，否则直接返回 null)
  const warpConfig = await getOrCreateWarpIdentity(xrayBinPath);

  // 5. 生成 xray config.json
  const xrayConfig = generateXrayConfig(warpConfig);
  fs.writeFileSync(xrayConfigPath, JSON.stringify(xrayConfig, null, 2));

  // 6. 启动服务
  const services = [];

  // cloudflared(仍是 koffi 进程内加载,未改动)
  let cloudflaredService = null;
  if (cloudflaredLib) {
    const cfPayload = cloudflaredPayload();
    if (cfPayload) {
      cloudflaredService = createService('cloudflared', cloudflaredLib, 'StartCloudflared', 'StopCloudflared', cfPayload, { autoRestart: true, maxRestarts: 5, stableMs: 5 * 60 * 1000 });
      services.push(cloudflaredService);
    }
  }

  // 信号监听:xray是子进程,SIGINT/SIGTERM传给Node时,子进程默认也会一并收到并退出,这里只需额外停koffi那部分
  let xrayChild = null;
  async function stopAll() {
    for (let i = services.length - 1; i >= 0; i--) {
      try { await services[i].stop(); } catch (e) { }
    }
    try { if (xrayChild) xrayChild.kill(); } catch (e) { }
    process.exit(0);
  }
  process.on('SIGINT', stopAll);
  process.on('SIGTERM', stopAll);

  services.forEach(service => service.start());
  xrayChild = startXray(xrayBinPath, xrayConfigPath);
  await new Promise(r => setTimeout(r, 1000));
  console.log('xray is running');

  if (cloudflaredService) {
     console.log('cloudflared is running');
  }

  // 7. 等待并检测隧道域名
  await new Promise(r => setTimeout(r, 5000));
  const argoDomain = await extractDomain();

  // 8. 生成节点链接
  const subTxt = await generateLinks(argoDomain);

  // 9. 启动 HTTP 服务器
  startHttpServer(subTxt);

  setTimeout(() => {
    cleanupFiles({ keepSub: true });
    clearConsole();
    console.log('App is running');
  }, 45000);
}

startServer();
setInterval(() => {}, 1000);
JSEOF
}

install_service () {
    purple "正在安装中,请稍等......"
    devil www del ${USERNAME}.${CURRENT_DOMAIN} > /dev/null 2>&1
    rm -rf $HOME/domains/${USERNAME}.${CURRENT_DOMAIN} > /dev/null 2>&1
    devil www add ${USERNAME}.${CURRENT_DOMAIN} nodejs /usr/local/bin/node24 > /dev/null 2>&1
    [ -d "$WORKDIR" ] || mkdir -p "$WORKDIR"
    # devil 在 add 时会自动在 public/ 下放一个默认占位 index.html；
    # Passenger 对该目录下的静态文件优先级高于应用本身，不清掉的话根路径请求
    # 永远会被这个占位页拦截，走不到 Node app.js
    rm -f "${WORKDIR}/public/index.html" > /dev/null 2>&1
    write_app_js "${WORKDIR}/app.js"
    cat > "${WORKDIR}/index.html" <<'HTMLEOF'
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>Willowmere Bird Conservancy</title>
<style>
  :root {
    --ink: #2f3226;
    --paper: #f6f4ee;
    --line: #d8d3c4;
    --moss: #4c5c3f;
    --rust: #8a5a3b;
    --muted: #6b6558;
  }
  * { box-sizing: border-box; }
  body {
    margin: 0;
    background: var(--paper);
    color: var(--ink);
    font-family: Georgia, 'Times New Roman', serif;
    font-size: 16px;
    line-height: 1.65;
  }
  a { color: var(--moss); }
  a:hover { color: var(--rust); }
  .topbar {
    background: var(--ink);
    color: var(--paper);
    font-family: Arial, Helvetica, sans-serif;
    font-size: 0.8rem;
    padding: 0.4rem 1rem;
    text-align: center;
    letter-spacing: 0.02em;
  }
  header.masthead {
    border-bottom: 3px double var(--ink);
    padding: 2rem 1rem 1.4rem;
    text-align: center;
  }
  header.masthead h1 {
    margin: 0;
    font-size: 2.1rem;
    font-weight: normal;
    letter-spacing: 0.03em;
  }
  header.masthead p.tagline {
    margin: 0.4rem 0 0;
    color: var(--muted);
    font-style: italic;
    font-size: 0.95rem;
  }
  nav.main {
    background: #ece8dc;
    border-bottom: 1px solid var(--line);
    font-family: Arial, Helvetica, sans-serif;
    font-size: 0.85rem;
  }
  nav.main ul {
    list-style: none;
    display: flex;
    flex-wrap: wrap;
    justify-content: center;
    gap: 1.6rem;
    margin: 0;
    padding: 0.7rem 1rem;
  }
  nav.main a {
    text-decoration: none;
    color: var(--ink);
    text-transform: uppercase;
    letter-spacing: 0.06em;
  }
  main {
    max-width: 760px;
    margin: 0 auto;
    padding: 2.2rem 1.4rem 3rem;
  }
  section { margin-bottom: 2.6rem; }
  h2 {
    font-size: 1.35rem;
    font-weight: normal;
    border-bottom: 1px solid var(--line);
    padding-bottom: 0.35rem;
    margin: 0 0 1rem;
  }
  h3 {
    font-size: 1.05rem;
    font-weight: bold;
    margin: 1.2rem 0 0.3rem;
    color: var(--rust);
  }
  p { margin: 0 0 0.9rem; }
  .lede {
    font-size: 1.05rem;
    color: var(--ink);
  }
  .callout {
    background: #ece8dc;
    border-left: 3px solid var(--moss);
    padding: 0.8rem 1rem;
    font-size: 0.92rem;
    color: var(--muted);
  }
  ul.plain, ol.plain {
    padding-left: 1.3rem;
    margin: 0 0 1rem;
  }
  ul.plain li, ol.plain li {
    margin-bottom: 0.4rem;
  }
  table.species {
    width: 100%;
    border-collapse: collapse;
    font-size: 0.9rem;
    margin: 0.6rem 0 1rem;
  }
  table.species th, table.species td {
    border: 1px solid var(--line);
    padding: 0.45rem 0.6rem;
    text-align: left;
    vertical-align: top;
  }
  table.species th {
    background: #ece8dc;
    font-weight: normal;
    font-family: Arial, Helvetica, sans-serif;
    font-size: 0.78rem;
    text-transform: uppercase;
    letter-spacing: 0.04em;
  }
  .notes-entry {
    border-top: 1px solid var(--line);
    padding-top: 1rem;
    margin-top: 1rem;
  }
  .notes-entry:first-child { border-top: none; padding-top: 0; margin-top: 0; }
  .notes-entry .date {
    font-family: Arial, Helvetica, sans-serif;
    font-size: 0.75rem;
    color: var(--muted);
    text-transform: uppercase;
    letter-spacing: 0.05em;
    margin-bottom: 0.25rem;
  }
  footer {
    border-top: 3px double var(--ink);
    padding: 1.6rem 1.4rem;
    font-family: Arial, Helvetica, sans-serif;
    font-size: 0.78rem;
    color: var(--muted);
    text-align: center;
  }
  footer p { margin: 0.2rem 0; }
</style>
</head>
<body>

<div class="topbar">Volunteer-run &middot; field notes updated irregularly &middot; no tracking, no ads</div>

<header class="masthead">
  <h1>Willowmere Bird Conservancy</h1>
  <p class="tagline">Notes on habitat, migration, and the birds that pass through the valley</p>
</header>

<nav class="main">
  <ul>
    <li><a href="#about">About</a></li>
    <li><a href="#threats">Threats</a></li>
    <li><a href="#species">Species Notes</a></li>
    <li><a href="#help">Get Involved</a></li>
    <li><a href="#notes">Field Notes</a></li>
  </ul>
</nav>

<main>

  <section id="about">
    <p class="lede">Willowmere is a small, volunteer-run effort to document and protect the birds that breed, winter,
    or pass through the Willowmere valley and the wetlands along its lower reach. We keep counts, restore small
    patches of habitat, and write up what we see so that the record outlasts any one of us.</p>
    <p>We are not a large organisation and we do not claim to be. Most of what appears on this page comes from
    volunteers walking the same transects year after year, comparing notes, and slowly building a picture of how
    the valley's bird life is changing. If you are looking for a national body with paid staff and a press office,
    this is not that. If you are looking for a place to read plain notes about birds and the pressures on them,
    you are in the right place.</p>
  </section>

  <section id="threats">
    <h2>Why bird populations are declining</h2>
    <p>Across most of the temperate world, long-term counts point the same direction: fewer birds, in fewer places,
    than a few decades ago. The causes are rarely a single event. More often it is a slow accumulation of smaller
    pressures, each survivable on its own, that together tip a population from stable to declining.</p>

    <h3>Habitat loss and fragmentation</h3>
    <p>Wetland drainage, hedgerow removal, and the conversion of mixed farmland into single-crop fields all reduce
    the number of places a bird can nest, feed, or shelter from weather. Fragmentation matters as much as outright
    loss: a woodland cut into small isolated blocks can support far fewer breeding pairs than the same area left
    whole, because edge habitat exposes nests to more predators and because birds that need interior forest
    conditions simply have nowhere left to go.</p>

    <h3>Collisions and everyday hazards</h3>
    <p>Windows are a significant and mostly invisible cause of death for birds moving through towns and cities,
    especially during migration when tired birds travel at night and are drawn off course by artificial light.
    Roads, powerlines, and outdoor domestic cats each add to the toll in ways that rarely make the news but add up
    over a breeding season.</p>

    <h3>Pesticides and food supply</h3>
    <p>Many farmland and garden birds feed insects to their chicks even if the adults eat seed the rest of the
    year. Where insect abundance falls, sharply, nesting success falls with it, even in habitat that otherwise
    looks intact. This is one reason a hedgerow full of green leaves can still be a poor place to raise a brood.</p>

    <h3>A shifting climate</h3>
    <p>Migratory birds time their journeys to arrive when food is at its peak. As spring arrives earlier in many
    regions, the timing between migration, breeding, and the seasonal insect flush has in some cases pulled apart,
    so that chicks hatch after the best feeding window has already passed. Range shifts are also underway, with
    some species moving north or upslope as conditions change, which can put them into competition with birds
    already living there.</p>

    <div class="callout">None of this is offered as a reason for despair. Populations that are given room, time,
    and a reduction in the sharpest pressures do recover, sometimes faster than expected. The purpose of a record
    like this one is to notice the change early enough that something can still be done about it locally.</div>
  </section>

  <section id="species">
    <h2>Species we watch closely</h2>
    <p>The valley sees well over a hundred species across the year. The table below is not exhaustive; it lists
    a handful that volunteers pay particular attention to, either because the valley holds a meaningful share of
    a declining population, or because the species is a useful early indicator of habitat condition.</p>
    <table class="species">
      <tr><th>Species</th><th>Status locally</th><th>Why we watch it</th></tr>
      <tr><td>Common Cuckoo</td><td>Declining</td><td>Depends on host nests and caterpillar abundance; an early
      warning for insect decline.</td></tr>
      <tr><td>Eurasian Curlew</td><td>Declining</td><td>Ground-nesting wader, highly sensitive to disturbance and
      wet-meadow drainage.</td></tr>
      <tr><td>Spotted Flycatcher</td><td>Sharp decline</td><td>Late migrant, aerial insectivore; sensitive to both
      breeding and wintering habitat.</td></tr>
      <tr><td>Willow Tit</td><td>Local decline</td><td>Needs standing dead wood for nest excavation; a marker of
      unmanaged, structurally messy woodland.</td></tr>
      <tr><td>Sand Martin</td><td>Variable</td><td>Colonial nester in river banks; numbers swing with bank erosion
      and winter conditions in the Sahel.</td></tr>
      <tr><td>Grey Wagtail</td><td>Stable</td><td>Good indicator of clean, fast-flowing water and healthy stream
      invertebrate life.</td></tr>
    </table>
    <p>Counts for each of these are logged on standard transect walks, usually early morning, at roughly the same
    dates each year so that the numbers can be compared honestly across seasons.</p>
  </section>

  <section id="help">
    <h2>How to help, wherever you are</h2>
    <p>Most of what keeps a bird population healthy has very little to do with money and a great deal to do with
    ordinary decisions made by ordinary people living near where the birds live.</p>
    <ul class="plain">
      <li><strong>Keep some mess.</strong> A corner of long grass, a pile of brush, a dead branch left standing –
      these untidy features are often more valuable to birds than a manicured equivalent.</li>
      <li><strong>Reduce window strikes.</strong> Breaking up reflections with film, decals, or external screens
      on the worst-offending panes prevents a surprising share of collision deaths, particularly during migration.</li>
      <li><strong>Keep cats indoors, or supervised, during the breeding season.</strong> Even well-fed cats hunt,
      and fledglings on the ground are especially vulnerable in the weeks after leaving the nest.</li>
      <li><strong>Plant for insects, not just for flowers.</strong> Native plant species support far more of the
      insect life that nestlings actually need than ornamental exotics do.</li>
      <li><strong>Take part in a count.</strong> Long-running citizen science projects rely entirely on volunteers
      walking the same route year after year. A single observer with a notebook, repeated reliably, is worth more
      than a single expert visit.</li>
      <li><strong>Report what you see, accurately.</strong> Under-recording common species is as damaging to the
      long-term picture as missing a rarity; consistent records of ordinary birds are what make trends visible.</li>
    </ul>
  </section>

  <section id="notes">
    <h2>Field notes</h2>

    <div class="notes-entry">
      <div class="date">Late spring</div>
      <p>Curlew back on the lower meadow for a fourth consecutive year, though the pair seems to be nesting later
      than the early records suggest was once typical. Water levels held up better than last year, which may be
      the difference.</p>
    </div>

    <div class="notes-entry">
      <div class="date">Mid spring</div>
      <p>First Spotted Flycatcher of the year, later than the ten-year average by almost a week. Whether that
      reflects conditions on the wintering grounds or simply a slow spring further south is not something a single
      sighting can answer, but it is worth noting all the same.</p>
    </div>

    <div class="notes-entry">
      <div class="date">Early spring</div>
      <p>Sand Martins prospecting the eroded bank near the old mill again. Numbers down on the peak years but
      steady compared with last season. Left the bank undisturbed rather than clearing the fallen willow in
      front of it, on the theory that a little cover does the colony no harm.</p>
    </div>

    <div class="notes-entry">
      <div class="date">Winter</div>
      <p>Quiet count this month, mostly resident finches and a small mixed flock working the alders along the
      stream. Nothing unusual, which in a record like this is itself a small kind of good news.</p>
    </div>
  </section>

</main>

<footer>
  <p>Willowmere Bird Conservancy &middot; an informal, volunteer-maintained record</p>
  <p>Counts and notes are kept for their own sake and shared here in case they are useful to someone else.</p>
</footer>

</body>
</html>
HTMLEOF
    cat > ${WORKDIR}/.env <<EOF
UUID=${UUID}
SUB_PATH=${SUB_PATH}
ARGO_PORT=${ARGO_PORT}
${ARGO_DOMAIN:+ARGO_DOMAIN=$ARGO_DOMAIN}
${ARGO_AUTH:+ARGO_AUTH=$([[ -z "$ARGO_AUTH" ]] && echo "" || ([[ "$ARGO_AUTH" =~ ^\{.* ]] && echo "'$ARGO_AUTH'" || echo "$ARGO_AUTH"))}
GLOBAL_WARP=${GLOBAL_WARP:-false}
${TG_BOT_TOKEN:+TG_BOT_TOKEN=$TG_BOT_TOKEN}
${TG_CHAT_ID:+TG_CHAT_ID=$TG_CHAT_ID}
EOF

  ln -fs /usr/local/bin/node24 ~/bin/node > /dev/null 2>&1
  ln -fs /usr/local/bin/npm24 ~/bin/npm > /dev/null 2>&1
  mkdir -p ~/.npm-global
  npm config set prefix '~/.npm-global'
  echo 'export PATH=~/.npm-global/bin:~/bin:$PATH' >> $HOME/.bash_profile && source $HOME/.bash_profile
  rm -rf $HOME/.npmrc > /dev/null 2>&1
  cd ${WORKDIR} && npm install dotenv axios koffi --silent > /dev/null 2>&1
  devil www restart ${USERNAME}.${CURRENT_DOMAIN} > /dev/null 2>&1
  # devil www restart 会重新生成 public/ 下的默认占位 index.html，覆盖掉我们之前删的那次；
  # 这里再清一次，确保根路径请求最终落到 app.js 而不是被这个占位页拦截
  rm -f "${WORKDIR}/public/index.html" > /dev/null 2>&1

  yellow "服务启动中，首次启动需要下载运行库，请耐心等待...."
  started=false
  for i in $(seq 1 15); do
    sleep 3
    # devil 每次 restart 都可能重新放回占位页，起服务的这段时间里持续清理，
    # 避免探测阶段命中占位页而不是真实的 app.js 响应
    rm -f "${WORKDIR}/public/index.html" > /dev/null 2>&1
    code=$(curl -o /dev/null -m 3 -s -w "%{http_code}" https://${USERNAME}.${CURRENT_DOMAIN})
    if [[ "$code" == "200" ]]; then
      started=true
      break
    fi
  done

  if $started; then
    green "服务已启动成功,请先访问 https://${USERNAME}.${CURRENT_DOMAIN}  启动服务，过20秒再访问订阅获取节点"
  else
    yellow "首页探测暂未返回200(可能仍在启动或域名解析较慢)，但这不代表节点一定不可用，请稍后手动访问 https://${USERNAME}.${CURRENT_DOMAIN} 或直接尝试订阅链接确认"
  fi

  TOKEN=$(sed -n 's/^SUB_PATH=\(.*\)/\1/p' $HOME/domains/${USERNAME}.${CURRENT_DOMAIN}/public_nodejs/.env)
  green "\n订阅链接: https://${USERNAME}.${CURRENT_DOMAIN}/${TOKEN}\n节点订阅链接适用于V2rayN/Nekoray/ShadowRocket/karing/Loon/sterisand 等\n"

  setup_keepalive_cron
}

quick_command() {
  COMMAND="00"
  SCRIPT_PATH="$HOME/bin/$COMMAND"
  mkdir -p "$HOME/bin"
  set +H
  printf '#!/bin/bash\n' > "$SCRIPT_PATH"
  echo "bash <(curl -Ls https://raw.githubusercontent.com/Joshuagpt/Go_Real/main/servct.sh)" >> "$SCRIPT_PATH"
  chmod +x "$SCRIPT_PATH"
  if [[ ":$PATH:" != *":$HOME/bin:"* ]]; then
      echo 'export PATH="$HOME/bin:$PATH"' >> "$HOME/.bashrc" 2>/dev/null
      source "$HOME/.bashrc"
  fi
  green "快捷指令00创建成功,下次运行输入00快速进入菜单\n"
}

show_nodes(){
cat ${WORKDIR}/.npm/sub.txt 2>/dev/null
TOKEN=$(sed -n 's/^SUB_PATH=\(.*\)/\1/p' $HOME/domains/${USERNAME}.${CURRENT_DOMAIN}/public_nodejs/.env)
yellow "\n订阅链接: https://${USERNAME}.${CURRENT_DOMAIN}/${TOKEN}\n节点订阅链接适用于V2rayN/Nekoray/ShadowRocket/karing/Loon/sterisand 等\n"
}

menu() {
  clear
  echo ""
  purple "=== Serv00|Ct8|HostUNO VLESS+Argo 安装脚本 ===\n"
  green "1. 安装"
  echo  "==============="
  red "2. 卸载"
  echo  "==============="
  green "3. 查看节点信息"
  echo  "==============="
  yellow "4. 初始化系统"
  echo  "==============="
  red "0. 退出脚本"
  echo "==========="
  reading "请输入选择(0-4): " choice
  echo ""
  case "${choice}" in
      1) install_vless;;
      2) uninstall_vless;;
      3) show_nodes ;;
      4) reset_system ;;
      0) exit 0 ;;
      *) red "无效的选项，请输入 0 到 4" ;;
  esac
}
menu
