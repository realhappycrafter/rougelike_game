// 零依赖 WebSocket 中继服务器 + 静态文件托管
// 用法: node server.js [port] [webRoot]
//   - 静态托管 webRoot（默认 ../../web_build，即 rougelike_game/web_build）
//   - WebSocket 连接 ?room=xxx 按房间互转文本帧（房间内其他人都能收到）
// 不依赖任何 npm 包，仅用 Node 内置 http / crypto / fs / path。
'use strict';
const http = require('http');
const crypto = require('crypto');
const fs = require('fs');
const path = require('path');

const PORT = parseInt(process.argv[2] || '8080', 10);
const WEB_ROOT = path.resolve(process.argv[3] || path.join(__dirname, '..', '..', 'web_build'));
const WS_GUID = '258EAFA5-E914-47DA-95CA-C5AB0DC85B11';

// ---------- 静态文件托管 ----------
const MIME = {
  '.html': 'text/html; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.wasm': 'application/wasm',
  '.pck': 'application/octet-stream',
  '.json': 'application/json; charset=utf-8',
  '.png': 'image/png',
  '.svg': 'image/svg+xml',
  '.ico': 'image/x-icon',
  '.css': 'text/css; charset=utf-8'
};

const server = http.createServer((req, res) => {
  let urlPath = decodeURIComponent((req.url || '/').split('?')[0]);
  if (urlPath === '/') urlPath = '/index.html';
  // 防目录穿越
  const filePath = path.normalize(path.join(WEB_ROOT, urlPath));
  if (!filePath.startsWith(WEB_ROOT)) {
    res.writeHead(403); res.end('forbidden'); return;
  }
  fs.readFile(filePath, (err, data) => {
    // 访问日志：定位"页面打不开"时，用于判断请求是否真的到达了中继。
    const ts = new Date().toTimeString().slice(0, 8);
    const from = req.socket.remoteAddress || '?';
    if (err) {
      console.log(`[${ts}] 404 ${urlPath}  <- ${from}`);
      res.writeHead(404); res.end('not found'); return;
    }
    console.log(`[${ts}] 200 ${urlPath} (${data.length}B)  <- ${from}`);
    const ext = path.extname(filePath).toLowerCase();
    res.writeHead(200, { 'Content-Type': MIME[ext] || 'application/octet-stream' });
    res.end(data);
  });
});

// ---------- WebSocket 中继（房间转发） ----------
const clients = []; // { socket, room, pid, buf }
const rooms = {};   // room -> { nextPid }

server.on('upgrade', (req, socket) => {
  const key = req.headers['sec-websocket-key'];
  if (!key) { socket.destroy(); return; }
  const accept = crypto.createHash('sha1').update(key + WS_GUID).digest('base64');
  socket.write(
    'HTTP/1.1 101 Switching Protocols\r\n' +
    'Upgrade: websocket\r\n' +
    'Connection: Upgrade\r\n' +
    'Sec-WebSocket-Accept: ' + accept + '\r\n\r\n'
  );
  const m = (req.url || '').match(/room=([^&]+)/);
  const room = m ? decodeURIComponent(m[1]) : 'default';
  // 按房间分配递增 pid（房内首个连接者 pid=0，通常是主机）
  if (!rooms[room]) rooms[room] = { nextPid: 0 };
  const pid = rooms[room].nextPid++;
  const client = { socket, room, pid, buf: Buffer.alloc(0) };
  clients.push(client);
  // 直连向该客户端发送 welcome（仅自己收到，报告本端 pid）
  socket.write(encodeFrame(0x1, Buffer.from(JSON.stringify({ t: 'welcome', pid, room }), 'utf8')));
  socket.on('data', (chunk) => onData(client, chunk));
  socket.on('close', () => removeClient(client));
  socket.on('error', () => removeClient(client));
});

function removeClient(c) {
  const i = clients.indexOf(c);
  if (i >= 0) clients.splice(i, 1);
  // 通知同房其他人有人离开（携带 pid 便于识别）
  relay(c, JSON.stringify({ t: 'peer_leave', pid: c.pid }));
}

// 把文本消息转发给同房其他客户端
function relay(from, text) {
  const frame = encodeFrame(0x1, Buffer.from(text, 'utf8'));
  for (const c of clients) {
    if (c !== from && c.room === from.room && c.socket.writable) {
      c.socket.write(frame);
    }
  }
}

// 解析 WebSocket 数据帧（处理掩码、分片、ping/pong/close）
function onData(client, chunk) {
  client.buf = Buffer.concat([client.buf, chunk]);
  while (true) {
    if (client.buf.length < 2) return;
    const b0 = client.buf[0], b1 = client.buf[1];
    const opcode = b0 & 0x0f;
    const masked = (b1 & 0x80) !== 0;
    let len = b1 & 0x7f;
    let offset = 2;
    if (len === 126) {
      if (client.buf.length < 4) return;
      len = client.buf.readUInt16BE(2); offset = 4;
    } else if (len === 127) {
      if (client.buf.length < 10) return;
      len = Number(client.buf.readBigUInt64BE(2)); offset = 10;
    }
    let maskKey = null;
    if (masked) {
      if (client.buf.length < offset + 4) return;
      maskKey = client.buf.subarray(offset, offset + 4); offset += 4;
    }
    if (client.buf.length < offset + len) return;
    let payload = client.buf.subarray(offset, offset + len);
    if (masked) {
      const out = Buffer.alloc(len);
      for (let i = 0; i < len; i++) out[i] = payload[i] ^ maskKey[i & 3];
      payload = out;
    }
    client.buf = client.buf.subarray(offset + len);
    if (opcode === 0x8) { client.socket.end(); return; }      // close
    if (opcode === 0x9) { client.socket.write(encodeFrame(0xA, payload)); continue; } // ping->pong
    if (opcode === 0x1) { relay(client, payload.toString('utf8')); } // text -> 转发
    // 其他 opcode 忽略
  }
}

// 编码服务器->客户端帧（不掩码）
function encodeFrame(opcode, data) {
  const len = data.length;
  let header;
  if (len < 126) {
    header = Buffer.from([0x80 | opcode, len]);
  } else if (len < 65536) {
    header = Buffer.alloc(4);
    header[0] = 0x80 | opcode; header[1] = 126; header.writeUInt16BE(len, 2);
  } else {
    header = Buffer.alloc(10);
    header[0] = 0x80 | opcode; header[1] = 127; header.writeBigUInt64BE(BigInt(len), 2);
  }
  return Buffer.concat([header, data]);
}

server.listen(PORT, () => {
  console.log('[relay] 静态托管: ' + WEB_ROOT);
  console.log('[relay] WebSocket 中继已启动: ws://localhost:' + PORT + '  (用 ?room=xxx 分房)');
});
