'use strict';
// 零依赖客机 feeder：连同一房间，等「收到主机 state 广播」确认主机已连入后，
// 再发 join，触发主机建代理。保证主机先连（真实游戏流程），避免 join 被中继丢弃。
// 用 Node 22 内置全局 WebSocket（无需 npm 依赖）。
const WS = globalThis.WebSocket;
const url = 'ws://localhost:8080?room=room1';
const sock = new WS(url);
let connected = false;
let joined = false;
sock.addEventListener('open', () => {
  connected = true;
  console.log('[guest] open');
});
sock.addEventListener('message', (e) => {
  const d = (typeof e.data === 'string') ? e.data : e.data.toString();
  if (d.includes('"t":"state"')) {
    if (!joined) {
      joined = true;
      sock.send(JSON.stringify({ t: 'join', pid: 99, room: 'room1', host: false }));
      console.log('[guest] host 已广播，发 join (pid=99)');
    }
  } else {
    console.log('[guest] recv ' + d.slice(0, 120));
  }
});
sock.addEventListener('error', (e) => console.log('[guest] error ' + (e.message || e)));
setTimeout(() => {
  try { sock.close(); } catch (e) {}
  console.log('[guest] done connected=' + connected + ' joined=' + joined);
  process.exit(0);
}, 9000);

