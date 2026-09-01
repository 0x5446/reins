/**
 * What the Relay concludes from Apple's answer, and what it does about it.
 *
 * This is the only place in the system that can tell a Bridle to throw away a
 * push address, and it had no tests at all. That is how a real one got in: the
 * loop was documented as requiring both hosts to call a token bad before
 * believing it, and nothing was recording whether the first host had ever
 * answered — so a single failed connection to `api.push.apple.com` turned
 * sandbox's routine refusal of a live production token into a death
 * certificate, and the Mac forgot a working phone.
 *
 * The failures here are all silent by nature. Nobody sees a push that does not
 * arrive, so the only thing standing between a wrong branch and a phone that
 * quietly stops buzzing is this file.
 *
 * `fetch` is stubbed rather than reached. What is under test is the reasoning
 * about Apple's replies, not Apple.
 */

import assert from 'node:assert/strict'
import test from 'node:test'
import { generateKeyPairSync } from 'node:crypto'
import { forgetProviderToken, wake } from '../src/apns.ts'

const PRODUCTION = 'https://api.push.apple.com'
const SANDBOX = 'https://api.sandbox.push.apple.com'
const TOKEN = 'a'.repeat(64)

/** A real P-256 key, because `wake` genuinely signs before it sends. */
const KEY = generateKeyPairSync('ec', { namedCurve: 'P-256' })
  .privateKey.export({ type: 'pkcs8', format: 'pem' })

/** A configured environment; individual tests blank out what they are testing. */
function env(overrides = {}) {
  return {
    ROWEL_APNS_KEY: KEY,
    ROWEL_APNS_KEY_ID: 'ABCDE12345',
    ROWEL_APNS_TEAM_ID: 'FGHIJ67890',
    ROWEL_APNS_TOPIC: 'ai.novabox.rowel',
    ...overrides,
  }
}

/**
 * Answer each host however the test says, and record who was asked.
 * @param {Record<string, {status: number, reason?: string} | Error>} byHost - keyed by host prefix.
 * @returns {{asked: string[], restore: () => void}} the hosts tried, in order.
 */
function stubFetch(byHost) {
  const real = globalThis.fetch
  const asked = []
  globalThis.fetch = async (url) => {
    const host = String(url).startsWith(PRODUCTION) ? PRODUCTION : SANDBOX
    asked.push(host)
    const answer = byHost[host]
    if (answer === undefined) throw new Error(`test did not say what ${host} answers`)
    if (answer instanceof Error) throw answer
    return new Response(
      answer.reason === undefined ? '' : JSON.stringify({ reason: answer.reason }),
      { status: answer.status },
    )
  }
  return { asked, restore: () => { globalThis.fetch = real } }
}

test.beforeEach(() => { forgetProviderToken() })

test('a production token accepted by production is not asked about twice', async (t) => {
  const stub = stubFetch({ [PRODUCTION]: { status: 200 } })
  t.after(stub.restore)
  assert.deepEqual(await wake(env(), { token: TOKEN }), { ok: true })
  assert.deepEqual(stub.asked, [PRODUCTION], 'sandbox was troubled for nothing')
})

test('a development token falls back to sandbox and is delivered', async (t) => {
  const stub = stubFetch({
    [PRODUCTION]: { status: 400, reason: 'BadDeviceToken' },
    [SANDBOX]: { status: 200 },
  })
  t.after(stub.restore)
  assert.deepEqual(await wake(env(), { token: TOKEN }), { ok: true })
  assert.deepEqual(stub.asked, [PRODUCTION, SANDBOX])
})

test('a token both hosts refuse is dead', async (t) => {
  const stub = stubFetch({
    [PRODUCTION]: { status: 400, reason: 'BadDeviceToken' },
    [SANDBOX]: { status: 400, reason: 'BadDeviceToken' },
  })
  t.after(stub.restore)
  const outcome = await wake(env(), { token: TOKEN })
  assert.equal(outcome.ok, false)
  assert.equal(outcome.reason, 'dead')
})

test('sandbox alone cannot condemn a token production never saw', async (t) => {
  // The bug this file was written for. Production is unreachable for a moment;
  // sandbox says what it says about every production token there is. Reporting
  // that as `dead` makes the Bridle delete an address that works, and the phone
  // goes quiet until its owner happens to open the app.
  const stub = stubFetch({
    [PRODUCTION]: new Error('connection reset'),
    [SANDBOX]: { status: 400, reason: 'BadDeviceToken' },
  })
  t.after(stub.restore)
  const outcome = await wake(env(), { token: TOKEN })
  assert.equal(outcome.ok, false)
  assert.equal(outcome.reason, 'refused', 'a working token was reported as gone')
  assert.match(outcome.detail, /production was never reached/u)
})

test('410 is believed on the spot', async (t) => {
  // Unregistered is unambiguous — the app was deleted. There is nothing sandbox
  // could add, and asking would only spend a request.
  const stub = stubFetch({ [PRODUCTION]: { status: 410, reason: 'Unregistered' } })
  t.after(stub.restore)
  const outcome = await wake(env(), { token: TOKEN })
  assert.equal(outcome.reason, 'dead')
  assert.deepEqual(stub.asked, [PRODUCTION])
})

test('a rate limit is not a death sentence', async (t) => {
  // Everything that is not a 200 used to come back as one undifferentiated
  // refusal, and the Switchboard passed that on as "forget this token".
  const stub = stubFetch({ [PRODUCTION]: { status: 429, reason: 'TooManyRequests' } })
  t.after(stub.restore)
  const outcome = await wake(env(), { token: TOKEN })
  assert.equal(outcome.reason, 'refused')
  assert.deepEqual(stub.asked, [PRODUCTION], 'a throttled Apple was asked twice')
})

test('an expired signing key is reported as ours, not as the phone\'s', async (t) => {
  const stub = stubFetch({ [PRODUCTION]: { status: 403, reason: 'ExpiredProviderToken' } })
  t.after(stub.restore)
  assert.equal((await wake(env(), { token: TOKEN })).reason, 'refused')
})

test('half a configuration is louder than none', async (t) => {
  const stub = stubFetch({})
  t.after(stub.restore)

  const none = await wake({}, { token: TOKEN })
  assert.equal(none.reason, 'unconfigured')
  assert.match(none.detail, /not configured/u)

  // Someone set three secrets and stopped. Every push disappears until they
  // finish, and "push is not configured" would read as a deliberate choice.
  const half = await wake(env({ ROWEL_APNS_TOPIC: undefined }), { token: TOKEN })
  assert.equal(half.reason, 'unconfigured')
  assert.match(half.detail, /half-configured/u)

  assert.deepEqual(stub.asked, [], 'Apple was called without a complete configuration')
})

test('a malformed token is refused without troubling Apple', async (t) => {
  const stub = stubFetch({})
  t.after(stub.restore)
  assert.equal((await wake(env(), { token: 'not-hex' })).reason, 'dead')
  assert.deepEqual(stub.asked, [])
})

test('the machine name reaches the banner and nothing else does', async (t) => {
  let sent
  const real = globalThis.fetch
  globalThis.fetch = async (_url, init) => { sent = JSON.parse(init.body); return new Response('', { status: 200 }) }
  t.after(() => { globalThis.fetch = real })

  await wake(env(), { token: TOKEN, machine: 'Pocket Mac' })
  assert.match(sent.aps.alert.body, /Pocket Mac/u)
  // The whole privacy claim in one assertion: whatever the agent wanted is not
  // in this payload, because there is no field it could have arrived in.
  assert.deepEqual(Object.keys(sent), ['aps'])
  assert.deepEqual(Object.keys(sent.aps).sort(), ['alert', 'interruption-level', 'sound'])
})

test('the signing token is minted once and reused', async (t) => {
  // Apple rejects a provider that mints these more than once every twenty
  // minutes, and a cold Worker is exactly where several requests arrive at once.
  const auths = []
  const real = globalThis.fetch
  globalThis.fetch = async (_url, init) => {
    auths.push(init.headers.authorization)
    return new Response('', { status: 200 })
  }
  t.after(() => { globalThis.fetch = real })

  await Promise.all([
    wake(env(), { token: TOKEN }),
    wake(env(), { token: TOKEN }),
    wake(env(), { token: TOKEN }),
  ])
  assert.equal(new Set(auths).size, 1, 'concurrent wakes each signed their own token')
})
