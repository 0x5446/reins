#!/usr/bin/env node
/**
 * Relay entry point. Reads its whole configuration from the environment so it
 * drops into any container platform without a config file.
 */

import { RelayServer } from './server.ts'

const server = new RelayServer({
  port: Number(process.env['PORT'] ?? '8787'),
  host: process.env['HOST'] ?? '0.0.0.0',
  log: (message: string) => { process.stdout.write(`${message}\n`) },
})

await server.listen()

for (const signal of ['SIGINT', 'SIGTERM'] as const) {
  process.on(signal, () => {
    void server.close().then(() => { process.exit(0) })
  })
}
