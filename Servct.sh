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

# 代理服务只需要一个本地 TCP 端口给 Relay 隧道用，不需要额外的 UDP 端口
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
purple "本机监听使用的tcp端口为: $tcp_port"
export RELAY_PORT=$tcp_port
}

install_px() {
bash -c 'ps aux | grep $(whoami) | grep -v "sshd\|bash\|grep" | awk "{print \$2}" | xargs -r kill -9 >/dev/null 2>&1' >/dev/null 2>&1
echo -e "${yellow}本脚本仅安装单协议代理服务${re}"
reading "\n确定继续安装吗？(直接回车即确认安装)【y/n】: " choice
  case "${choice:-y}" in
    [Yy]|"")
    	clear
        check_port
        relay_configure
        warp_configure
        monitor_configure
        install_service
      ;;
    [Nn]) exit 0 ;;
    *) red "无效的选择，请输入y或n" && menu ;;
  esac
}

uninstall_px() {
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

relay_configure() {
  reading "是否需要使用固定relay隧道？(直接回车将使用临时隧道)【y/n】: " relay_choice
  [[ -z $relay_choice ]] && return
  [[ "$relay_choice" != "y" && "$relay_choice" != "Y" && "$relay_choice" != "n" && "$relay_choice" != "N" ]] && { red "无效的选择, 请输入y或n"; return; }
  if [[ "$relay_choice" == "y" || "$relay_choice" == "Y" ]]; then
      reading "请输入relay固定隧道域名: " RELAY_DOMAIN
      green "你的relay固定隧道域名为: $RELAY_DOMAIN"
      reading "请输入relay固定隧道密钥（Json或Token）: " RELAY_AUTH
      green "你的relay固定隧道密钥为: $RELAY_AUTH"
  else
      green "RELAY隧道变量未设置，将使用临时隧道"
      return
  fi

  if [[ $RELAY_AUTH =~ TunnelSecret ]]; then
    echo $RELAY_AUTH > tunnel.json
    cat > tunnel.yml << EOF
tunnel: $(cut -d\" -f12 <<< "$RELAY_AUTH")
credentials-file: tunnel.json
protocol: http2

ingress:
  - hostname: $RELAY_DOMAIN
    service: http://localhost:$RELAY_PORT
    originRequest:
      noTLSVerify: true
  - service: http_status:404
EOF
  else
    yellow "\n当前使用的是token,请在cloudflare里设置隧道端口为${purple}${RELAY_PORT}${re}"
  fi
}

warp_configure() {
  reading "是否启用全局WARP出站？(直接回车默认不启用)【y/n】: " warp_choice
  if [[ "$warp_choice" == "y" || "$warp_choice" == "Y" ]]; then
    export GLOBAL_WARP=true
    green "已启用全局WARP出站(基于engine wireguard outbound;若UDP出站不可用或注册失败会自动降级为direct)"
  else
    export GLOBAL_WARP=false
    green "未启用WARP,出站全部走direct"
  fi
}

monitor_configure() {
  reading "是否启用Telegram健康告警？(engine/cloudflared多次重启仍失败、或服务长时间无法访问时会推送通知；直接回车默认不启用)【y/n】: " tg_choice
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
  local cron_tag="# px_keepalive"
  local monitor_script="$HOME/bin/px_monitor.sh"
  mkdir -p "$HOME/bin"

  # 独立的探测脚本: 除了原有的"访问自身域名保活"，
  # 额外做连续失败计数;达到阈值(3次≈30分钟)时通过Telegram告警一次，
  # 恢复后再发一条恢复通知，避免刷屏。TG_BOT_TOKEN/TG_CHAT_ID留空则静默跳过通知。
  cat > "$monitor_script" <<MONEOF
#!/bin/bash
URL="https://${USERNAME}.${CURRENT_DOMAIN}"
ENV_FILE="${WORKDIR}/.env"
STATE_FILE="\$HOME/.px_health_state"
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
  local cron_tag="# px_keepalive"
  crontab -l 2>/dev/null | grep -vF "${cron_tag}" | crontab -
  rm -f "$HOME/bin/px_monitor.sh" "$HOME/.px_health_state" 2>/dev/null
}

write_engine_js() {
  cat > "$1" <<'ENGEOF'
#!/usr/bin/env node
// 独立子进程: 纯 JS VLESS+WS 引擎。之所以不直接跑在 app.js 里，是因为 Phusion Passenger
// 的 Node "auto-install" 机制会把进程里第一次调用 .listen() 的 http.Server 自动接管当成
// 自己的请求入口，同一个进程里不允许出现第二次 .listen()。engine 独立成子进程后，它的
// .listen() 调用发生在另一个 OS 进程里，Passenger 完全看不到，不会冲突；副作用是内存
// 核算也更干净，能单独用 --max-old-space-size 卡住这个进程自己的堆。

const http = require('http');
const net = require('net');
const { WebSocketServer } = require('ws');

const UUID = process.env.UUID || '';
const RELAY_PORT = Number(process.env.RELAY_PORT) || 8001;
const WS_PATH = process.env.WS_PATH || '/data-sync';

// 把自己的 PID 写到当前目录(cwd 是 runtimeFilePath)下的 engine.pid，
// 给 app.js 下次启动时用来清理上一轮可能残留的孤儿进程(见 app.js 里 startEngine 的说明)
const fs = require('fs');
const pidFilePath = 'engine.pid';
try { fs.writeFileSync(pidFilePath, String(process.pid)); } catch (e) { /* ignore */ }
function cleanupPidFile() {
  try {
    if (fs.readFileSync(pidFilePath, 'utf8').trim() === String(process.pid)) {
      fs.unlinkSync(pidFilePath);
    }
  } catch (e) { /* ignore */ }
}

const uuidBytes = Buffer.from(UUID.replace(/-/g, ''), 'hex');
if (uuidBytes.length !== 16) {
  console.error('[engine] UUID 格式不对，无法启动');
  process.exit(1);
}

// ---- VLESS 头部解析 ----
function parseVlessHeader(buffer, expectedUUIDBytes) {
  if (buffer.length < 24) {
    return { hasError: true, message: 'VLESS 头部太短' };
  }
  const version = buffer[0];
  const uuidBytesIn = buffer.subarray(1, 17);
  if (!uuidBytesIn.equals(expectedUUIDBytes)) {
    return { hasError: true, message: 'UUID 校验失败' };
  }
  const optLen = buffer[17];
  let offset = 18 + optLen;
  const command = buffer[offset];
  offset += 1;
  if (command !== 1 && command !== 2) {
    return { hasError: true, message: `不支持的 command: ${command}` };
  }
  const isUDP = command === 2;
  const port = buffer.readUInt16BE(offset);
  offset += 2;
  const addressType = buffer[offset];
  offset += 1;
  let addressRemote = '';
  if (addressType === 1) {
    addressRemote = buffer.subarray(offset, offset + 4).join('.');
    offset += 4;
  } else if (addressType === 2) {
    const domainLen = buffer[offset];
    offset += 1;
    addressRemote = buffer.subarray(offset, offset + domainLen).toString('utf8');
    offset += domainLen;
  } else if (addressType === 3) {
    const parts = [];
    for (let i = 0; i < 8; i++) {
      parts.push(buffer.readUInt16BE(offset).toString(16));
      offset += 2;
    }
    addressRemote = parts.join(':');
  } else {
    return { hasError: true, message: `不支持的地址类型: ${addressType}` };
  }
  return {
    hasError: false, addressRemote, addressType, portRemote: port,
    isUDP, vlessVersion: version, rawDataIndex: offset
  };
}

function extractEarlyData(secWsProtocolHeader) {
  if (!secWsProtocolHeader) return null;
  try {
    let b64 = secWsProtocolHeader.replace(/-/g, '+').replace(/_/g, '/');
    while (b64.length % 4 !== 0) b64 += '=';
    return Buffer.from(b64, 'base64');
  } catch (e) {
    return null;
  }
}

function handleDnsOverTcp(ws, vlessRespHeader, rawClientData) {
  let headerSent = false;
  let offset = 0;
  const buf = rawClientData;
  function sendNext() {
    if (offset >= buf.length) return;
    const len = buf.readUInt16BE(offset);
    const payload = buf.subarray(offset + 2, offset + 2 + len);
    offset += 2 + len;
    const sock = net.connect(53, '8.8.8.8', () => {
      const lenPrefix = Buffer.alloc(2);
      lenPrefix.writeUInt16BE(payload.length);
      sock.write(Buffer.concat([lenPrefix, payload]));
    });
    sock.once('data', (respWithLen) => {
      const dnsAnswer = respWithLen.subarray(2);
      const frame = Buffer.alloc(2);
      frame.writeUInt16BE(dnsAnswer.length);
      const out = headerSent
        ? Buffer.concat([frame, dnsAnswer])
        : Buffer.concat([vlessRespHeader, frame, dnsAnswer]);
      headerSent = true;
      if (ws.readyState === ws.OPEN) ws.send(out);
      sock.destroy();
      sendNext();
    });
    sock.once('error', () => { sock.destroy(); sendNext(); });
    sock.setTimeout(5000, () => sock.destroy());
  }
  sendNext();
}

function handleTcpOutbound(ws, vlessRespHeader, addressRemote, portRemote, rawClientData) {
  let headerSent = false;
  const remoteSocket = net.connect(portRemote, addressRemote);
  remoteSocket.setNoDelay(true);
  remoteSocket.on('connect', () => {
    if (rawClientData && rawClientData.length > 0) remoteSocket.write(rawClientData);
  });
  remoteSocket.on('data', (chunk) => {
    if (ws.readyState !== ws.OPEN) return;
    const out = headerSent ? chunk : Buffer.concat([vlessRespHeader, chunk]);
    headerSent = true;
    ws.send(out, () => {});
    if (ws.bufferedAmount > 4 * 1024 * 1024) {
      remoteSocket.pause();
      const resume = setInterval(() => {
        if (ws.bufferedAmount < 1 * 1024 * 1024) {
          remoteSocket.resume();
          clearInterval(resume);
        }
      }, 50);
    }
  });
  remoteSocket.on('close', () => { try { ws.close(); } catch (e) {} });
  remoteSocket.on('error', () => { try { ws.close(); } catch (e) {} });
  ws.on('message', (data) => { if (remoteSocket.writable) remoteSocket.write(data); });
  ws.on('close', () => { try { remoteSocket.destroy(); } catch (e) {} });
  ws.on('error', () => { try { remoteSocket.destroy(); } catch (e) {} });
}

const wss = new WebSocketServer({ noServer: true });

function handleUpgrade(req, socket, head) {
  let pathname;
  try {
    pathname = new URL(req.url, 'http://localhost').pathname;
  } catch (e) {
    socket.destroy();
    return;
  }
  if (pathname !== WS_PATH) {
    socket.destroy();
    return;
  }
  wss.handleUpgrade(req, socket, head, (ws) => {
    wss.emit('connection', ws, req);
  });
}

wss.on('connection', (ws, req) => {
  ws.binaryType = 'nodebuffer';
  const earlyData = extractEarlyData(req.headers['sec-websocket-protocol']);
  let processed = false;

  function processFirstData(chunk) {
    if (processed) return;
    processed = true;
    const parsed = parseVlessHeader(chunk, uuidBytes);
    if (parsed.hasError) {
      console.error('[engine] VLESS 头部解析失败:', parsed.message);
      ws.close();
      return;
    }
    const vlessRespHeader = Buffer.from([parsed.vlessVersion, 0]);
    const rawClientData = chunk.subarray(parsed.rawDataIndex);
    if (parsed.isUDP) {
      if (parsed.portRemote !== 53) {
        console.error('[engine] 仅支持 UDP/53(DNS)，其余 UDP 目标暂不支持');
        ws.close();
        return;
      }
      handleDnsOverTcp(ws, vlessRespHeader, rawClientData);
    } else {
      handleTcpOutbound(ws, vlessRespHeader, parsed.addressRemote, parsed.portRemote, rawClientData);
    }
  }

  if (earlyData && earlyData.length > 0) processFirstData(earlyData);
  ws.once('message', (data) => {
    if (!processed) processFirstData(Buffer.isBuffer(data) ? data : Buffer.from(data));
  });
  ws.on('error', () => {});
});

const serverV4 = http.createServer((req, res) => { res.statusCode = 404; res.end(); });
serverV4.on('upgrade', handleUpgrade);
serverV4.on('error', err => console.error('[engine] IPv4监听出错:', err.message));
serverV4.listen(RELAY_PORT, '127.0.0.1', () => console.log(`[engine] listening on 127.0.0.1:${RELAY_PORT}`));

const serverV6 = http.createServer((req, res) => { res.statusCode = 404; res.end(); });
serverV6.on('upgrade', handleUpgrade);
serverV6.on('error', err => console.error('[engine] IPv6监听出错:', err.message));
serverV6.listen(RELAY_PORT, '::1', () => console.log(`[engine] listening on ::1:${RELAY_PORT}`));

process.on('SIGINT', () => { cleanupPidFile(); process.exit(0); });
process.on('SIGTERM', () => { cleanupPidFile(); process.exit(0); });
ENGEOF
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
const RELAY_DOMAIN    = process.env.RELAY_DOMAIN    || '';         // relay固定隧道域名,留空即使用临时隧道
const RELAY_AUTH      = process.env.RELAY_AUTH      || '';         // relay固定隧道token或json,留空即使用临时隧道
const RELAY_PORT      = Number(process.env.RELAY_PORT) || 8001;    // relay固定隧道端口(本地监听端口)
const CFIP           = process.env.CFIP           || 'ali.ztyawc.de'; // 优选域名或优选IP
const CFPORT         = Number(process.env.CFPORT) || 443;        // 优选域名或优选IP对应端口
const PORT           = Number(process.env.PORT)   || 3000;       // http订阅端口
const NAME           = process.env.NAME           || '';         // 节点名称
const DISABLE_RELAY   = process.env.DISABLE_RELAY   || false;      // 设置为true时禁用relay
const GLOBAL_WARP    = String(process.env.GLOBAL_WARP).toLowerCase() === 'true'; // true时全部出站走WARP，否则不启用WARP
const TG_BOT_TOKEN    = process.env.TG_BOT_TOKEN    || '';        // Telegram Bot Token,留空则不发送告警
const TG_CHAT_ID      = process.env.TG_CHAT_ID      || '';        // Telegram Chat ID,留空则不发送告警
// ==============================================================

const ROOT = process.cwd();
const runtimeFilePath = path.resolve(ROOT, FILE_PATH);
const libraryDir = runtimeFilePath;
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

// ======================== Relay 隧道配置 ========================

function relayType() {
  if (DISABLE_RELAY === 'true' || DISABLE_RELAY === true) {
    console.log("DISABLE_RELAY is set to true, disable relay tunnel");
    return;
  }
  if (!RELAY_AUTH || !RELAY_DOMAIN) {
    console.log("RELAY_DOMAIN or RELAY_AUTH variable is empty, use quick tunnel");
    return;
  }
  if (RELAY_AUTH.includes('TunnelSecret')) {
    fs.writeFileSync(path.join(FILE_PATH, 'tunnel.json'), RELAY_AUTH);
    const tunnelYaml = `
  tunnel: ${RELAY_AUTH.split('"')[11]}
  credentials-file: ${path.join(FILE_PATH, 'tunnel.json')}
  protocol: http2
  
  ingress:
    - hostname: ${RELAY_DOMAIN}
      service: http://localhost:${RELAY_PORT}
      originRequest:
        noTLSVerify: true
    - service: http_status:404
  `;
    fs.writeFileSync(path.join(FILE_PATH, 'tunnel.yml'), tunnelYaml);
  } else {
    console.log(`Using token connect to tunnel, please set ${RELAY_PORT} in cloudflare`);
  }
}

// ======================== WARP: 暂不支持 ========================
// 纯 JS 引擎目前只做直连转发(direct)，没有实现 WireGuard/wireguard 出站，
// 之前基于 xray wireguard outbound 的 WARP 相关逻辑(注册身份、UDP探测、
// engine兼容性探测等)随 engine 一起移除。GLOBAL_WARP 这个环境变量目前是 no-op。

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
// px_monitor.sh(crontab 每10分钟探测一次)负责兜底告警。
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

// ======================== engine 子进程管理 ========================
// engine 现在是独立的 node 子进程(engine.js)，原因见 engine.js 顶部注释：
// Phusion Passenger 的 auto-install 机制不允许同一个 Node 进程里出现第二次 .listen()。
// 复用跟 cloudflared 一样的滑动窗口重启逻辑；崩溃只会影响这一个子进程，不牵连 Node 主进程。
//
// 关键点: engine.js 独立于 app.js 存在，正是为了让它不受 Passenger 因 idle 回收
// app.js 主进程的影响——回收只发生在 app.js 身上，engine.js 作为脱离的子进程会
// 继续存活并处理已建立的代理连接。如果这里无脑"发现有旧 pid 就杀掉重开"，
// 就等于每次 app.js 被 Passenger 回收重启，都会连带打断所有正在用的代理连接
// (对 WoW 这类长连接游戏流量尤其致命)。所以只有确认旧进程已经不在了，才清理;
// 如果还活着，直接复用，不再新开一个。
function isPidAlive(pid) {
  try {
    process.kill(pid, 0);
    return true;
  } catch (e) {
    return false; // ESRCH: 进程不存在
  }
}

function readStaleEnginePid() {
  const pidFilePath = path.resolve(runtimeFilePath, 'engine.pid');
  try {
    const pid = Number(fs.readFileSync(pidFilePath, 'utf8').trim());
    return pid || null;
  } catch (e) {
    return null;
  }
}

function killStaleEngine() {
  const pidFilePath = path.resolve(runtimeFilePath, 'engine.pid');
  try {
    const oldPid = Number(fs.readFileSync(pidFilePath, 'utf8').trim());
    if (oldPid && oldPid !== process.pid) {
      process.kill(oldPid, 'SIGKILL');
      console.log(`engine: 已清理上一轮残留的孤儿进程(PID ${oldPid})`);
    }
  } catch (e) {
    // 文件不存在，或者进程已经不在了(ESRCH)，都属于正常情况，忽略
  }
  try { fs.unlinkSync(pidFilePath); } catch (e) { /* ignore */ }
}

function startEngine(enginePath) {
  const guard = createRestartGuard(5, 5 * 60 * 1000);

  function spawnOnce() {
    const oldPid = readStaleEnginePid();
    if (oldPid && isPidAlive(oldPid)) {
      // 上一轮的 engine 还活着(大概率是 app.js 被 Passenger 回收重启，
      // 但这个独立子进程没有被牵连)，直接复用，不打断正在跑的连接。
      console.log(`engine: 复用仍存活的上一轮 engine 进程(PID ${oldPid})，不重新启动`);
      return null;
    }
    killStaleEngine();
    const startedAt = Date.now();
    const child = spawn(process.execPath, [enginePath], {
      cwd: runtimeFilePath,
      stdio: ['ignore', 'pipe', 'pipe'],
      env: {
        ...process.env,
        UUID,
        RELAY_PORT: String(RELAY_PORT),
        WS_PATH: '/data-sync'
      }
    });

    child.stdout.on('data', d => process.stdout.write(`[engine] ${d}`));
    child.stderr.on('data', d => process.stderr.write(`[engine] ${d}`));

    child.on('error', err => {
      console.error('engine 子进程启动失败:', err.message);
    });

    child.on('exit', (code, signal) => {
      const aliveMs = Date.now() - startedAt;
      console.error(`engine 子进程退出(code=${code}, signal=${signal}, 存活${Math.round(aliveMs / 1000)}秒)`);
      if (guard.shouldRestart(aliveMs)) {
        console.error(`engine 将在2秒后自动重启(第${guard.count}/${guard.max}次)`);
        setTimeout(spawnOnce, 2000);
      } else {
        console.error('engine 短时间内反复崩溃且重启次数已达上限，不再重启');
        notifyFatal(`engine 反复崩溃，已停止自动重启(连续在5分钟内失败${guard.max}次)`);
      }
    });

    return child;
  }

  return spawnOnce();
}


// ======================== Cloudflared Payload ========================

function cloudflaredPayload() {
  if (DISABLE_RELAY === 'true' || DISABLE_RELAY === true) return null;
  if (RELAY_AUTH && RELAY_DOMAIN) {
    if (RELAY_AUTH.match(/^[A-Z0-9a-z=]{120,250}$/)) {
      return JSON.stringify({
        args: ['tunnel', '--edge-ip-version', 'auto', '--no-autoupdate', '--protocol', 'http2', 'run', '--token', RELAY_AUTH]
      });
    } else if (RELAY_AUTH.match(/TunnelSecret/)) {
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
      '--loglevel', 'info', '--url', `http://localhost:${RELAY_PORT}`
    ]
  });
}

// ======================== 隧道域名检测 ========================

async function waitForQuickTunnelDomain(logPath, timeoutMs) {
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
    // 注意: 这里必须用非阻塞的 setTimeout，不能用 Atomics.wait 同步阻塞主线程——
    // 否则会连带冻结 HTTP server 和 engine 子进程的 stdout 事件循环，
    // 拖慢/拖死 Passenger 认为的"进程已就绪"判定。
    await new Promise(r => setTimeout(r, sleepMs));
  }
  return null;
}

async function extractDomain() {
  if (DISABLE_RELAY === 'true' || DISABLE_RELAY === true) return null;
  if (RELAY_AUTH && RELAY_DOMAIN) {
    console.log('RELAY_DOMAIN:', RELAY_DOMAIN + '\n');
    return RELAY_DOMAIN;
  }
  // Quick tunnel
  console.log('Waiting for quick tunnel domain in log...');
  let domain = await waitForQuickTunnelDomain(bootLogPath, 30000);
  if (!domain) {
    console.log('Quick tunnel domain not found, retrying...');
    try { fs.unlinkSync(bootLogPath); } catch (e) { }
    await new Promise(r => setTimeout(r, 5000));
    domain = await waitForQuickTunnelDomain(bootLogPath, 30000);
  }
  if (domain) {
    console.log('RelayDomain:', domain + '\n');
  } else {
    console.log('RelayDomain not found');
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

async function generateLinks(relayDomain) {
  const ISP = await getMetaInfo();
  const nodeName = NAME ? `${NAME}-${ISP}` : ISP;

  await new Promise(r => setTimeout(r, 2000));

  let subTxt = '';

  // 节点链接生成 (relay)
  if ((DISABLE_RELAY !== 'true' && DISABLE_RELAY !== true) && relayDomain) {
    const linkPath = encodeURIComponent('/data-sync?ed=2560');
    subTxt = `vless://${UUID}@${CFIP}:${CFPORT}?encryption=none&security=tls&sni=${relayDomain}&fp=chrome&type=ws&host=${relayDomain}&path=${linkPath}#${encodeURIComponent(nodeName)}`;
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

function startHttpServer(state) {
  const server = http.createServer((req, res) => {
    if (req.method !== 'GET') {
      res.statusCode = 405;
      res.end('Method Not Allowed');
      return;
    }
    const url = new URL(req.url, `http://localhost`);
    if (url.pathname === subscribePath) {
      if (!state.subTxt) {
        // 节点链接还没生成完(隧道域名探测/下载依赖等还在跑)，先给个 202
        // 而不是让 Passenger 因为端口没绑定而超时判死并反复重启进程
        res.statusCode = 202;
        res.setHeader('Content-Type', 'text/plain; charset=utf-8');
        res.end('starting, please retry shortly');
        return;
      }
      res.setHeader('Content-Type', 'text/plain; charset=utf-8');
      const encodedContent = Buffer.from(state.subTxt).toString('base64');
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
  // 0. 立刻绑定 HTTP 端口。Passenger 是靠"进程有没有把 PORT 端口监听起来"
  //    来判断应用是否就绪的，之前把 server.listen 放在下载 helper.so / 探测
  //    隧道域名(quick tunnel 最坏情况下要阻塞近 65 秒)之后，导致 Passenger
  //    在端口还没绑定时就判超时、返回500，然后在下一次请求时重新 spawn 一个
  //    全新的 app.js 进程——于是永远卡在"刚起步就被杀掉重启"的循环里。
  //    现在先监听端口占住位置，节点信息用 state.subTxt 异步补上。
  const httpState = { subTxt: '' };
  startHttpServer(httpState);

  // 1. 创建运行目录 + 清理文件
  if (!fs.existsSync(FILE_PATH)) {
    fs.mkdirSync(FILE_PATH);
    console.log(`${FILE_PATH} is created`);
  }
  cleanupOldFiles();

  // 2. 生成 Relay 隧道配置
  relayType();

  // 3. 下载核心程序: 现在只有 cloudflared 需要下载(仍沿用 koffi 的 .so)。
  //    engine 是独立子进程(engine.js)，见其文件顶部注释，原因是 Passenger 的
  //    auto-install 机制不允许同一个 Node 进程里出现第二次 .listen()。

let cloudflaredLib = null;

if (DISABLE_RELAY !== 'true' && DISABLE_RELAY !== true) {

    const baseUrl =
    'https://github.com/Joshuagpt/Go_Real/releases/download/v1';

    cloudflaredLib =
    await downloadLibrary(
        `${baseUrl}/helper.so`,
        'helper.so'
    );

}

  // 4. 启动服务
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

  let engineChild = null;
  async function stopAll() {
    for (let i = services.length - 1; i >= 0; i--) {
      try { await services[i].stop(); } catch (e) { }
    }
    try { if (engineChild) engineChild.kill(); } catch (e) { }
    process.exit(0);
  }
  process.on('SIGINT', stopAll);
  process.on('SIGTERM', stopAll);

  services.forEach(service => service.start());
  engineChild = startEngine(path.resolve(__dirname, 'engine.js'));
  await new Promise(r => setTimeout(r, 500));
  console.log('engine (pure-JS VLESS+WS, child process) is running');

  if (cloudflaredService) {
     console.log('cloudflared is running');
  }

  // 5. 等待并检测隧道域名
  await new Promise(r => setTimeout(r, 5000));
  const relayDomain = await extractDomain();

  // 6. 生成节点链接(HTTP 服务器早在第0步就已经在监听了，这里只是把内容填进去)
  httpState.subTxt = await generateLinks(relayDomain);

  setTimeout(() => {
    cleanupFiles({ keepSub: true });
    clearConsole();
    console.log('App is running');
  }, 45000);
}

process.on('uncaughtException', err => {
  console.error('未捕获的异常(uncaughtException):', err && err.stack || err);
});
process.on('unhandledRejection', err => {
  console.error('未处理的 Promise rejection(unhandledRejection):', err && err.stack || err);
});

startServer().catch(err => {
  console.error('startServer() 执行失败:', err && err.stack || err);
});
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
    write_engine_js "${WORKDIR}/engine.js"
    chmod +x "${WORKDIR}/app.js"

    cat > "${WORKDIR}/index.html" <<'HTMLEOF'
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>Project Oceanus - Marine Ecology Monitoring</title>
<style>
  :root {
    --deep-blue: #050b14;
    --water: #0a192f;
    --cyan: #64ffda;
    --text-main: #ccd6f6;
    --text-muted: #8892b0;
  }
  body {
    margin: 0;
    padding: 0;
    background-color: var(--deep-blue);
    background-image: 
      radial-gradient(circle at 15% 50%, rgba(100, 255, 218, 0.08), transparent 25%),
      radial-gradient(circle at 85% 30%, rgba(10, 25, 47, 0.8), transparent 25%);
    color: var(--text-main);
    font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
    display: flex;
    justify-content: center;
    align-items: center;
    min-height: 100vh;
    overflow: hidden;
  }
  /* Bioluminescent environmental glow */
  .orb {
    position: absolute;
    border-radius: 50%;
    filter: blur(80px);
    opacity: 0.5;
    animation: float 10s infinite alternate ease-in-out;
    z-index: 0;
  }
  .orb-1 {
    width: 300px; height: 300px;
    background: #112240;
    top: -100px; left: -100px;
  }
  .orb-2 {
    width: 400px; height: 400px;
    background: rgba(100, 255, 218, 0.04);
    bottom: -150px; right: -100px;
    animation-delay: -5s;
  }
  .container {
    position: relative;
    z-index: 1;
    width: 90%;
    max-width: 580px;
    background: rgba(10, 25, 47, 0.65);
    backdrop-filter: blur(20px);
    -webkit-backdrop-filter: blur(20px);
    border: 1px solid rgba(100, 255, 218, 0.1);
    border-radius: 16px;
    padding: 45px 40px;
    box-shadow: 0 20px 40px rgba(0,0,0,0.4);
  }
  .header {
    text-align: center;
    margin-bottom: 25px;
  }
  .logo {
    display: inline-block;
    width: 48px; height: 48px;
    border: 2px solid var(--cyan);
    border-radius: 50%;
    margin-bottom: 18px;
    position: relative;
  }
  .logo::after {
    content: '';
    position: absolute;
    top: 10px; left: 10px; right: 10px; bottom: 10px;
    background: var(--cyan);
    border-radius: 50%;
    animation: pulse 2.5s infinite ease-in-out;
  }
  h1 {
    margin: 0;
    font-weight: 600;
    font-size: 1.7rem;
    color: #e6f1ff;
    letter-spacing: 1px;
  }
  p.subtitle {
    color: var(--cyan);
    font-size: 0.85rem;
    margin-top: 8px;
    text-transform: uppercase;
    letter-spacing: 2px;
  }
  .content {
    color: var(--text-muted);
    line-height: 1.65;
    text-align: justify;
    font-size: 0.95rem;
    margin-bottom: 35px;
  }
  .stats-container {
    display: grid;
    grid-template-columns: repeat(3, 1fr);
    gap: 15px;
    margin-bottom: 35px;
  }
  .stat-box {
    background: rgba(255, 255, 255, 0.02);
    border: 1px solid rgba(255, 255, 255, 0.04);
    border-radius: 10px;
    padding: 16px 10px;
    text-align: center;
  }
  .stat-value {
    display: block;
    color: var(--text-main);
    font-size: 1.25rem;
    font-weight: bold;
    font-family: ui-monospace, SFMono-Regular, Consolas, monospace;
  }
  .stat-label {
    font-size: 0.7rem;
    color: var(--text-muted);
    text-transform: uppercase;
    margin-top: 6px;
    letter-spacing: 0.5px;
  }
  .footer {
    text-align: center;
    font-size: 0.8rem;
    color: rgba(136, 146, 176, 0.5);
    border-top: 1px solid rgba(136, 146, 176, 0.1);
    padding-top: 25px;
    line-height: 1.6;
  }
  @keyframes float {
    0% { transform: translateY(0) scale(1); }
    100% { transform: translateY(-30px) scale(1.05); }
  }
  @keyframes pulse {
    0% { transform: scale(0.9); opacity: 0.8; }
    50% { transform: scale(1.1); opacity: 0.3; }
    100% { transform: scale(0.9); opacity: 0.8; }
  }
  @media (max-width: 480px) {
    .stats-container { grid-template-columns: 1fr; }
    .container { padding: 35px 25px; }
  }
</style>
</head>
<body>
  <div class="orb orb-1"></div>
  <div class="orb orb-2"></div>
  
  <div class="container">
    <div class="header">
      <div class="logo"></div>
      <h1>Project Oceanus</h1>
      <p class="subtitle">Global Marine Ecology Initiative</p>
    </div>
    
    <div class="content">
      Dedicated to the preservation of the world's most fragile deep-sea ecosystems. Our autonomous acoustic sensor network continuously analyzes water quality, thermal currents, and microplastic concentrations across oceanic trenches, providing open-source foundational data for marine biologists worldwide.
    </div>
    
    <div class="stats-container">
      <div class="stat-box">
        <span class="stat-value" id="buoy-count">1,024</span>
        <span class="stat-label">Active Sensors</span>
      </div>
      <div class="stat-box">
        <span class="stat-value">10,984m</span>
        <span class="stat-label">Max Depth</span>
      </div>
      <div class="stat-box">
        <span class="stat-value" style="color: var(--cyan);">Syncing</span>
        <span class="stat-label">Network Status</span>
      </div>
    </div>
    
    <div class="footer">
      &copy; 2026 Project Oceanus Non-Profit Foundation.<br>
      <i>Authorized researchers: Append your institutional access token to the URL path.</i>
    </div>
  </div>

  <script>
    // Simulate minor fluctuations in sensor counts for dynamic realism
    setInterval(() => {
      const el = document.getElementById('buoy-count');
      let val = parseInt(el.innerText.replace(',', ''));
      if(Math.random() > 0.6) { 
        val += Math.floor(Math.random() * 3); 
        el.innerText = val.toLocaleString();
      }
    }, 4000);
  </script>
</body>
</html>
HTMLEOF

    cat > ${WORKDIR}/.env <<EOF
UUID=${UUID}
SUB_PATH=${SUB_PATH}
RELAY_PORT=${RELAY_PORT}
${RELAY_DOMAIN:+RELAY_DOMAIN=$RELAY_DOMAIN}
${RELAY_AUTH:+RELAY_AUTH=$([[ -z "$RELAY_AUTH" ]] && echo "" || ([[ "$RELAY_AUTH" =~ ^\{.* ]] && echo "'$RELAY_AUTH'" || echo "$RELAY_AUTH"))}
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
  cd ${WORKDIR} && npm install dotenv axios koffi ws --silent > /dev/null 2>&1
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
  purple "=== Serv00|Ct8|HostUNO 代理部署脚本 ===\n"
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
      1) install_px;;
      2) uninstall_px;;
      3) show_nodes ;;
      4) reset_system ;;
      0) exit 0 ;;
      *) red "无效的选项，请输入 0 到 4" ;;
  esac
}
menu
