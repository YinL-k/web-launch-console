import crypto from 'node:crypto';
import fs from 'node:fs';
import http from 'node:http';
import path from 'node:path';
import { URL } from 'node:url';

const root = path.resolve(process.env.WEB_LAUNCH_ROOT || '');
const port = Number(process.env.WEB_LAUNCH_PORT || 8088);
const host = process.env.WEB_LAUNCH_HOST || '127.0.0.1';
const spaFallback = /^true$/i.test(process.env.WEB_LAUNCH_SPA_FALLBACK || 'true');
const password = process.env.WEB_LAUNCH_PASSWORD || '';
const sessionToken = process.env.WEB_LAUNCH_SESSION_TOKEN || crypto.randomBytes(32).toString('hex');

if (!root || !fs.existsSync(root) || !fs.statSync(root).isDirectory()) throw new Error('WEB_LAUNCH_ROOT must point to an existing directory.');
if (!Number.isInteger(port) || port < 1 || port > 65535) throw new Error('WEB_LAUNCH_PORT must be a valid TCP port.');

const mimeTypes = new Map([
  ['.html', 'text/html; charset=utf-8'], ['.htm', 'text/html; charset=utf-8'],
  ['.js', 'text/javascript; charset=utf-8'], ['.mjs', 'text/javascript; charset=utf-8'],
  ['.css', 'text/css; charset=utf-8'], ['.json', 'application/json; charset=utf-8'],
  ['.svg', 'image/svg+xml'], ['.png', 'image/png'], ['.jpg', 'image/jpeg'],
  ['.jpeg', 'image/jpeg'], ['.gif', 'image/gif'], ['.webp', 'image/webp'],
  ['.ico', 'image/x-icon'], ['.woff', 'font/woff'], ['.woff2', 'font/woff2'],
  ['.txt', 'text/plain; charset=utf-8'], ['.map', 'application/json; charset=utf-8'],
]);

function send(res, status, body, headers = {}) {
  res.writeHead(status, { 'Cache-Control': 'no-store', 'X-Content-Type-Options': 'nosniff', ...headers });
  res.end(body);
}

function hasSession(req) {
  if (!password) return true;
  const entry = String(req.headers.cookie || '').split(';').map((item) => item.trim()).find((item) => item.startsWith('web_launch_session='));
  if (!entry) return false;
  const left = Buffer.from(entry.slice('web_launch_session='.length));
  const right = Buffer.from(sessionToken);
  return left.length === right.length && crypto.timingSafeEqual(left, right);
}

function loginPage(error = '') {
  return `<!doctype html><html lang="zh-CN"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>访问验证</title><style>body{margin:0;background:#f5f7fb;font:16px system-ui;color:#172033;display:grid;place-items:center;min-height:100vh}.box{width:min(360px,calc(100% - 48px));background:#fff;padding:32px;border-radius:18px;box-shadow:0 18px 50px #17203318}h1{font-size:22px;margin:0 0 8px}p{color:#657087;margin:0 0 22px}.error{color:#c43333}input,button{box-sizing:border-box;width:100%;padding:12px 14px;border-radius:10px;font:inherit}input{border:1px solid #d9deea;margin-bottom:12px}button{border:0;background:#2563eb;color:white;font-weight:650;cursor:pointer}</style></head><body><form class="box" method="post" action="/_launcher/login"><h1>请输入访问口令</h1><p class="${error ? 'error' : ''}">${error || '此页面已由 Web Launch Console 保护。'}</p><input type="password" name="password" autocomplete="current-password" autofocus required><button type="submit">进入网页</button></form></body></html>`;
}

function resolveRequestFile(pathname) {
  let decoded;
  try { decoded = decodeURIComponent(pathname); } catch { return null; }
  const candidate = path.resolve(root, decoded.replace(/^[/\\]+/, ''));
  const relative = path.relative(root, candidate);
  if (relative.startsWith('..') || path.isAbsolute(relative)) return null;
  try {
    if (fs.statSync(candidate).isDirectory()) return path.join(candidate, 'index.html');
    return candidate;
  } catch {
    return spaFallback ? path.join(root, 'index.html') : candidate;
  }
}

const server = http.createServer((req, res) => {
  const requestUrl = new URL(req.url || '/', `http://${req.headers.host || 'localhost'}`);
  if (requestUrl.pathname === '/_launcher/health') return send(res, 200, JSON.stringify({ ok: true }), { 'Content-Type': 'application/json; charset=utf-8' });
  if (requestUrl.pathname === '/_launcher/login' && req.method === 'GET') return send(res, 200, loginPage(), { 'Content-Type': 'text/html; charset=utf-8' });
  if (requestUrl.pathname === '/_launcher/login' && req.method === 'POST') {
    let body = '';
    req.on('data', (chunk) => { body += chunk; if (body.length > 8192) req.destroy(); });
    req.on('end', () => {
      const supplied = new URLSearchParams(body).get('password') || '';
      const left = Buffer.from(supplied);
      const right = Buffer.from(password);
      const valid = left.length === right.length && crypto.timingSafeEqual(left, right);
      if (!valid) return send(res, 401, loginPage('访问口令不正确。'), { 'Content-Type': 'text/html; charset=utf-8' });
      return send(res, 302, '', { Location: '/', 'Set-Cookie': `web_launch_session=${sessionToken}; Path=/; HttpOnly; SameSite=Lax` });
    });
    return;
  }
  if (!hasSession(req)) return send(res, 302, '', { Location: '/_launcher/login' });
  if (req.method !== 'GET' && req.method !== 'HEAD') return send(res, 405, 'Method Not Allowed');
  const file = resolveRequestFile(requestUrl.pathname);
  if (!file) return send(res, 400, 'Bad Request');
  fs.stat(file, (error, stat) => {
    if (error || !stat.isFile()) return send(res, 404, 'Not Found');
    const headers = {
      'Content-Type': mimeTypes.get(path.extname(file).toLowerCase()) || 'application/octet-stream',
      'Content-Length': stat.size,
      'Cache-Control': /[.-][a-f0-9]{8,}\./i.test(path.basename(file)) ? 'public, max-age=31536000, immutable' : 'no-cache',
    };
    res.writeHead(200, headers);
    if (req.method === 'HEAD') return res.end();
    fs.createReadStream(file).on('error', () => res.destroy()).pipe(res);
  });
});

server.listen(port, host, () => console.log(`web-ready http://${host}:${port}`));
function shutdown() { server.close(() => process.exit(0)); setTimeout(() => process.exit(1), 3000).unref(); }
process.on('SIGINT', shutdown);
process.on('SIGTERM', shutdown);

