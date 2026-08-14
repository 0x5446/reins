/**
 * A token bucket per client address.
 *
 * The Relay's two guessable surfaces are the short-code claim and the app
 * attach; both should cost an attacker real time. Everything else is either
 * signature-checked or plain ciphertext switching.
 */

/** One bucket's state. */
interface Bucket {
  tokens: number
  updatedAt: number
}

/** Refill-rate-limited counter keyed by a caller identifier. */
export class RateLimiter {
  private readonly buckets = new Map<string, Bucket>()

  /**
   * @param capacity - burst size.
   * @param refillPerSecond - steady-state rate.
   */
  constructor(private readonly capacity: number, private readonly refillPerSecond: number) {}

  /**
   * Charge one unit against a key.
   * @param key - caller identifier, usually a remote address.
   * @param now - current epoch milliseconds.
   * @returns whether the request may proceed.
   */
  take(key: string, now: number = Date.now()): boolean {
    const bucket = this.buckets.get(key) ?? { tokens: this.capacity, updatedAt: now }
    const elapsed = Math.max(0, now - bucket.updatedAt) / 1000
    bucket.tokens = Math.min(this.capacity, bucket.tokens + elapsed * this.refillPerSecond)
    bucket.updatedAt = now
    if (bucket.tokens < 1) {
      this.buckets.set(key, bucket)
      return false
    }
    bucket.tokens -= 1
    this.buckets.set(key, bucket)
    // Buckets at full capacity carry no information worth remembering.
    if (bucket.tokens >= this.capacity) this.buckets.delete(key)
    return true
  }
}
