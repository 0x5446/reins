/**
 * Which machines are currently reachable, and the circuits attached to them.
 *
 * This is the Relay's entire memory. It holds no user data, no message
 * contents, and no keys it could use to read anything: a machine is a device id
 * and a socket, and a circuit is a number. That is a deliberate design
 * constraint, not an omission — a Relay that cannot read traffic cannot leak
 * it, cannot be subpoenaed for it, and cannot lose it.
 */

import type { WebSocket } from 'ws'

/** One connected app socket bound to one machine. */
export interface Circuit {
  id: number
  socket: WebSocket
  /** Epoch milliseconds the circuit opened. */
  openedAt: number
}

/** One registered Bridle. */
export interface Machine {
  deviceId: string
  /** Display name the Bridle reported; shown to the app before it connects. */
  name: string
  /** Bridle version, for support questions. */
  version: string
  socket: WebSocket
  /** Epoch milliseconds the Bridle registered. */
  since: number
  circuits: Map<number, Circuit>
  nextCircuit: number
}

/** Circuits one machine may hold at once. */
const MAX_CIRCUITS_PER_MACHINE = 8

/** The set of live machines. */
export class Registry {
  private readonly machines = new Map<string, Machine>()

  /** How many machines are connected. */
  get size(): number {
    return this.machines.size
  }

  /** How many phone circuits are open across all machines. */
  get circuitCount(): number {
    let total = 0
    for (const machine of this.machines.values()) total += machine.circuits.size
    return total
  }

  /**
   * Register a Bridle, displacing any earlier socket for the same machine.
   * @param deviceId - the machine's self-certifying device id.
   * @param name - display name.
   * @param version - Bridle version string.
   * @param socket - the Bridle's Relay socket.
   * @returns the registered machine.
   */
  register(deviceId: string, name: string, version: string, socket: WebSocket): Machine {
    // A laptop that suspends can leave a half-dead socket behind; the newest
    // registration is by definition the one that can still carry traffic.
    this.machines.get(deviceId)?.socket.close(4000, 'replaced by a newer connection')
    const machine: Machine = { deviceId, name, version, socket, since: Date.now(), circuits: new Map(), nextCircuit: 1 }
    this.machines.set(deviceId, machine)
    return machine
  }

  /**
   * Drop a machine, but only if the socket given is still the current one.
   * @param deviceId - the machine to drop.
   * @param socket - the socket that closed.
   */
  unregister(deviceId: string, socket: WebSocket): void {
    const machine = this.machines.get(deviceId)
    if (machine === undefined || machine.socket !== socket) return
    for (const circuit of machine.circuits.values()) circuit.socket.close(4004, 'machine went offline')
    this.machines.delete(deviceId)
  }

  /**
   * Look up a machine.
   * @param deviceId - the machine's device id.
   * @returns the machine, or undefined when it is offline.
   */
  find(deviceId: string): Machine | undefined {
    return this.machines.get(deviceId)
  }

  /**
   * Attach an app socket to a machine.
   * @param machine - the target machine.
   * @param socket - the app's socket.
   * @returns the new circuit, or undefined when the machine is at capacity.
   */
  attach(machine: Machine, socket: WebSocket): Circuit | undefined {
    if (machine.circuits.size >= MAX_CIRCUITS_PER_MACHINE) return undefined
    const id = machine.nextCircuit
    machine.nextCircuit = machine.nextCircuit >= 0xffffffff ? 1 : machine.nextCircuit + 1
    const circuit: Circuit = { id, socket, openedAt: Date.now() }
    machine.circuits.set(id, circuit)
    return circuit
  }

  /**
   * Detach a circuit.
   * @param machine - the machine it belonged to.
   * @param id - the circuit id.
   */
  detach(machine: Machine, id: number): void {
    machine.circuits.delete(id)
  }
}
