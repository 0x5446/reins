#!/usr/bin/env node
/**
 * Put the dsh web UI on this Mac's Wi-Fi address, for looking at it on a phone.
 *
 *   node scripts/lan-webui.mjs            # http://<your-lan-ip>:3081
 *
 * A throwaway for answering one question — "how good is the web UI on a phone"
 * — and not part of the product. Rowel exists precisely so that this is not how
 * anyone reaches their harness.
 *
 * **Read this before running it.** dsh executes shell commands. Binding it to a
 * network interface hands remote code execution to everything on that Wi-Fi,
 * with no authentication of any kind — no password, no token, nothing. On a
 * home network that is a calculated risk for a few minutes. On a café, an
 * office, or any network with guests on it, it is not a risk, it is a mistake.
 * Ctrl-C when you are done looking.
 *
 * Why a proxy rather than `dsh --trusted-host`: that flag needs dsh restarted,
 * which drops every running session. This rewrites the Host header on the way
 * through instead, so dsh keeps believing it is being spoken to over loopback —
 * which, from its side, it is.
 */

import { createServer, request } from 'node:http'
import { connect } from 'node:net'
import { networkInterfaces } from 'node:os'

const TARGET_HOST = '127.0.0.1'
const TARGET_PORT = Number(process.env.DSH_PORT ?? 3080)
const LISTEN_PORT = Number(process.env.PORT ?? 3081)

const server = createServer((incoming, reply) => {
  const proxied = request(
    {
      host: TARGET_HOST,
      port: TARGET_PORT,
      path: incoming.url,
      method: incoming.method,
      // The whole trick. dsh's fence checks the Host header, not the socket, so
      // presenting loopback is enough — and honest, since the connection it
      // actually receives is one.
      headers: { ...incoming.headers, host: `${TARGET_HOST}:${TARGET_PORT}` },
    },
    (answer) => {
      reply.writeHead(answer.statusCode ?? 502, answer.headers)
      answer.pipe(reply)
    },
  )
  proxied.on('error', (error) => {
    reply.writeHead(502, { 'content-type': 'text/plain' })
    reply.end(`dsh did not answer: ${error.message}\n`)
  })
  incoming.pipe(proxied)
})

// The event streams are WebSockets, and a UI without them looks loaded and is
// frozen — which would answer the question wrongly.
server.on('upgrade', (incoming, socket, head) => {
  const upstream = connect(TARGET_PORT, TARGET_HOST, () => {
    const headers = { ...incoming.headers, host: `${TARGET_HOST}:${TARGET_PORT}` }
    const lines = Object.entries(headers).map(([key, value]) => `${key}: ${value}`)
    upstream.write(`${incoming.method} ${incoming.url} HTTP/1.1\r\n${lines.join('\r\n')}\r\n\r\n`)
    if (head.length > 0) upstream.write(head)
    upstream.pipe(socket)
    socket.pipe(upstream)
  })
  upstream.on('error', () => socket.destroy())
  socket.on('error', () => upstream.destroy())
})

server.listen(LISTEN_PORT, '0.0.0.0', () => {
  const addresses = Object.values(networkInterfaces())
    .flat()
    .filter(entry => entry?.family === 'IPv4' && !entry.internal)
    .map(entry => entry.address)

  process.stdout.write('\n  dsh web UI is on your Wi-Fi:\n\n')
  for (const address of addresses) process.stdout.write(`    http://${address}:${LISTEN_PORT}\n`)
  process.stdout.write(
    '\n  Anyone on this network can now run commands on this Mac.\n' +
    '  Ctrl-C when you are done.\n\n',
  )
})
