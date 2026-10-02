// Minimal single-user stand-in for the private Orca Cloud desktop auth API.
// It implements just enough of /v1/desktop/auth/* for an Orca desktop to sign in
// and mint relay host-control tokens for a self-hosted relay.
import { createServer } from 'node:http'
import { createHash, randomBytes, timingSafeEqual } from 'node:crypto'
import { existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'
import { SignJWT, jwtVerify, generateKeyPair, exportJWK, importJWK } from 'jose'

const env = process.env
const PORT = Number(env.PORT ?? 8787)
const ISSUER = required('AUTH_ISSUER').replace(/\/$/, '')
const CLIENT_ID = env.AUTH_CLIENT_ID ?? 'orca-desktop'
const OWNER_EMAIL = env.OWNER_EMAIL ?? 'owner@localhost'
const OWNER_PASSWORD = required('OWNER_PASSWORD')
const DATA_DIR = env.AUTH_DATA_DIR ?? './data'
const ACCESS_TTL_S = 12 * 3600
const REFRESH_TTL_S = 365 * 24 * 3600
const RELAY_TOKEN_TTL_S = 15 * 60
const CODE_TTL_MS = 5 * 60_000
const USER_ID = 'owner'

if (OWNER_PASSWORD.length < 12) throw new Error('OWNER_PASSWORD must be at least 12 characters')

function required(name) {
  const value = env[name]?.trim()
  if (!value) throw new Error(`${name} is required`)
  return value
}

// ---------- keys (generated once, persisted in DATA_DIR) ----------
mkdirSync(DATA_DIR, { recursive: true })
const relayKeyPath = join(DATA_DIR, 'relay-signing-key.json')
const sessionSecretPath = join(DATA_DIR, 'session-secret')

if (!existsSync(relayKeyPath)) {
  const { privateKey } = await generateKeyPair('ES256', { extractable: true })
  const jwk = await exportJWK(privateKey)
  jwk.kid = randomBytes(8).toString('hex')
  writeFileSync(relayKeyPath, JSON.stringify(jwk), { mode: 0o600 })
}
if (!existsSync(sessionSecretPath)) {
  writeFileSync(sessionSecretPath, randomBytes(48).toString('base64url'), { mode: 0o600 })
}
const relayPrivateJwk = JSON.parse(readFileSync(relayKeyPath, 'utf8'))
const relayPrivateKey = await importJWK(relayPrivateJwk, 'ES256')
const { d: _d, ...relayPublicJwk } = relayPrivateJwk
const jwks = { keys: [{ ...relayPublicJwk, use: 'sig', alg: 'ES256' }] }
const sessionSecret = new TextEncoder().encode(readFileSync(sessionSecretPath, 'utf8').trim())

// ---------- helpers ----------
const sha256 = (value) => createHash('sha256').update(value).digest()
const b64url = (buf) => Buffer.from(buf).toString('base64url')
const nowS = () => Math.floor(Date.now() / 1000)

function sameSecret(a, b) {
  return timingSafeEqual(sha256(a), sha256(b))
}

function profileIdFor(localProfileId) {
  return `p-${b64url(sha256(String(localProfileId ?? 'default'))).slice(0, 16)}`
}

async function signSessionToken(typ, prof, ttl) {
  return new SignJWT({ typ, prof })
    .setProtectedHeader({ alg: 'HS256' })
    .setSubject(USER_ID)
    .setIssuer(ISSUER)
    .setIssuedAt()
    .setExpirationTime(nowS() + ttl)
    .setJti(b64url(randomBytes(12)))
    .sign(sessionSecret)
}

async function verifySessionToken(token, typ) {
  try {
    const { payload } = await jwtVerify(token, sessionSecret, { issuer: ISSUER, algorithms: ['HS256'] })
    return payload.typ === typ && payload.sub === USER_ID && typeof payload.prof === 'string' ? payload : null
  } catch {
    return null
  }
}

function cloudSummary(prof) {
  return { cloudProfileId: prof, userId: USER_ID, email: OWNER_EMAIL, displayName: 'Owner' }
}

const capabilities = () => ({ flags: { 'relay.use': true }, refreshedAt: Date.now() })

async function sessionResponse(prof) {
  const accessToken = await signSessionToken('access', prof, ACCESS_TTL_S)
  const refreshToken = await signSessionToken('refresh', prof, REFRESH_TTL_S)
  return {
    accessToken,
    refreshToken,
    expiresAt: (nowS() + ACCESS_TTL_S) * 1000,
    cloud: cloudSummary(prof),
    organizations: [],
    capabilities: capabilities()
  }
}

function send(res, status, body, headers = {}) {
  const isString = typeof body === 'string'
  res.writeHead(status, {
    'content-type': isString ? 'text/html; charset=utf-8' : 'application/json',
    'cache-control': 'no-store',
    ...headers
  })
  res.end(isString ? body : JSON.stringify(body))
}

async function readBody(req, limit = 64 * 1024) {
  const chunks = []
  let size = 0
  for await (const chunk of req) {
    size += chunk.length
    if (size > limit) throw Object.assign(new Error('body too large'), { status: 413 })
    chunks.push(chunk)
  }
  return Buffer.concat(chunks).toString('utf8')
}

async function readJson(req) {
  try {
    const parsed = JSON.parse((await readBody(req)) || '{}')
    return parsed && typeof parsed === 'object' ? parsed : {}
  } catch (error) {
    if (error.status) throw error
    throw Object.assign(new Error('invalid json'), { status: 400 })
  }
}

async function bearerSession(req) {
  const match = /^Bearer ([^\s]+)$/.exec(req.headers.authorization ?? '')
  return match ? verifySessionToken(match[1], 'access') : null
}

function isLoopbackCallback(value) {
  try {
    const url = new URL(value)
    return url.protocol === 'http:' && url.hostname === '127.0.0.1' && url.pathname === '/auth/callback'
  } catch {
    return false
  }
}

const escapeHtml = (value) =>
  String(value).replace(/[&<>"']/g, (c) => `&#${c.charCodeAt(0)};`)

// ---------- authorization codes + login throttle ----------
const pendingCodes = new Map()
let failedLogins = []

function loginThrottled() {
  const cutoff = Date.now() - 15 * 60_000
  failedLogins = failedLogins.filter((t) => t > cutoff)
  return failedLogins.length >= 10
}

setInterval(() => {
  const now = Date.now()
  for (const [code, entry] of pendingCodes) if (entry.expiresAt < now) pendingCodes.delete(code)
}, 60_000).unref()

const AUTHORIZE_FIELDS = ['client_id', 'redirect_uri', 'state', 'nonce', 'code_challenge', 'local_profile_id']

function validateAuthorizeParams(params) {
  if (params.client_id !== CLIENT_ID) return 'unknown client_id'
  if (params.response_type !== undefined && params.response_type !== 'code') return 'unsupported response_type'
  if (params.code_challenge_method !== undefined && params.code_challenge_method !== 'S256')
    return 'unsupported code_challenge_method'
  if (!isLoopbackCallback(params.redirect_uri)) return 'redirect_uri must be a 127.0.0.1 loopback callback'
  if (!params.state || !params.nonce || !/^[A-Za-z0-9_-]{43}$/.test(params.code_challenge ?? ''))
    return 'missing state, nonce or code_challenge'
  return null
}

function loginPage(params, message = '') {
  const hidden = AUTHORIZE_FIELDS.map(
    (name) => `<input type="hidden" name="${name}" value="${escapeHtml(params[name] ?? '')}">`
  ).join('')
  return `<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width">
<title>Orca self-hosted sign-in</title>
<style>body{font-family:system-ui;max-width:360px;margin:15vh auto;padding:0 16px}
input[type=password]{width:100%;padding:8px;font-size:16px;box-sizing:border-box}
button{margin-top:12px;padding:8px 16px;font-size:15px}.err{color:#c00}</style></head><body>
<h2>Orca relay sign-in</h2><p>${escapeHtml(OWNER_EMAIL)}</p>
${message ? `<p class="err">${escapeHtml(message)}</p>` : ''}
<form method="post" action="/v1/desktop/auth/authorize">${hidden}
<input type="password" name="password" placeholder="Password" autofocus required>
<button type="submit" name="action" value="login">Sign in</button>
<button type="submit" name="action" value="cancel" formnovalidate>Cancel</button></form></body></html>`
}

function redirectTo(res, redirectUri, query) {
  const url = new URL(redirectUri)
  for (const [key, value] of Object.entries(query)) url.searchParams.set(key, value)
  res.writeHead(302, { location: url.toString(), 'cache-control': 'no-store' })
  res.end()
}

// ---------- routes ----------
async function handle(req, res) {
  const url = new URL(req.url ?? '/', ISSUER)
  const route = `${req.method} ${url.pathname}`

  if (route === 'GET /health') return send(res, 200, { ok: true })
  if (route === 'GET /.well-known/jwks.json') return send(res, 200, jwks)

  if (route === 'GET /v1/desktop/auth/authorize') {
    const params = Object.fromEntries(url.searchParams)
    const problem = validateAuthorizeParams(params)
    if (problem) return send(res, 400, `<p>${escapeHtml(problem)}</p>`)
    return send(res, 200, loginPage(params))
  }

  if (route === 'POST /v1/desktop/auth/authorize') {
    const params = Object.fromEntries(new URLSearchParams(await readBody(req)))
    const problem = validateAuthorizeParams(params)
    if (problem) return send(res, 400, `<p>${escapeHtml(problem)}</p>`)
    if (params.action === 'cancel') {
      return redirectTo(res, params.redirect_uri, { error: 'access_denied', state: params.state })
    }
    if (loginThrottled()) return send(res, 429, loginPage(params, 'Too many attempts, try again later.'))
    if (!sameSecret(params.password ?? '', OWNER_PASSWORD)) {
      failedLogins.push(Date.now())
      await new Promise((resolve) => setTimeout(resolve, 1000))
      return send(res, 401, loginPage(params, 'Wrong password.'))
    }
    const code = b64url(randomBytes(32))
    pendingCodes.set(code, {
      challenge: params.code_challenge,
      redirectUri: params.redirect_uri,
      state: params.state,
      nonce: params.nonce,
      localProfileId: params.local_profile_id,
      expiresAt: Date.now() + CODE_TTL_MS
    })
    return redirectTo(res, params.redirect_uri, { code, state: params.state })
  }

  if (route === 'POST /v1/desktop/auth/session') {
    const body = await readJson(req)
    const entry = pendingCodes.get(body.code)
    pendingCodes.delete(body.code)
    const verifierOk =
      entry && typeof body.codeVerifier === 'string' && b64url(sha256(body.codeVerifier)) === entry.challenge
    if (
      !entry ||
      entry.expiresAt < Date.now() ||
      !verifierOk ||
      body.redirectUri !== entry.redirectUri ||
      body.state !== entry.state ||
      body.nonce !== entry.nonce
    ) {
      return send(res, 400, { error: 'invalid_grant' })
    }
    return send(res, 200, await sessionResponse(profileIdFor(entry.localProfileId ?? body.localProfileId)))
  }

  if (route === 'POST /v1/desktop/auth/refresh') {
    const body = await readJson(req)
    const claims = typeof body.refreshToken === 'string' ? await verifySessionToken(body.refreshToken, 'refresh') : null
    if (!claims) return send(res, 401, { error: 'invalid_grant' })
    return send(res, 200, await sessionResponse(claims.prof))
  }

  if (route === 'POST /v1/desktop/auth/logout') {
    await readBody(req).catch(() => '')
    return send(res, 200, {})
  }

  // Everything below needs a valid access token.
  const session = await bearerSession(req)

  if (route === 'POST /v1/desktop/auth/capabilities' || route === 'POST /v1/desktop/auth/org') {
    if (!session) return send(res, 401, { error: 'unauthorized' })
    return send(res, 200, { cloud: cloudSummary(session.prof), organizations: [], capabilities: capabilities() })
  }

  if (route === 'POST /v1/desktop/auth/profile') {
    if (!session) return send(res, 401, { error: 'unauthorized' })
    return send(res, 200, await sessionResponse(session.prof))
  }

  if (route === 'POST /v1/desktop/auth/relay-token') {
    if (!session) return send(res, 401, { error: 'unauthorized' })
    const body = await readJson(req)
    const relayHostId = String(body.relayHostId ?? '')
    const publicKey = Buffer.from(String(body.hostPublicKeyB64 ?? ''), 'base64')
    // The relay host id is derived from the host key; refuse tokens for an id the caller cannot own.
    if (
      !/^[A-Za-z0-9_-]{16}$/.test(relayHostId) ||
      publicKey.length !== 32 ||
      b64url(sha256(publicKey)).slice(0, 16) !== relayHostId
    ) {
      return send(res, 400, { error: 'invalid_relay_host' })
    }
    const exp = nowS() + RELAY_TOKEN_TTL_S
    const relayToken = await new SignJWT({ prof: session.prof, relayHostId, purpose: 'host-control' })
      .setProtectedHeader({ alg: 'ES256', kid: relayPrivateJwk.kid })
      .setSubject(USER_ID)
      .setIssuer(ISSUER)
      .setAudience('orca-relay')
      .setIssuedAt()
      .setExpirationTime(exp)
      .sign(relayPrivateKey)
    return send(res, 200, { relayToken, expiresAt: exp * 1000 })
  }

  return send(res, 404, { error: 'not_found' })
}

createServer((req, res) => {
  handle(req, res).catch((error) => {
    if (!res.headersSent) send(res, error.status ?? 500, { error: error.status ? error.message : 'internal_error' })
    if (!error.status) console.error('[orca-auth]', error)
  })
}).listen(PORT, () => console.log(`[orca-auth] listening on :${PORT}, issuer ${ISSUER}`))
