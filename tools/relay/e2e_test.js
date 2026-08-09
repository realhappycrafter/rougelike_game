// 端到端协议测试（零依赖）：用两个原生 WS 客户端模拟 Godot 的 host / guest，
// 走真实 relay，验证完整联机协议：welcome(分配 pid) -> join 广播 -> input 广播给 host
// -> host 回 state 快照广播给 guest。全部通过则打印 E2E_PASS。
'use strict';
const http = require('http');
const crypto = require('crypto');

const PORT = parseInt(process.argv[2] || '8080', 10);
const ROOM = 'e2e_' + Date.now();

function wsConnect(url, onMessage, onOpen) {
  const key = crypto.randomBytes(16).toString('base64');
  const req = http.request(url.replace('ws://', 'http://'), {
    headers: {
      'Connection': 'Upgrade',
      'Upgrade': 'websocket',
      'Sec-WebSocket-Key': key,
      'Sec-WebSocket-Version': '13'
    }
  });
  let buf = Buffer.alloc(0);
  let handshook = false;
  req.on('upgrade', (res, socket) => {
    handshook = true;
    socket.on('data', (chunk) => {
      buf = Buffer.concat([buf, chunk]);
      // 解析文本帧
      while (buf.length >= 2) {
        const b0 = buf[0], b1 = buf[1];
        const opcode = b0 & 0x0f;
        let len = b1 & 0x7f;
        let off = 2;
        if (len === 126) { if (buf.length < 4) return; len = buf.readUInt16BE(2); off = 4; }
        else if (len === 127) { if (buf.length < 10) return; len = Number(buf.readBigUInt64BE(2)); off = 10; }
        if (buf.length < off + len) return;
        const payload = buf.subarray(off, off + len);
        buf = buf.subarray(off + len);
        if (opcode === 0x1) {
          try { onMessage(JSON.parse(payload.toString('utf8'))); } catch (e) {}
        }
      }
    });
    onOpen(socket);
  });
  req.end();
  return req;
}

function send(socket, obj) {
  const data = Buffer.from(JSON.stringify(obj), 'utf8');
  const len = data.length;
  let header;
  if (len < 126) header = Buffer.from([0x81, len]);
  else { header = Buffer.alloc(4); header[0] = 0x81; header[1] = 126; header.writeUInt16BE(len, 2); }
  socket.write(Buffer.concat([header, data]));
}

let hostPid = -1, guestPid = -1;
let hostGotInput = false, guestGotState = false;
let guestSocket = null, hostSocket = null;

// 第二个参数可指定中继主机名/IP，用于验证局域网路径（如 192.168.0.107）而非仅回环。
const RELAY_HOST = process.argv[3] || 'localhost';
const base = 'ws://' + RELAY_HOST + ':' + PORT;

// Host 先连
wsConnect(base + '?room=' + ROOM, (msg) => {
  if (msg.t === 'welcome') { hostPid = msg.pid; send(hostSocket, { t: 'join', pid: hostPid, room: ROOM, host: true }); }
  else if (msg.t === 'input') {
    hostGotInput = true;
    // host 收到客机输入后，回一个状态快照（模拟 _host_broadcast）
    send(hostSocket, {
      t: 'state',
      rt: 1.0, kills: 3,
      players: [
        { pid: hostPid, x: 0, y: 0, hp: 100, mhp: 100, lv: 1, wp: [{ id: 'knife', level: 1 }], c: [0.45,0.8,1.0], down: 0 },
        { pid: guestPid, x: 50, y: 0, hp: 80, mhp: 100, lv: 1, wp: [{ id: 'knife', level: 1 }], c: [1.0,0.5,0.4], down: 0 }
      ],
      enemies: [{ e: 'imp', x: 100, y: 100, hp: 20, m: 20, s: 14, c: [0.8,0.2,0.2], b: 0, el: 0, f: 0, cr: 0 }]
    });
  }
}, (sock) => { hostSocket = sock; launchGuest(); });

function launchGuest() {
  wsConnect(base + '?room=' + ROOM, (msg) => {
    if (msg.t === 'welcome') { guestPid = msg.pid; send(guestSocket, { t: 'join', pid: guestPid, room: ROOM, host: false }); }
    else if (msg.t === 'state') {
      guestGotState = true;
      finish();
    }
  }, (sock) => {
    guestSocket = sock;
    // 客机开始发输入
    const iv = setInterval(() => {
      if (guestSocket) send(guestSocket, { t: 'input', pid: guestPid, mx: 1, my: 0, ax: 1, ay: 0 });
    }, 50);
    setTimeout(() => clearInterval(iv), 400);
  });
}

function finish() {
  if (hostGotInput && guestGotState) {
    console.log('E2E_PASS  hostPid=%d guestPid=%d', hostPid, guestPid);
    process.exit(0);
  } else {
    console.log('E2E_FAIL  hostGotInput=%s guestGotState=%s', hostGotInput, guestGotState);
    process.exit(1);
  }
}

setTimeout(() => {
  console.log('E2E_TIMEOUT  hostGotInput=%s guestGotState=%s', hostGotInput, guestGotState);
  process.exit(1);
}, 5000);
