/**
 * The session list is the one screen that cannot be paged — dsh returns every
 * session and ignores `limit`, `offset` and `cursor` — so the only lever left
 * is how heavy each row is. On a real machine nine tenths of it was
 * projections the app never reads.
 */

import assert from 'node:assert/strict'
import test from 'node:test'
import { thinRoster } from '@rowel/bridle'

/**
 * A real row, captured from a live dsh and neutralised.
 *
 * Written from the wire rather than from memory on purpose: a fixture invented
 * by hand carried four projections where the real thing carries eleven, and
 * the saving it reported was 69% against a measured 90%. A test that models
 * the payload as lighter than it is understates exactly the problem it exists
 * to guard.
 */
const REAL_ROW = {
    "sessionId": "session-fixture",
    "updatedAt": 1786712206927,
    "running": false,
    "blank": false,
    "cwd": "/Users/someone/code",
    "agentPreset": "cordis",
    "projections": {
      "asOfSeq": 143184,
      "values": {
        "sessionStats": {
          "turns": 2,
          "steps": 72,
          "llmMs": 1998681,
          "toolMs": 79729,
          "ttftMs": 454285,
          "ttftSteps": 70,
          "decodeMs": 1544396,
          "decodeTokens": 135392
        },
        "title": "a conversation",
        "goal": null,
        "tokenUsage": {
          "uncachedInputTokens": 171242,
          "outputTokens": 135392,
          "cacheReadTokens": 8025600,
          "cacheWriteTokens": 0
        },
        "contextPressure": {
          "pressureTokens": 176460,
          "projectedTokens": 176865,
          "contextWindow": 1000000
        },
        "contextBreakdown": {
          "systemTokens": 1511,
          "toolsTokens": 6376,
          "messageTokens": 264369
        },
        "subagentTiming": {
          "settledMs": 0
        },
        "subagent": null,
        "permissions": {
          "options": [
            {
              "value": "read-only",
              "name": "read-only"
            },
            {
              "value": "workspace-write",
              "name": "workspace-write"
            },
            {
              "value": "danger-full-access",
              "name": "danger-full-access"
            }
          ],
          "currentValue": "workspace-write"
        },
        "todos": [
          {
            "content": "Confirm codex-personal exa wiring + locate EXA_API_KEY",
            "status": "completed"
          },
          {
            "content": "Wire web-search-exa into dsh base bundle (source: package.json + cordis.patch.yml + lock)",
            "status": "in_progress"
          },
          {
            "content": "Activate exa in the running dsh web profile (install package + profile patch + key)",
            "status": "pending"
          },
          {
            "content": "Verify composition and report",
            "status": "pending"
          }
        ],
        "plan": {
          "active": false,
          "pending": false
        }
      }
    }
  }

/** That row, with a fresh id so a list of them is not one row repeated. */
function row(id, title) {
  const copy = structuredClone(REAL_ROW)
  copy.sessionId = id
  copy.projections.values.title = title
  return copy
}

test('the row keeps what the app reads and drops what it does not', () => {
  const { value, trimming } = thinRoster({ items: [row('s1', 'a conversation')] })

  const kept = value.items[0]
  assert.deepEqual(kept.projections.values, { title: 'a conversation' })
  // Everything outside `projections.values` is the row itself and stays.
  assert.equal(kept.sessionId, 's1')
  assert.equal(kept.cwd, REAL_ROW.cwd)
  assert.equal(kept.agentPreset, REAL_ROW.agentPreset)
  assert.equal(kept.running, REAL_ROW.running)
  assert.equal(kept.projections.asOfSeq, REAL_ROW.projections.asOfSeq)
  assert.ok(trimming.after < trimming.before)
})

test('it is a keep-list, so a projection dsh adds later is dropped by default', () => {
  const fat = row('s1', 'x')
  fat.projections.values.somethingNew = { invented: 'next year', payload: 'x'.repeat(500) }

  const { value } = thinRoster({ items: [fat] })
  assert.deepEqual(Object.keys(value.items[0].projections.values), ['title'])
})

test('most of a real list is the part nobody reads', () => {
  const items = Array.from({ length: 67 }, (_, index) => row(`s${String(index)}`, 'a conversation'))
  const { trimming } = thinRoster({ items })
  const saved = 1 - trimming.after / trimming.before
  assert.ok(saved > 0.8, `only ${String(Math.round(saved * 100))}% saved; the measured figure was about 90%`)
})

test('anything that is not a session list passes through untouched', () => {
  for (const value of [null, undefined, 42, 'text', {}, { items: 'not an array' }]) {
    const result = thinRoster(value)
    assert.equal(result.value, value)
    assert.equal(result.trimming, undefined)
  }
})

test('a row with no projections survives, since an older dsh may send none', () => {
  const { value, trimming } = thinRoster({ items: [{ sessionId: 's1', updatedAt: 1 }] })
  assert.deepEqual(value.items[0], { sessionId: 's1', updatedAt: 1 })
  assert.equal(trimming, undefined, 'nothing to save is not a saving')
})
