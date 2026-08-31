/**
 * Binding by home: the DSH_HOME is the instance's identity, and a home that
 * declares its own address is the strongest anchor a binding can have — the
 * declared port doubles as a single-instance lock (a second boot from the
 * same home dies on EADDRINUSE), so the URL derived here names the world
 * itself, not whichever process answered this morning.
 */

import assert from 'node:assert/strict'
import test from 'node:test'
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { dshHomeUrl } from '@reins/bridle'

function home(t, patch) {
  const root = mkdtempSync(join(tmpdir(), 'reins-dshhome-'))
  t.after(() => { rmSync(root, { recursive: true, force: true }) })
  if (patch !== undefined) {
    mkdirSync(join(root, 'profiles', 'web'), { recursive: true })
    writeFileSync(join(root, 'profiles', 'web', 'cordis.patch.yml'), patch)
  }
  return root
}

test('a home that declares its address is read verbatim', (t) => {
  const root = home(t, `# demo patch
- id: web
  config:
    searchProvider: exa

- id: webserver
  config:
    host: 127.0.0.1
    port: 3081

- id: llm-deepseek
  disabled: true
`)
  assert.equal(dshHomeUrl(root), 'http://127.0.0.1:3081')
})

test('a home that does not declare an address yields nothing, not a guess', (t) => {
  // Guessing the default port here would defeat the whole point: an
  // undeclared home has no identity-level address, and the caller must say
  // so instead of silently binding to wherever 3080 points today.
  assert.equal(dshHomeUrl(home(t, `- id: web\n  config:\n    searchProvider: exa\n`)), undefined)
  assert.equal(dshHomeUrl(home(t)), undefined, 'no patch file at all')
  assert.equal(dshHomeUrl(home(t, `- id: webserver\n  config:\n    port: 3081\n`)), undefined,
    'half a declaration (no host) is not a declaration')
})

test('a computed port is refused, not evaluated', (t) => {
  // The stock composed value is a !!js expression. Evaluating repo-supplied
  // code inside the Bridle is out of the question; a home using expressions
  // simply has not declared a literal address.
  const root = home(t, `- id: webserver
  config:
    host: 127.0.0.1
    port: !!js ctx.webStartup.port ?? 3080
`)
  assert.equal(dshHomeUrl(root), undefined)
})
