// 零依赖冒烟测试：开两个 WebSocket 客户端进同一房间，A 发消息，B 应收到。
// 用法: node smoke_test.js [port]
'use strict';
const http = require('http');
const crypto = require('crypto');
const PORT = parseInt(process.argv[2] || '8080', 10);
const ROOM = 'smoketest';

function connect(onOpen, onMessage) {
  const key = crypto.randomBytes(16).toString('base64');
  const req = http.request({
    port: PORT, host: '127.0.0.1', path: '/?room=' + ROOM,
    headers: {
      'Connection': 'Upgrade', 'Upgrade': 'websocket',
      'Sec-WebSocket-Key': key, 'Sec-WebSocket-Version': '13'
    }
  });
  req.on('upgrade', (res, socket) => {
    let buf = Buffer.alloc(0);
    socket.on('data', (chunk) => {
      buf = Buffer.concat([buf, chunk]);
      while (buf.length >= 2) {
        const b1 = buf[1];
        let len = b1 & 0x7f; let off = 2;
        if (len === 126) { if (buf.length < 4) break; len = buf.readUInt16BE(2); off = 4; }
        else if (len === 127) { if (buf.length < 10) break; len = Number(buf.readBigUInt64BE(2)); off = 10; }
        if (buf.length < off + len) break;
        const payload = buf.subarray(off, off + len);
        buf = buf.subarray(off + len);
        try { onMessage(JSON.parse(payload.toString('utf8'))); } catch (e) {}
      }
    });
    onOpen(socket);
  });
  req.end();
}

function sendText(socket, obj) {
  const data = Buffer.from(JSON.stringify(obj), 'utf8');
  const len = data.length;
  const mask = crypto.randomBytes(4);
  let header;
  if (len < 126) header = Buffer.from([0x81, 0x80 | len]);
  else if (len < 65536) { header = Buffer.alloc(4); header[0] = 0x81; header[1] = 0x80 | 126; header.writeUInt16BE(len, 2); }
  else { header = Buffer.alloc(10); header[0] = 0x81; header[1] = 0x80 | 127; header.writeBigUInt64BE(BigInt(len), 2); }
  const masked = Buffer.alloc(len);
  for (let i = 0; i < len; i++) masked[i] = data[i] ^ mask[i & 3];
  socket.write(Buffer.concat([header, mask, masked]));
}

let received = null;
connect((aSocket) => {
  setTimeout(() => {
    connect((bSocket) => {
      setTimeout(() => sendText(aSocket, { t: 'chat', text: 'hello from A' }), 300);
    }, (msg) => { received = msg; console.log('[B 收到] ' + JSON.stringify(msg)); });
  }, 300);
}, () => {});

setTimeout(() => {
  if (received && received.t === 'chat' && received.text === 'hello from A') {
    console.log('SMOKE_TEST_PASS'); process.exit(0);
  } else {
    console.log('SMOKE_TEST_FAIL received=' + JSON.stringify(received)); process.exit(1);
  }
}, 2500);
