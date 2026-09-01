#!/usr/bin/env node
/**
 * Relay entry point. Reads its whole configuration from the environment so it
 * drops into any container platform without a config file.
 */

import { RelayServer } from './server.ts'

const installScript = process.env['ROWEL_INSTALL_SCRIPT']

const server = new RelayServer({
  port: Number(process.env['PORT'] ?? '8787'),
  host: process.env['HOST'] ?? '0.0.0.0',
  log: (message: string) => { process.stdout.write(`${message}\n`) },
  // An empty value turns the route off; unset falls back to the install.sh in
  // the checkout, which is what a normal deployment wants.
  ...(installScript === undefined ? {} : { installScript: installScript === '' ? null : installScript }),
})

await server.listen()

for (const signal of ['SIGINT', 'SIGTERM'] as const) {
  process.on(signal, () => {
    void server.close().then(() => { process.exit(0) })
  })
}
