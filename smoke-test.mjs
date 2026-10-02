// End-to-end check of a deployed relay, the way the Orca desktop drives it:
// PKCE sign-in -> session -> refresh -> relay-token -> /v1/assign -> host control WebSocket upgrade.
// Usage: node smoke-test.mjs https://dxxxx.cloudfront.net <owner-password>
import { createHash, randomBytes } from 'node:crypto'
import { createRequire } from 'node:module'
import { homedir } from 'node:os'

const require = createRequire(`${homedir()}/code/orca/cloud/apps/relay/package.json`)
const WebSocket = require('ws')

const [base, password] = process.argv.slice(2)
if (!base || !password) throw new Error('usage: node smoke-test.mjs <base-url> <owner-password>')

const b64 = (b) => Buffer.from(b).toString('base64url')
const sha = (v) => createHash('sha256').update(v).digest()
let failures = 0
const check = (name, ok, detail = '') => {
  if (!ok) failures++
  console.log(`${ok ? 'PASS' : 'FAIL'}  ${name}${detail ? `  (${detail})` : ''}`)
}
const timed = async (fn) => {
  const t = performance.now()
  const value = await fn()
  return [value, Math.round(performance.now() - t)]
}
const post = (path, body, token) =>
  fetch(`${base}${path}`, {
    method: 'POST',
    headers: { 'content-type': 'application/json', ...(token ? { authorization: `Bearer ${token}` } : {}) },
    body: JSON.stringify(body)
  })

const verifier = b64(randomBytes(32))
const state = b64(randomBytes(16))
const nonce = b64(randomBytes(16))
const redirect = 'http://127.0.0.1:55555/auth/callback'
const params = {
  client_id: 'orca-desktop', redirect_uri: redirect, state, nonce,
  code_challenge: b64(sha(verifier)), local_profile_id: 'smoke-test'
}

const [page, pageMs] = await timed(() =>
  fetch(`${base}/v1/desktop/auth/authorize?${new URLSearchParams({ ...params, response_type: 'code', code_challenge_method: 'S256', scope: 'openid' })}`))
check('authorize page', page.status === 200, `${page.status}, ${pageMs}ms`)

const login = await fetch(`${base}/v1/desktop/auth/authorize`, {
  method: 'POST', redirect: 'manual',
  body: new URLSearchParams({ ...params, action: 'login', password })
})
const location = login.headers.get('location')
check('password login redirects to loopback', login.status === 302 && location?.startsWith(redirect), String(login.status))
const code = location && new URL(location).searchParams.get('code')

const session = await (await post('/v1/desktop/auth/session',
  { code, codeVerifier: verifier, nonce, redirectUri: redirect, state, localProfileId: 'smoke-test' })).json()
check('session exchange', Boolean(session.accessToken) && session.capabilities?.flags?.['relay.use'] === true)

const refreshed = await (await post('/v1/desktop/auth/refresh', { refreshToken: session.refreshToken })).json()
check('refresh keeps identity', refreshed.cloud?.cloudProfileId === session.cloud?.cloudProfileId)

const publicKey = randomBytes(32)
const relayHostId = b64(sha(publicKey)).slice(0, 16)
const tokenResponse = await post('/v1/desktop/auth/relay-token',
  { relayHostId, hostPublicKeyB64: publicKey.toString('base64') }, refreshed.accessToken)
const { relayToken } = await tokenResponse.json()
check('relay token minted', tokenResponse.status === 200 && Boolean(relayToken), String(tokenResponse.status))

const [assign, assignMs] = await timed(() => post('/v1/assign', { v: 1, relayHostId, reconnect: true }, relayToken))
const assignment = await assign.json().catch(() => ({}))
check('director assignment', assign.status === 200 && assignment.cellUrl === base, `${assign.status}, ${assignMs}ms, cell ${assignment.cellUrl}`)

const admin = await fetch(`${base}/v1/admin/drain`, { method: 'POST' })
check('admin routes blocked at the edge', admin.status === 404, String(admin.status))

const rejected = await post('/v1/assign', { v: 1, relayHostId }, refreshed.accessToken)
check('relay rejects non-relay tokens', rejected.status === 401, String(rejected.status))

// A real host would now send its signed hello; opening the socket proves the upgrade
// survives CloudFront with the Authorization header intact.
await new Promise((resolve) => {
  const started = performance.now()
  const ws = new WebSocket(`${base.replace(/^http/, 'ws')}/v1/host/control`, {
    headers: { authorization: `Bearer ${relayToken}` }
  })
  ws.once('open', () => {
    check('host control WebSocket upgrade through CloudFront', true, `${Math.round(performance.now() - started)}ms`)
    ws.close()
    resolve()
  })
  ws.once('unexpected-response', (_req, res) => {
    check('host control WebSocket upgrade through CloudFront', false, `HTTP ${res.statusCode}`)
    resolve()
  })
  ws.once('error', (error) => {
    check('host control WebSocket upgrade through CloudFront', false, error.message)
    resolve()
  })
})

console.log(failures ? `\n${failures} check(s) failed` : '\nall checks passed')
process.exit(failures ? 1 : 0)
