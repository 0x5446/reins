/**
 * The numbers the Relay is held to.
 *
 * The first block is protocol (docs/protocol.md §6.2): the Bridle and the app
 * are already shipped against these, so they are constants here rather than
 * configuration — loosening one makes abuse cheaper without telling anybody.
 * The second block is capacity, which depends on what you are willing to pay
 * for, so it comes from the environment.
 */

/** How long a Bridle has to answer the registration challenge. */
export const REGISTER_TIMEOUT_MS = 15_000

/** Phones one machine may hold at once. */
export const MAX_CIRCUITS_PER_MACHINE = 8

/** Unclaimed short codes one machine may hold at once. */
export const MAX_OFFERS_PER_DEVICE = 3

/** Ceiling on how long the Relay will hold a pairing offer. */
export const OFFER_MAX_TTL_MS = 15 * 60 * 1000

/** Largest `POST /v1/pair/offer` body that will be read. */
export const MAX_BODY_BYTES = 64 * 1024

/**
 * Largest tunnel message this substrate can carry, in bytes.
 *
 * **Lower than the protocol's own ceiling, and not by choice.** docs/protocol.md
 * §6.2 says 64 MiB; the Workers runtime closes any WebSocket that receives a
 * message over 32 MiB with a 1009 before a single line of this code runs, so
 * that number cannot be honoured here. Nothing below enforces it — the
 * enforcement is the runtime's, and the Relay only gets to describe it.
 *
 * @see https://developers.cloudflare.com/workers/runtime-apis/websockets/
 */
export const RUNTIME_MAX_FRAME_BYTES = 32 * 1024 * 1024

/** Machines the whole Relay will hold at once, when `REINS_MAX_MACHINES` is unset. */
export const DEFAULT_MAX_MACHINES = 1_000

/** Circuits across every machine, when `REINS_MAX_CIRCUITS` is unset. */
export const DEFAULT_MAX_CIRCUITS = 4_000

/** Burst and refill for `GET /v1/pair/claim`, per caller address. */
export const CLAIM_LIMIT = { capacity: 10, refillPerSecond: 0.2 } as const

/** Burst and refill for `WS /v1/app`, per caller address. */
export const ATTACH_LIMIT = { capacity: 30, refillPerSecond: 1 } as const

/**
 * Read a positive integer out of a Worker variable.
 * @param raw - the configured value, if any.
 * @param fallback - used when unset, empty, or not a positive integer.
 * @returns the limit to enforce.
 */
export function positiveInt(raw: string | undefined, fallback: number): number {
  const value = Number(raw)
  return Number.isInteger(value) && value > 0 ? value : fallback
}
