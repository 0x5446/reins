/**
 * The Relay wire. This is the only protocol the Relay itself understands, and
 * it is deliberately content-blind: the Relay switches opaque byte strings
 * between one Bridle socket and the app sockets attached to it, and can decrypt
 * none of them.
 *
 * A Bridle holds one socket to the Relay and may serve several phones over it,
 * so Bridle-side messages carry a circuit id. The app side needs no framing at
 * all: an app socket *is* one circuit, so it sends and receives raw tunnel
 * bytes.
 *
 * Layout, big-endian: `u8 type | u32 circuit | payload`.
 */

/** Message kinds on the Bridle side of the Relay. */
export const MuxType = {
  /** Relay to Bridle: a phone attached; payload is JSON {@link CircuitInfo}. */
  Open: 0x01,
  /** Either direction: one tunnel carrier message, verbatim. */
  Data: 0x02,
  /** Either direction: the circuit ended; payload is a UTF-8 reason. */
  Close: 0x03,
} as const

/** One {@link MuxType} value. */
export type MuxTypeValue = (typeof MuxType)[keyof typeof MuxType]

/** Header size in bytes. */
export const MUX_HEADER_LENGTH = 5

/** What the Relay can honestly tell a Bridle about a newly attached phone. */
export interface CircuitInfo {
  /** Coarse client hint from the app's query string; not authenticated. */
  client?: string
  /** Relay-side connection age in milliseconds, for diagnostics. */
  at?: number
}

/** A decoded Bridle-side message. */
export interface MuxMessage {
  type: MuxTypeValue
  /** Circuit this message belongs to. */
  circuit: number
  payload: Buffer
}

/**
 * Encode one Bridle-side message.
 * @param type - message kind.
 * @param circuit - circuit id, 32-bit unsigned.
 * @param payload - the body; empty for a bare close.
 * @returns the framed bytes.
 */
export function encodeMux(type: MuxTypeValue, circuit: number, payload: Buffer = Buffer.alloc(0)): Buffer {
  const header = Buffer.allocUnsafe(MUX_HEADER_LENGTH)
  header.writeUInt8(type, 0)
  header.writeUInt32BE(circuit >>> 0, 1)
  return Buffer.concat([header, payload])
}

/**
 * Decode one Bridle-side message.
 * @param bytes - the received frame.
 * @returns the decoded message.
 * @throws {@link Error} when the frame is too short or carries an unknown type.
 */
export function decodeMux(bytes: Buffer): MuxMessage {
  if (bytes.length < MUX_HEADER_LENGTH) throw new Error('relay frame is shorter than its header')
  const type = bytes.readUInt8(0)
  if (type !== MuxType.Open && type !== MuxType.Data && type !== MuxType.Close) {
    throw new Error(`relay frame has unknown type ${String(type)}`)
  }
  return { type, circuit: bytes.readUInt32BE(1), payload: bytes.subarray(MUX_HEADER_LENGTH) }
}
