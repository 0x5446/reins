/**
 * The Relay wire, in terms the Workers runtime speaks.
 *
 * `@reins/protocol` already implements all of this, but against `Buffer` and
 * `node:crypto`, neither of which exists here without dragging in a
 * compatibility layer for the sake of four functions. These are the same bytes
 * — docs/protocol.md §5 and §2.4 are the shared authority, and the end-to-end
 * test drives a real Bridle through them, which is what actually proves it.
 */

/** Message kinds on the Bridle side of the Relay (docs/protocol.md §5). */
export const MuxType = {
  /** Relay to Bridle: a phone attached; payload is JSON `CircuitInfo`. */
  Open: 0x01,
  /** Either direction: one tunnel carrier message, verbatim. */
  Data: 0x02,
  /** Either direction: the circuit ended; payload is a UTF-8 reason. */
  Close: 0x03,
} as const

/** One {@link MuxType} value. */
export type MuxTypeValue = (typeof MuxType)[keyof typeof MuxType]

/** Header size in bytes: `u8 type | u32 circuit`, big-endian. */
export const MUX_HEADER_LENGTH = 5

/** A decoded Bridle-side message. */
export interface MuxMessage {
  type: MuxTypeValue
  circuit: number
  /** A view into the received buffer; never copied. */
  payload: Uint8Array
}

/**
 * Frame one Bridle-side message.
 * @param type - message kind.
 * @param circuit - circuit id, 32-bit unsigned.
 * @param payload - the body; empty for a bare close.
 * @returns the framed bytes, ready for `ws.send`.
 */
export function encodeMux(type: MuxTypeValue, circuit: number, payload: Uint8Array = new Uint8Array(0)): ArrayBuffer {
  const framed = new Uint8Array(MUX_HEADER_LENGTH + payload.byteLength)
  const header = new DataView(framed.buffer)
  header.setUint8(0, type)
  header.setUint32(1, circuit >>> 0)
  framed.set(payload, MUX_HEADER_LENGTH)
  return framed.buffer
}

/**
 * Unframe one Bridle-side message.
 * @param bytes - the received message.
 * @returns the decoded message.
 * @throws {@link Error} when the frame is too short or carries an unknown type.
 */
export function decodeMux(bytes: ArrayBuffer): MuxMessage {
  if (bytes.byteLength < MUX_HEADER_LENGTH) throw new Error('relay frame is shorter than its header')
  const view = new DataView(bytes)
  const type = view.getUint8(0)
  if (type !== MuxType.Open && type !== MuxType.Data && type !== MuxType.Close) {
    throw new Error(`relay frame has unknown type ${String(type)}`)
  }
  return { type, circuit: view.getUint32(1), payload: new Uint8Array(bytes, MUX_HEADER_LENGTH) }
}

/**
 * Decode unpadded base64url.
 * @param text - the encoded value.
 * @returns the raw bytes, or undefined when the input is not base64url.
 */
export function fromBase64Url(text: string): Uint8Array | undefined {
  const padded = text.replaceAll('-', '+').replaceAll('_', '/')
  try {
    const binary = atob(padded.padEnd(padded.length + ((4 - (padded.length % 4)) % 4), '='))
    const bytes = new Uint8Array(binary.length)
    for (let index = 0; index < binary.length; index += 1) bytes[index] = binary.charCodeAt(index)
    return bytes
  } catch {
    // Callers are parsing something a stranger sent; malformed input is a 403,
    // not a stack trace.
    return undefined
  }
}

/**
 * Encode unpadded base64url.
 * @param bytes - the raw bytes.
 * @returns the encoded value.
 */
export function toBase64Url(bytes: Uint8Array): string {
  let binary = ''
  for (const byte of bytes) binary += String.fromCharCode(byte)
  return btoa(binary).replaceAll('+', '-').replaceAll('/', '_').replaceAll('=', '')
}

/** UTF-8, reused rather than allocated per frame. */
const utf8 = new TextEncoder()

/**
 * Encode text for a mux payload.
 * @param text - the string to encode.
 * @returns its UTF-8 bytes.
 */
export function encodeText(text: string): Uint8Array {
  return utf8.encode(text)
}

/**
 * Decode a mux payload as text.
 * @param bytes - the payload.
 * @returns the decoded string.
 */
export function decodeText(bytes: Uint8Array): string {
  return new TextDecoder().decode(bytes)
}
