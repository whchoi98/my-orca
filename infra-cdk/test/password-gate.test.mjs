// Local harness for lib/functions/password-gate.js: swaps the CloudFront `cloudfront` module for an
// in-memory key value store and checks the gate's decisions. Run: node test/password-gate.test.mjs
import { readFileSync } from 'node:fs'
import { createHash, createHmac } from 'node:crypto'
import { createRequire } from 'node:module'
import assert from 'node:assert/strict'

const source = readFileSync(new URL('../lib/functions/password-gate.js', import.meta.url), 'utf8')
assert.ok(Buffer.byteLength(source) <= 10240, `function is ${Buffer.byteLength(source)} bytes (> 10 KB)`)

function loadGate(store) {
  const body = source.replace("import cf from 'cloudfront';", '')
  const factory = new Function('cf', 'require', `${body}\nreturn handler;`)
  const cf = { kvs: () => ({ get: async (k) => { if (!(k in store)) throw new Error('KeyNotFound'); return store[k] } }) }
  return factory(cf, createRequire(import.meta.url))
}

// The wire form is base64(utf8(password)), the same value set_password.sh hashes.
const password = Buffer.from('올바른 암호 correct horse', 'utf8').toString('base64')
const salt = 'a1b2c3'
const store = {
  'auth-salt': salt,
  'auth-hash': createHash('sha256').update(`${salt}:${password}`).digest('hex'),
  'auth-signkey': 'k'.repeat(64)
}
const gate = loadGate(store)
const req = (over = {}) => ({ method: 'GET', uri: '/', headers: {}, cookies: {}, querystring: {}, ...over })
const h = (v) => ({ value: v })

// 1. Unauthenticated HTML navigation gets the login page, with the show-password checkbox.
let r = await gate({ request: req({ headers: { accept: h('text/html,*/*') } }) })
assert.equal(r.statusCode, 401); assert.match(r.body, /접속 암호를 입력하세요/)
assert.match(r.body, /type="checkbox" id="v"/); assert.doesNotMatch(r.body, /id="c"/)
// Once a password exists, the first-run setup endpoint is closed at the edge (never forwarded).
r = await gate({ request: req({ method: 'POST', uri: '/__gate/setup', headers: { 'x-orca-setup-code': h('c') } }) })
assert.equal(r.statusCode, 409); assert.equal(r.uri, undefined)

// 2. Unauthenticated WebSocket upgrade and asset requests get a bare 401, never the origin.
r = await gate({ request: req({ uri: '/', headers: { upgrade: h('websocket'), accept: h('text/html') } }) })
assert.equal(r.statusCode, 401); assert.equal(r.body, 'Unauthorized')
r = await gate({ request: req({ uri: '/assets/web.js', headers: { accept: h('*/*') } }) })
assert.equal(r.statusCode, 401)

// 3. Wrong password, missing password and GET login are refused.
r = await gate({ request: req({ method: 'POST', uri: '/__gate/login', headers: { 'x-orca-password': h('nope') } }) })
assert.equal(r.statusCode, 401)
r = await gate({ request: req({ method: 'POST', uri: '/__gate/login' }) })
assert.equal(r.statusCode, 401)
r = await gate({ request: req({ uri: '/__gate/login', headers: { 'x-orca-password': h(password) } }) })
assert.equal(r.statusCode, 405)

// 4. Right password issues a signed, HttpOnly, Secure cookie.
r = await gate({ request: req({ method: 'POST', uri: '/__gate/login', headers: { 'x-orca-password': h(password) } }) })
assert.equal(r.statusCode, 204)
const issued = r.cookies.orca_gate
assert.match(issued.attributes, /HttpOnly/); assert.match(issued.attributes, /Secure/); assert.match(issued.attributes, /Max-Age=604800/)

// 5. The cookie admits HTML, assets and the WebSocket upgrade, and is stripped before the origin.
for (const over of [{ headers: { accept: h('text/html') } }, { uri: '/assets/web.js' }, { headers: { upgrade: h('websocket') } }]) {
  const passed = await gate({ request: req({ ...over, cookies: { orca_gate: { value: issued.value }, other: { value: 'x' } } }) })
  assert.ok(passed.uri, 'request forwarded to origin'); assert.equal(passed.cookies.orca_gate, undefined); assert.equal(passed.cookies.other.value, 'x')
}

// 6. Tampered, expired and foreign-key cookies are rejected.
const [exp, sig] = issued.value.split('.')
for (const value of [`${Number(exp) + 999}.${sig}`, `${exp}.${sig.slice(0, -2)}AA`, `100.${sig}`, 'garbage', `${exp}.`]) {
  r = await gate({ request: req({ cookies: { orca_gate: { value } } }) })
  assert.equal(r.statusCode, 401, `rejected ${value.slice(0, 20)}`)
}
// A correctly signed cookie whose expiry has passed must not admit anything.
const pastExpiry = String(Math.floor(Date.now() / 1000) - 60)
const pastSig = createHmac('sha256', store['auth-signkey']).update(`orca-gate:${pastExpiry}`).digest('base64url')
r = await gate({ request: req({ cookies: { orca_gate: { value: `${pastExpiry}.${pastSig}` } } }) })
assert.equal(r.statusCode, 401, 'expired but validly signed cookie')
r = await loadGate({ ...store, 'auth-signkey': 'z'.repeat(64) })({ request: req({ cookies: { orca_gate: { value: issued.value } } }) })
assert.equal(r.statusCode, 401, 'rotating auth-signkey logs every session out')

// 7. Logout clears the cookie.
r = await gate({ request: req({ uri: '/__gate/logout' }) })
assert.equal(r.statusCode, 302); assert.match(r.cookies.orca_gate.attributes, /Max-Age=0/)

// 8. No password yet (empty store, or keys present but empty): first-login setup mode.
for (const unset of [{}, { 'auth-salt': '', 'auth-hash': '', 'auth-signkey': '' }]) {
  const setupGate = loadGate(unset)
  r = await setupGate({ request: req({ headers: { accept: h('text/html') } }) })
  assert.equal(r.statusCode, 401); assert.match(r.body, /접속 암호를 정하세요/)
  assert.match(r.body, /id="p"/); assert.match(r.body, /id="c"/, 'setup page asks for a confirmation')
  assert.match(r.body, /id="k"[^>]*hidden/, 'setup-code field exists for links that lost their #fragment')
  assert.match(r.body, /type="checkbox" id="v"/)
  // Only POST /__gate/setup reaches the origin setup service; everything else stays closed.
  const forwarded = await setupGate({ request: req({ method: 'POST', uri: '/__gate/setup', cookies: { orca_gate: { value: issued.value } } }) })
  assert.equal(forwarded.uri, '/__gate/setup', 'setup POST forwarded to origin')
  r = await setupGate({ request: req({ uri: '/__gate/setup' }) }); assert.equal(r.statusCode, 405)
  for (const over of [{ headers: { upgrade: h('websocket') } }, { uri: '/assets/web.js' },
    { method: 'POST', uri: '/__gate/login', headers: { 'x-orca-password': h(password) } },
    { headers: { accept: h('text/html') }, cookies: { orca_gate: { value: issued.value } } }]) {
    r = await setupGate({ request: req(over) })
    assert.ok(!r.uri || r.uri === undefined, 'nothing but setup reaches the origin')
    assert.ok([401, 503].includes(r.statusCode), `closed while unset: ${JSON.stringify(over).slice(0, 60)}`)
  }
}

// 9. An empty password never logs in, even if the stored hash were the hash of an empty password.
const emptyHashGate = loadGate({ ...store, 'auth-hash': createHash('sha256').update(`${salt}:`).digest('hex') })
r = await emptyHashGate({ request: req({ method: 'POST', uri: '/__gate/login' }) })
assert.equal(r.statusCode, 401, 'missing password header is refused')

console.log(`password-gate: all checks passed (${Buffer.byteLength(source)} bytes)`)
