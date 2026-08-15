/**
 * The Reins Relay: a content-blind switchboard between phones and the Bridles
 * on people's machines — the same one `relay/` implements, on Workers.
 *
 * It exists for one reason. A laptop behind NAT cannot accept an inbound
 * connection, so the Bridle dials out and holds a socket, and the Relay hands
 * phones onto it. Everything it forwards is a Noise ciphertext it has no key
 * for. It stores nothing but a device id, a socket, and a display name.
 *
 * This file is routing and nothing else: no state, no sockets held open, no
 * traffic. It decides which Durable Object a request belongs to and gets out of
 * the way. The three objects behind it are the Switchboard (one per live Bridle
 * connection, holds the sockets), the Exchange (one, globally: the directory,
 * the census, the ceilings, the rate limits), and PairCode (one per outstanding
 * short code).
 *
 * Endpoints, unchanged from the Node Relay:
 * - `GET  /healthz`               liveness and coarse counters
 * - `GET  /v1/machine/:deviceId`  is that machine online, and what is it called
 * - `POST /v1/pair/offer`         a Bridle parks a short-code pairing bundle
 * - `GET  /v1/pair/claim?code=`   an app collects one, once
 * - `WS   /v1/bridle`             a Bridle registers and carries muxed circuits
 * - `WS   /v1/app?device=`        a phone attaches as one circuit
 */

import { exchangeOf, type Env } from './env.ts'
import { deviceIdFor, normalizeShortCode, verifyPairOffer } from './identity.ts'
import { MAX_BODY_BYTES, OFFER_MAX_TTL_MS } from './limits.ts'
import { fromBase64Url } from './wire.ts'

export { Exchange } from './exchange.ts'
export { PairCode } from './pair-code.ts'
export { Switchboard } from './switchboard.ts'

export default {
  /**
   * Route one request.
   * @param request - the incoming request.
   * @param env - the Durable Object bindings and capacity variables.
   * @param ctx - used to finish bookkeeping after the response goes out.
   * @returns the response.
   */
  async fetch(request: Request, env: Env, ctx: ExecutionContext): Promise<Response> {
    const url = new URL(request.url)

    if (request.method === 'GET' && url.pathname === '/healthz') {
      return json(200, await exchangeOf(env).health())
    }

    if (request.method === 'GET' && url.pathname === '/install') {
      // Not served here, and not a gap. The installer is an edge Redirect Rule
      // to the repository (docs/deployment.md §2) precisely so that a Relay
      // compromise cannot become a supply-chain event; a Worker that answered
      // this would put both back in one trust domain.
      return json(404, { error: 'no installer on this relay' })
    }

    if (request.method === 'GET' && url.pathname.startsWith('/v1/machine/')) {
      const deviceId = decodeURIComponent(url.pathname.slice('/v1/machine/'.length))
      return json(200, await exchangeOf(env).describe(deviceId))
    }

    if (request.method === 'POST' && url.pathname === '/v1/pair/offer') {
      return await postOffer(request, env)
    }

    if (request.method === 'GET' && url.pathname === '/v1/pair/claim') {
      return await claimOffer(url, env, ctx, callerOf(request))
    }

    if (url.pathname === '/v1/bridle') return upgradeBridle(request, env)
    if (url.pathname === '/v1/app') return await upgradeApp(request, env, url)

    return json(404, { error: 'not found' })
  },
} satisfies ExportedHandler<Env>

/**
 * Park a signed pairing bundle under a short code.
 * @param request - the offer.
 * @param env - the bindings.
 * @returns the Relay's answer, in the Node Relay's exact shapes.
 */
async function postOffer(request: Request, env: Env): Promise<Response> {
  const length = Number(request.headers.get('content-length') ?? '0')
  if (length > MAX_BODY_BYTES) return json(400, { error: 'body must be JSON' })
  let body: {
    code?: unknown
    device?: unknown
    key?: unknown
    signature?: unknown
    bundle?: { device?: unknown }
    expiresAt?: unknown
  }
  try {
    body = await request.json()
  } catch {
    return json(400, { error: 'body must be JSON' })
  }
  const { code, device, key, signature, bundle, expiresAt } = body
  if (typeof code !== 'string' || typeof device !== 'string' || typeof key !== 'string'
    || typeof signature !== 'string' || bundle === undefined || typeof expiresAt !== 'number') {
    return json(400, { error: 'code, device, key, signature, bundle, and expiresAt are required' })
  }
  const publicKey = fromBase64Url(key)
  // Both checks matter: the signature proves the key holder authorised this
  // code, and the id check proves the key is the one the device id names.
  if (publicKey === undefined || await deviceIdFor(publicKey) !== device || !await verifyPairOffer(publicKey, code, signature)) {
    return json(403, { error: 'offer is not signed by the machine it names' })
  }
  if (bundle.device !== device) {
    return json(400, { error: 'bundle names a different machine' })
  }

  const normalized = normalizeShortCode(code)
  // Clamped here rather than in the object holding the bundle, so that the
  // machine's slot and the bundle itself always lapse at the same instant.
  const lapses = Math.min(expiresAt, Date.now() + OFFER_MAX_TTL_MS)
  if (!await exchangeOf(env).reserveOffer(device, normalized, lapses)) {
    return json(429, { error: 'too many outstanding offers for this machine' })
  }
  await pairCodeOf(env, normalized).put(device, JSON.stringify(bundle), lapses)
  return json(200, { ok: true })
}

/**
 * Spend a short code.
 * @param url - the request URL, carrying the code.
 * @param env - the bindings.
 * @param ctx - used to return the machine's slot after answering.
 * @param caller - the claimant's address, for rate limiting.
 * @returns the bundle, or a refusal.
 */
async function claimOffer(url: URL, env: Env, ctx: ExecutionContext, caller: string): Promise<Response> {
  const exchange = exchangeOf(env)
  if (!await exchange.claimAllowance(caller)) {
    return json(429, { error: 'too many attempts; wait a moment' })
  }
  const code = normalizeShortCode(url.searchParams.get('code') ?? '')
  const claim = await pairCodeOf(env, code).claim()
  if (!claim.ok) return json(404, { error: 'that code is not valid any more' })
  // Bookkeeping, not correctness: the code is already spent. Making the phone
  // wait for the machine's slot to be returned would add a round trip to the
  // one step of pairing a person is watching.
  ctx.waitUntil(exchange.releaseOffer(claim.device, code))
  // Spliced rather than re-encoded, because the bundle has been an opaque
  // string since it arrived and there is no reason to give this code an
  // opinion about its contents on the way out.
  return raw(200, `{"bundle":${claim.bundle}}`)
}

/**
 * Hand a Bridle's socket to a fresh Switchboard.
 *
 * A new object per connection, because the device id is not knowable yet — it
 * arrives in a signed message after the upgrade (docs/protocol.md §6.1). The
 * Switchboard publishes itself to the Exchange once the signature checks out,
 * and that is how phones find it afterwards.
 * @param request - the upgrade.
 * @param env - the bindings.
 * @returns the 101, or 426.
 */
function upgradeBridle(request: Request, env: Env): Response | Promise<Response> {
  if (request.headers.get('Upgrade')?.toLowerCase() !== 'websocket') {
    return new Response('expected a websocket upgrade', { status: 426 })
  }
  const id = env.SWITCHBOARD.newUniqueId()
  return env.SWITCHBOARD.get(id).fetch(new Request('https://switchboard/bridle', request))
}

/**
 * Put a phone onto the Switchboard holding its machine.
 * @param request - the upgrade.
 * @param env - the bindings.
 * @param url - the request URL, carrying the device id.
 * @returns the 101, or a refusal the app can explain to someone.
 */
async function upgradeApp(request: Request, env: Env, url: URL): Promise<Response> {
  if (request.headers.get('Upgrade')?.toLowerCase() !== 'websocket') {
    return new Response('expected a websocket upgrade', { status: 426 })
  }
  const deviceId = url.searchParams.get('device') ?? ''
  const route = await exchangeOf(env).locate(deviceId, callerOf(request))
  if (!route.ok) return refuse(route.code, route.reason)
  const target = env.SWITCHBOARD.get(env.SWITCHBOARD.idFromString(route.switchboard))
  return await target.fetch(new Request(`https://switchboard/app?device=${encodeURIComponent(deviceId)}`, request))
}

/**
 * Turn a phone away with a reason it can show someone.
 *
 * A completed upgrade that immediately closes, not an HTTP error: the app reads
 * these close codes (`ios/Reins/Net/WebSocketCarrier.swift` turns 4404 into
 * "That Mac is offline"), and a 503 would arrive as an unhelpful transport
 * failure indistinguishable from having no signal.
 * @param code - the close code.
 * @param reason - the text shown to the user.
 * @returns the 101 that carries the refusal.
 */
function refuse(code: number, reason: string): Response {
  const pair = new WebSocketPair()
  pair[1].accept()
  pair[1].close(code, reason)
  return new Response(null, { status: 101, webSocket: pair[0] })
}

/**
 * Reach the object holding one short code.
 * @param env - the bindings.
 * @param code - the normalized short code.
 * @returns its stub.
 */
function pairCodeOf(env: Env, code: string): DurableObjectStub<import('./pair-code.ts').PairCode> {
  return env.PAIR_CODE.get(env.PAIR_CODE.idFromName(code))
}

/**
 * Identify the caller for rate limiting.
 * @param request - the incoming request.
 * @returns the client address, or a shared bucket when there is none to be had.
 */
function callerOf(request: Request): string {
  const direct = request.headers.get('CF-Connecting-IP')
  if (direct !== null && direct.length > 0) return direct
  const forwarded = request.headers.get('X-Forwarded-For')
  return (forwarded?.split(',')[0] ?? 'unknown').trim()
}

/**
 * Answer with JSON, uncacheable.
 *
 * `no-store` is load-bearing rather than habitual: a short code is claimable
 * exactly once, and a cached claim response would make it replayable.
 * @param status - the HTTP status.
 * @param body - the payload.
 * @returns the response.
 */
function json(status: number, body: unknown): Response {
  return raw(status, JSON.stringify(body))
}

/**
 * Answer with a JSON document that is already text.
 * @param status - the HTTP status.
 * @param body - the encoded payload.
 * @returns the response.
 */
function raw(status: number, body: string): Response {
  return new Response(body, {
    status,
    headers: {
      'content-type': 'application/json; charset=utf-8',
      'cache-control': 'no-store',
    },
  })
}
