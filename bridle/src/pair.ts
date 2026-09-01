/**
 * Making a machine claimable by a phone.
 *
 * Two paths, one outcome. Scanning the QR is the default because it carries the
 * machine's static key directly, which is what makes a hostile Relay
 * impossible rather than merely unlikely. Typing the short code exists because
 * some people will be pairing an iPad, or a phone whose camera is covered by a
 * corporate policy, and telling them "get a different device" is not a product.
 */

import {
  deviceIdFor,
  encodePairingLink,
  signPairOffer,
  type PairingBundle,
} from '@rowel/protocol'
import { openPairingOffer, signingKeys, staticKeys, type BridleState } from './identity.ts'

/** Everything the operator needs to show, in the three forms a person might use. */
export interface Invitation {
  /** The full bundle, for the QR. */
  bundle: PairingBundle
  /** `rowel://pair#…` deep link the QR encodes. */
  link: string
  /** Typed alternative, e.g. `KTPQ-3WRM`. */
  code: string
  /** Epoch milliseconds after which the invitation stops working. */
  expiresAt: number
}

/**
 * Open a pairing invitation for this machine.
 * @param state - loaded state; the offer is recorded and persisted.
 * @param direct - LAN tunnel addresses to advertise, if the daemon has any.
 * @returns the invitation in all three forms.
 */
export function createInvitation(state: BridleState, direct: string[] = []): Invitation {
  const offer = openPairingOffer(state)
  const bundle: PairingBundle = {
    v: 1,
    relay: state.relayUrl,
    ...(direct.length > 0 ? { direct } : {}),
    device: state.deviceId,
    key: staticKeys(state).publicKey.toString('base64url'),
    token: offer.token,
    name: state.machineName,
  }
  return { bundle, link: encodePairingLink(bundle), code: offer.code, expiresAt: offer.expiresAt }
}

/**
 * Hand the invitation to the Relay so a typed short code can fetch it.
 *
 * The Relay learns the machine's static key here, which is exactly why the
 * short-code path ends in a six-digit confirmation on both screens: a Relay
 * that substituted its own key would produce a different number.
 * @param state - loaded state, for the signing identity.
 * @param invitation - the invitation to publish.
 * @throws {@link Error} when the Relay refuses the offer.
 */
export async function publishInvitation(state: BridleState, invitation: Invitation): Promise<void> {
  const keys = signingKeys(state)
  const response = await fetch(new URL('/v1/pair/offer', toHttpUrl(state.relayUrl)), {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({
      code: invitation.code,
      device: deviceIdFor(keys.publicKey),
      key: keys.publicKey.toString('base64url'),
      signature: signPairOffer(keys.privateKey, invitation.code),
      bundle: invitation.bundle,
      expiresAt: invitation.expiresAt,
    }),
    signal: AbortSignal.timeout(10_000),
  })
  if (!response.ok) {
    throw new Error(`relay refused the pairing offer (HTTP ${String(response.status)})`)
  }
}

/**
 * Normalize a Relay base URL to an HTTP scheme.
 * @param base - an `http(s)://` or `ws(s)://` URL.
 * @returns the same origin with an HTTP scheme.
 */
export function toHttpUrl(base: string): string {
  const url = new URL(base)
  if (url.protocol === 'ws:') url.protocol = 'http:'
  else if (url.protocol === 'wss:') url.protocol = 'https:'
  return url.toString()
}
