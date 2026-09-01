#!/usr/bin/env node
/**
 * A one-file client for the App Store Connect API.
 *
 * The web session is the only other way to reach these settings, and it
 * expires in the middle of things; a key does not. Everything here is what
 * `release.sh` cannot do: look at what was uploaded, attach a build to a
 * version, answer the declarations a submission is blocked on.
 *
 * Usage:
 *   node ios/asc.mjs builds                      recent builds for the app
 *   node ios/asc.mjs version                     the in-flight version
 *   node ios/asc.mjs attach <buildId>            put that build on the version
 *   node ios/asc.mjs ratings                     current age-rating answers
 *   node ios/asc.mjs submit                      send the version to review
 *   node ios/asc.mjs get <path>                  any GET, path after /v1
 *   node ios/asc.mjs patch <path> <json>         any PATCH
 *   node ios/asc.mjs post <path> <json>          any POST
 *
 * Environment: ASC_KEY_ID, ASC_ISSUER_ID, ASC_KEY_PATH, and ROWEL_APP_ID.
 */

import { createSign } from 'node:crypto'
import { readFileSync } from 'node:fs'

const KEY_ID = process.env['ASC_KEY_ID']
const ISSUER = process.env['ASC_ISSUER_ID']
const KEY_PATH = process.env['ASC_KEY_PATH']
const APP_ID = process.env['ROWEL_APP_ID'] ?? '6807263060'

for (const [name, value] of [['ASC_KEY_ID', KEY_ID], ['ASC_ISSUER_ID', ISSUER], ['ASC_KEY_PATH', KEY_PATH]]) {
  if (value === undefined || value === '') {
    process.stderr.write(`asc: $${name} is not set\n`)
    process.exit(1)
  }
}

const base64url = (input) => Buffer.from(input).toString('base64url')

/**
 * Mint a token for this call.
 *
 * Signed ES256 in JOSE form — `r || s`, not the DER sequence Node produces by
 * default. A DER signature is accepted by nothing and rejected with a bare
 * 401, which reads like a bad key.
 * @returns {string} the bearer token.
 */
function token() {
  const now = Math.floor(Date.now() / 1000)
  const header = base64url(JSON.stringify({ alg: 'ES256', kid: KEY_ID, typ: 'JWT' }))
  // Twenty minutes is the ceiling Apple accepts; anything longer is a 401.
  const claims = base64url(JSON.stringify({
    iss: ISSUER, iat: now, exp: now + 19 * 60, aud: 'appstoreconnect-v1',
  }))
  const signer = createSign('SHA256')
  signer.update(`${header}.${claims}`)
  const signature = signer.sign(
    { key: readFileSync(KEY_PATH, 'utf8'), dsaEncoding: 'ieee-p1363' })
  return `${header}.${claims}.${signature.toString('base64url')}`
}

/**
 * One API call.
 * @param {string} method - HTTP method.
 * @param {string} path - path after the version prefix, e.g. `/v1/builds`.
 * @param {unknown} [body] - JSON body for writes.
 * @returns {Promise<any>} the parsed response, or `{}` for a 204.
 */
async function call(method, path, body) {
  const response = await fetch(`https://api.appstoreconnect.apple.com${path}`, {
    method,
    headers: {
      authorization: `Bearer ${token()}`,
      'content-type': 'application/json',
    },
    body: body === undefined ? undefined : JSON.stringify(body),
  })
  const text = await response.text()
  if (!response.ok) {
    process.stderr.write(`asc: ${method} ${path} -> ${String(response.status)}\n${text.slice(0, 900)}\n`)
    process.exit(1)
  }
  return text.length === 0 ? {} : JSON.parse(text)
}

const [command, ...rest] = process.argv.slice(2)

/** The version currently being prepared, which is the one a build attaches to. */
async function inflight() {
  const versions = await call('GET',
    `/v1/apps/${APP_ID}/appStoreVersions?limit=5&fields[appStoreVersions]=versionString,appStoreState,platform`)
  const version = versions.data.find(v => v.attributes.appStoreState !== 'READY_FOR_SALE') ?? versions.data[0]
  if (version === undefined) {
    process.stderr.write('asc: no app store version to work with\n')
    process.exit(1)
  }
  return version
}

switch (command) {
  case 'builds': {
    const builds = await call('GET',
      `/v1/builds?filter[app]=${APP_ID}&limit=10&sort=-uploadedDate&fields[builds]=version,processingState,uploadedDate,expired`)
    for (const build of builds.data) {
      const a = build.attributes
      process.stdout.write(`${build.id}  build ${a.version.padEnd(6)} ${String(a.processingState).padEnd(12)} ${a.uploadedDate}\n`)
    }
    break
  }
  case 'version': {
    const version = await inflight()
    const build = await call('GET', `/v1/appStoreVersions/${version.id}/build?fields[builds]=version,processingState`)
      .catch(() => ({ data: null }))
    process.stdout.write(`${version.id}  ${version.attributes.versionString}  ${version.attributes.appStoreState}\n`)
    process.stdout.write(`build: ${build.data === null ? 'none attached' : `${build.data.attributes.version} (${build.data.attributes.processingState})`}\n`)
    break
  }
  case 'attach': {
    const [buildId] = rest
    if (buildId === undefined) { process.stderr.write('asc: attach <buildId>\n'); process.exit(1) }
    const version = await inflight()
    await call('PATCH', `/v1/appStoreVersions/${version.id}`, {
      data: {
        type: 'appStoreVersions', id: version.id,
        relationships: { build: { data: { type: 'builds', id: buildId } } },
      },
    })
    process.stdout.write(`attached ${buildId} to ${version.attributes.versionString}\n`)
    break
  }
  case 'ratings': {
    const declaration = await call('GET', `/v1/apps/${APP_ID}/ageRatingDeclaration`)
    process.stdout.write(`${declaration.data.id}\n${JSON.stringify(declaration.data.attributes, null, 2)}\n`)
    break
  }
  case 'submit': {
    // Three calls, not one. A submission is a container, the version is an
    // item inside it, and `submitted` is the button — Apple models "Add for
    // Review" and "Submit to App Review" as two separate acts, and so does
    // this. Anything already open is reused: a second container for the same
    // app is rejected, and the error names neither the existing one nor why.
    const version = await inflight()
    const open = await call('GET', `/v1/apps/${APP_ID}/reviewSubmissions?filter[state]=READY_FOR_REVIEW`)
    const submission = open.data[0] ?? (await call('POST', '/v1/reviewSubmissions', {
      data: {
        type: 'reviewSubmissions', attributes: { platform: 'IOS' },
        relationships: { app: { data: { type: 'apps', id: APP_ID } } },
      },
    })).data
    const items = await call('GET', `/v1/reviewSubmissions/${submission.id}/items`)
    if (items.data.length === 0) {
      await call('POST', '/v1/reviewSubmissionItems', {
        data: {
          type: 'reviewSubmissionItems',
          relationships: {
            reviewSubmission: { data: { type: 'reviewSubmissions', id: submission.id } },
            appStoreVersion: { data: { type: 'appStoreVersions', id: version.id } },
          },
        },
      })
    }
    const sent = await call('PATCH', `/v1/reviewSubmissions/${submission.id}`, {
      data: { type: 'reviewSubmissions', id: submission.id, attributes: { submitted: true } },
    })
    process.stdout.write(`${version.attributes.versionString} -> ${sent.data.attributes.state}\n`)
    break
  }
  case 'get':
    process.stdout.write(`${JSON.stringify(await call('GET', rest[0]), null, 2)}\n`)
    break
  case 'post':
    process.stdout.write(`${JSON.stringify(await call('POST', rest[0], JSON.parse(rest[1])), null, 2)}\n`)
    break
  case 'patch':
    process.stdout.write(`${JSON.stringify(await call('PATCH', rest[0], JSON.parse(rest[1])), null, 2)}\n`)
    break
  default:
    process.stderr.write('asc: builds | version | attach <id> | ratings | submit | get <path> | patch <path> <json> | post <path> <json>\n')
    process.exit(1)
}
