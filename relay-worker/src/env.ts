/** Bindings from `wrangler.jsonc`, in one place so every module agrees on them. */

import type { Exchange } from './exchange.ts'
import type { PairCode } from './pair-code.ts'
import type { Switchboard } from './switchboard.ts'

/** What the Worker and the Durable Objects are handed at construction. */
export interface Env {
  /** One per live Bridle connection. */
  SWITCHBOARD: DurableObjectNamespace<Switchboard>
  /** The single directory, census, and rate limiter. */
  EXCHANGE: DurableObjectNamespace<Exchange>
  /** One per outstanding short code. */
  PAIR_CODE: DurableObjectNamespace<PairCode>
  /** Global machine ceiling; see `limits.ts`. */
  ROWEL_MAX_MACHINES?: string
  /** Seconds between directory sweeps; only a test ever sets it. */
  ROWEL_SWEEP_INTERVAL_MS?: string
  /** Global circuit ceiling; see `limits.ts`. */
  ROWEL_MAX_CIRCUITS?: string
  // APNs. All four or none: any missing and the Relay simply never wakes
  // anyone, which is the state it shipped in and every other function tolerates.
  /** The `.p8` contents. A secret — `wrangler secret put`, never a var. */
  ROWEL_APNS_KEY?: string
  /** The APNs key's ten-character id. */
  ROWEL_APNS_KEY_ID?: string
  /** The paid team's ten-character id. */
  ROWEL_APNS_TEAM_ID?: string
  /** The app's bundle id, which APNs calls the topic. */
  ROWEL_APNS_TOPIC?: string
}

/** The name of the one Exchange. There is exactly one, and this is why. */
export const EXCHANGE_NAME = 'exchange'

/**
 * Reach the Exchange.
 * @param env - the Worker environment.
 * @returns a stub for the single Exchange object.
 */
export function exchangeOf(env: Env): DurableObjectStub<Exchange> {
  return env.EXCHANGE.get(env.EXCHANGE.idFromName(EXCHANGE_NAME))
}
