// DSH 局域网转发：把只监听回环的 DSH WebUI 暴露到本机局域网地址。
//
// 为什么需要它：DSH 的 web 服务默认只 `listen(3080, '127.0.0.1')`，
// 且 `--host 0.0.0.0` 需要 `DSH_PKG_ALLOW_LAN=1` 才允许（见
// `@deepseek-ai/dsh-web-app/lib/startup.js`）；桌面版用 `.store.dat` 里的
// `port` 启动 harness，没有局域网开关。本脚本在不重启 harness 的前提下，
// 在局域网地址上再开一个监听，把请求转给回环上的 DSH。
//
// Host 头会被改写成回环地址：`@deepseek-ai/dsh-client-connection` 的
// browser-trust fence 只接受回环 Host 或显式 `trustedHosts`
// （`isTrustedApiRequest`：`if (!isLoopbackHostname(...) && !isTrustedAuthority(...)) return false;`）。
// 拾忆 APP 的局域网模式本来就把 Host 覆盖成 `127.0.0.1:<port>`
// （`dsh_service.dart` 的 `_lanLoopbackHost`），浏览器直连时才需要这层改写。
//
// 用法：
//   node tools/dsh_lan_proxy.mjs --listen 0.0.0.0 --port 3080 --target 127.0.0.1
// 说明：
//   --listen 监听地址（默认 0.0.0.0；只想暴露单张网卡时填该网卡 IP）
//   --port   对外端口（默认 3080）
//   --target 上游地址（默认 127.0.0.1）
//   --target-port 上游端口（默认同 --port）
// 安全：DSH 的 WebUI 等于本机代码执行入口，务必配合防火墙只放行本网段，
//       并依赖 DSH 自身的 token / 会话 Cookie 鉴权（本脚本不做鉴权）。

import http from 'node:http';
import net from 'node:net';

const argv = process.argv.slice(2);
function opt(name, fallback) {
  const i = argv.indexOf(`--${name}`);
  return i >= 0 && argv[i + 1] ? argv[i + 1] : fallback;
}

const listenHost = opt('listen', '0.0.0.0');
const listenPort = Number(opt('port', '3080'));
const targetHost = opt('target', '127.0.0.1');
const targetPort = Number(opt('target-port', String(listenPort)));
const upstreamAuthority = `${targetHost}:${targetPort}`;

function stamp() {
  return new Date().toISOString();
}

function log(...parts) {
  console.log(`[${stamp()}]`, ...parts);
}

/** 把请求头里的 Host（及其它指向对外地址的标记）改成上游的回环身份。 */
function upstreamHeaders(rawHeaders) {
  const headers = { ...rawHeaders };
  headers.host = upstreamAuthority;
  // 浏览器标记会把跨站请求挡在 fence 外，转发后由 fence 按同源重新判定。
  delete headers['sec-fetch-site'];
  return headers;
}

const server = http.createServer((req, res) => {
  const peer = req.socket.remoteAddress ?? '?';
  const upstream = http.request(
    {
      host: targetHost,
      port: targetPort,
      method: req.method,
      path: req.url,
      headers: upstreamHeaders(req.headers),
    },
    (up) => {
      log(`${peer} ${req.method} ${req.url} -> ${up.statusCode ?? 502}`);
      res.writeHead(up.statusCode ?? 502, up.headers);
      up.pipe(res);
    },
  );
  upstream.on('error', (error) => {
    log('proxy error', peer, req.method, req.url, error.message);
    if (!res.headersSent) res.writeHead(502, { 'content-type': 'text/plain; charset=utf-8' });
    res.end(`dsh lan proxy: ${error.message}\n`);
  });
  req.pipe(upstream);
});

// WebSocket 升级：手动转发请求行 + 头（同样改写 Host），之后双向原样管道。
server.on('upgrade', (req, socket, head) => {
  const upstream = net.connect(targetPort, targetHost, () => {
    const lines = [`${req.method} ${req.url} HTTP/1.1`];
    for (const [key, value] of Object.entries(upstreamHeaders(req.headers))) {
      if (value === undefined) continue;
      lines.push(`${key}: ${Array.isArray(value) ? value.join(', ') : value}`);
    }
    upstream.write(`${lines.join('\r\n')}\r\n\r\n`);
    if (head?.length) upstream.write(head);
    upstream.pipe(socket);
    socket.pipe(upstream);
  });
  upstream.on('error', (error) => {
    log('upgrade error', req.url, error.message);
    socket.destroy();
  });
  socket.on('error', () => upstream.destroy());
});

server.on('error', (error) => {
  log('listen failed', error.message);
  process.exit(1);
});

server.listen(listenPort, listenHost, () => {
  log(`dsh lan proxy listening on http://${listenHost}:${listenPort} -> http://${upstreamAuthority}`);
});
