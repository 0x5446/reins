/**
 * The Bridle as a library, for the end-to-end tests and for embedding it in
 * another process. The CLI in `cli.ts` is a thin shell over exactly this.
 */

export { BridleCore, type DshStatus } from './core.ts'
export { DirectServer, DIRECT_PATH, localAddresses, dialableAddresses } from './direct-server.ts'
export { DshClient, assertLoopback, type DshHealth, type DshResult } from './dsh/client.ts'
export { ensureDsh, portOpen, probeDsh, type DiscoveredDsh } from './dsh/discovery.ts'
export { EventLog, type LoggedEvent, type ReplayResult } from './tunnel/event-log.ts'
export { TunnelSession, type SessionOptions, type TunnelTransport } from './tunnel/session.ts'
export { RelayClient, toWebSocketUrl, type RelayState } from './relay-client.ts'
export { createInvitation, publishInvitation, toHttpUrl, type Invitation } from './pair.ts'
export { installService, uninstallService, serviceLogPath, SERVICE_LABEL } from './service.ts'
export { clearRuntime, readRuntime, writeRuntime, type RuntimeInfo } from './runtime.ts'
export {
  DEFAULT_DSH_URL,
  DEFAULT_RELAY_URL,
  acceptPeer,
  findPeer,
  loadState,
  offerAccepts,
  openPairingOffer,
  reinsHome,
  revokePeer,
  saveState,
  signingKeys,
  statePath,
  staticKeys,
  touchPeer,
  type BridleState,
  type PairedPeer,
  type PairingOffer,
} from './identity.ts'
