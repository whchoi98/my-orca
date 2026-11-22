// CloudFront Function (cloudfront-js-2.0, viewer request): password gate in front of Orca.
// Orca has no password of its own (access is its pairing link), so this gate plays the role
// of code-server's password page. It runs on every request, including the WebSocket upgrade
// GET, so the Orca UI, its assets and its RPC socket all need the gate cookie.
//
// Key value store (written by set_password.sh or, on first login, the EC2 setup service):
//   auth-salt / auth-hash = sha256 hex of `${salt}:${base64(utf8(password))}` / auth-signkey
// Pages send base64(utf8(password)): fetch() header values must be Latin-1.
// No password yet: HTML requests get the setup page and only POST /__gate/setup reaches the
// origin (the setup service checks the one-time code from the pairing link).
import cf from 'cloudfront';

const crypto = require('crypto');
const kvs = cf.kvs();

const COOKIE = 'orca_gate';
const MAX_AGE = 7 * 24 * 3600;
const ATTRS = 'Path=/; Secure; HttpOnly; SameSite=Lax';

async function readConfig() {
  try {
    const salt = await kvs.get('auth-salt');
    const hash = await kvs.get('auth-hash');
    const signKey = await kvs.get('auth-signkey');
    return salt && hash && signKey ? { salt, hash, signKey } : null;
  } catch (e) {
    return null;
  }
}

function safeEqual(a, b) {
  if (typeof a !== 'string' || typeof b !== 'string' || a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}

function sign(key, expiry) {
  return crypto.createHmac('sha256', key).update('orca-gate:' + expiry).digest('base64url');
}

function hasValidCookie(request, key) {
  const cookie = request.cookies[COOKIE];
  if (!cookie || !cookie.value) return false;
  const dot = cookie.value.indexOf('.');
  if (dot < 1) return false;
  const expiry = cookie.value.slice(0, dot);
  if (!/^[0-9]{1,12}$/.test(expiry) || Number(expiry) < Math.floor(Date.now() / 1000)) return false;
  return safeEqual(cookie.value.slice(dot + 1), sign(key, expiry));
}

function header(request, name) {
  const h = request.headers[name];
  return h ? h.value : '';
}

function reply(statusCode, body, type, extra) {
  const headers = { 'content-type': { value: (type || 'text/plain') + '; charset=utf-8' }, 'cache-control': { value: 'no-store' } };
  for (const k in extra || {}) headers[k] = { value: extra[k] };
  return { statusCode, headers, body };
}

const CSS = ':root{color-scheme:light dark;--bg:#f6f7f9;--fg:#1d2330;--card:#fff;--line:#d8dce3;--ac:#0b6bcb;--err:#c4282d}'
  + '@media (prefers-color-scheme:dark){:root{--bg:#14171c;--fg:#e7e9ee;--card:#1d2128;--line:#353b45;--ac:#4c9ff0;--err:#ff6b6b}}'
  + 'body{margin:0;min-height:100vh;display:grid;place-items:center;background:var(--bg);color:var(--fg);font:15px/1.5 system-ui,-apple-system,"Segoe UI",sans-serif}'
  + 'form{width:min(340px,calc(100vw - 32px));background:var(--card);border:1px solid var(--line);border-radius:10px;padding:28px 24px}'
  + 'h1{margin:0 0 4px;font-size:20px}p{margin:0 0 18px;opacity:.75;font-size:13px}'
  + 'input.pw,input.cd,button{box-sizing:border-box;width:100%;font:inherit;border-radius:6px;padding:10px 12px}'
  + 'input.pw,input.cd{border:1px solid var(--line);background:transparent;color:inherit;margin-bottom:10px}'
  + 'label{display:flex;gap:6px;align-items:center;font-size:13px;margin:2px 0 14px;cursor:pointer}'
  + 'button{border:0;background:var(--ac);color:#fff;font-weight:600;cursor:pointer}button:disabled{opacity:.6}'
  + '#e{color:var(--err);font-size:13px;min-height:20px;margin:10px 0 0}';

// Shared by both pages: base64(utf8()), the show-password checkbox, error output.
const JS = "var f=document.getElementById('f'),b=document.getElementById('b'),e=document.getElementById('e');"
  + "function enc(v){var u=new TextEncoder().encode(v),s='';for(var i=0;i<u.length;i++)s+=String.fromCharCode(u[i]);return btoa(s)}"
  + "function val(id){return document.getElementById(id).value}"
  + "function err(m){e.textContent=m;b.disabled=false}"
  + "function login(p){return fetch('/__gate/login',{method:'POST',credentials:'same-origin',headers:{'x-orca-password':enc(p)}})}"
  + "document.getElementById('v').onchange=function(){var t=this.checked?'text':'password';"
  + "document.querySelectorAll('input.pw').forEach(function(i){i.type=t})};";

function page(title, lead, fields, button, script) {
  return '<!doctype html><html lang="ko"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">'
    + '<title>' + title + '</title><style>' + CSS + '</style></head><body><form id="f"><h1>Orca</h1><p>' + lead + '</p>' + fields
    + '<label><input type="checkbox" id="v">암호 보기</label><button id="b" type="submit">' + button + '</button>'
    + '<div id="e" role="alert"></div></form><script>' + JS + script + '</script></body></html>';
}

const LOGIN_PAGE = page('Orca 로그인', '접속 암호를 입력하세요.',
  '<input class="pw" id="p" type="password" autocomplete="current-password" autofocus required aria-label="암호">', '로그인',
  "f.onsubmit=async function(ev){ev.preventDefault();b.disabled=true;e.textContent='';"
  + "try{var r=await login(val('p'));if(r.status===204){location.reload();return}"
  + "err(r.status===401?'암호가 올바르지 않습니다.':'로그인할 수 없습니다 ('+r.status+').')}catch(x){err('네트워크 오류가 발생했습니다.')}};");

// The one-time code normally rides in the link (#…&gate-setup=…). A long link can lose its tail
// when copied or opened through an editor, so the page then asks for the code instead.
const SETUP_PAGE = page('Orca 접속 암호 설정', '처음 접속입니다. 사용할 접속 암호를 정하세요 (8자 이상).',
  '<input class="cd" id="k" type="text" autocomplete="off" spellcheck="false" hidden aria-label="설정 코드" placeholder="설정 코드 (get_pairing_url.sh 출력)">'
  + '<input class="pw" id="p" type="password" autocomplete="new-password" autofocus required aria-label="새 암호" placeholder="새 암호">'
  + '<input class="pw" id="c" type="password" autocomplete="new-password" required aria-label="암호 확인" placeholder="암호 확인">', '설정',
  "var h=new URLSearchParams(location.hash.slice(1)),code=h.get('gate-setup'),k=document.getElementById('k');"
  + "if(!code){k.hidden=false;k.required=true;k.focus()}"
  + "f.onsubmit=async function(ev){ev.preventDefault();var p=val('p'),sc=code||k.value.trim();b.disabled=true;e.textContent='';"
  + "if(!sc)return err('설정 코드를 입력하세요.');"
  + "if(p.length<8)return err('암호는 8자 이상이어야 합니다.');if(p!==val('c'))return err('두 암호가 다릅니다.');"
  + "try{var r=await fetch('/__gate/setup',{method:'POST',headers:{'x-orca-setup-code':sc,'x-orca-password':enc(p),'x-orca-password-confirm':enc(val('c'))}});"
  + "if(r.status===204){e.textContent='적용 중입니다…';for(var i=0;i<45;i++){var l=await login(p);"
  // Back to the pairing link without the code; with no pairing in the URL, Orca's root asks for it.
  + "if(l.status===204){h.delete('gate-setup');var q=h.toString();history.replaceState(null,'',(h.get('pairing')?location.pathname:'/')+(q?'#'+q:''));location.reload();return}"
  + "await new Promise(function(z){setTimeout(z,2000)})}return err('적용이 늦어지고 있습니다. 잠시 뒤 새로고침하세요.')}"
  + "if(r.status===409){e.textContent='이미 설정되었습니다.';setTimeout(function(){location.reload()},1500);return}"
  + "err(r.status===401?'설정 코드가 올바르지 않습니다. 새 링크를 받으세요.':r.status===423?'시도 횟수를 넘었습니다.':'설정할 수 없습니다 ('+r.status+').')}"
  + "catch(x){err('네트워크 오류가 발생했습니다.')}};");

async function handler(event) {
  const request = event.request;
  const isWebSocket = header(request, 'upgrade').toLowerCase() === 'websocket';
  const wantsHtml = !isWebSocket && request.method === 'GET' && header(request, 'accept').indexOf('text/html') !== -1;
  const config = await readConfig();

  if (!config) {
    // First login: the EC2 setup service validates the code and writes the store.
    if (request.uri === '/__gate/setup') return request.method === 'POST' ? request : reply(405, 'POST only');
    if (wantsHtml) return reply(401, SETUP_PAGE, 'text/html', { 'x-frame-options': 'DENY' });
    return reply(503, 'Password gate is not configured yet.');
  }

  if (request.uri === '/__gate/setup') return reply(409, 'A password is already set.');
  if (request.uri === '/__gate/login') {
    if (request.method !== 'POST') return reply(405, 'POST only');
    const supplied = header(request, 'x-orca-password');
    const computed = crypto.createHash('sha256').update(config.salt + ':' + supplied).digest('hex');
    if (!supplied || !safeEqual(computed, config.hash)) return reply(401, 'invalid password');
    const expiry = String(Math.floor(Date.now() / 1000) + MAX_AGE);
    return {
      statusCode: 204,
      headers: { 'cache-control': { value: 'no-store' } },
      cookies: { [COOKIE]: { value: expiry + '.' + sign(config.signKey, expiry), attributes: ATTRS + '; Max-Age=' + MAX_AGE } },
    };
  }
  if (request.uri === '/__gate/logout') {
    return {
      statusCode: 302,
      headers: { location: { value: '/' }, 'cache-control': { value: 'no-store' } },
      cookies: { [COOKIE]: { value: '', attributes: ATTRS + '; Max-Age=0' } },
    };
  }
  if (hasValidCookie(request, config.signKey)) {
    delete request.cookies[COOKIE]; // the origin never needs the gate cookie
    return request;
  }
  if (wantsHtml) return reply(401, LOGIN_PAGE, 'text/html', { 'x-frame-options': 'DENY' });
  return reply(401, 'Unauthorized');
}
