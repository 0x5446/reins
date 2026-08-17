/// Whether an address is on a network this device is actually on.
///
/// The question the app used to answer by proxy. "Are we on Wi-Fi" stood in
/// for it and got both ends wrong: on cellular it dialled local addresses that
/// could not possibly answer, and when a Mac was tethered to this very phone —
/// the phone's own path being cellular — it would have refused to dial the
/// machine one hop away.
///
/// Asking directly is both simpler and exact. Compare the machine's advertised
/// address against the subnets this device currently has; if none contains it,
/// there is nothing to try, and the relay should not be made to wait for a
/// dial that cannot succeed.
///
/// **Only excludes what it can prove is off-network.** A hostname rather than
/// an IPv4 literal — a Tailscale name, an operator's tunnel — is not
/// judgeable here and is always dialled. So is anything, if the interface list
/// cannot be read. Being wrong in that direction costs one failed connect;
/// being wrong the other way makes a working path invisible.

import Foundation

/// Whether `url`'s host sits inside one of this device's IPv4 subnets.
/// - Parameter url: a `ws://host:port` candidate.
/// - Returns: `false` only when the host is an IPv4 literal that provably
///   belongs to no network this device is on.
public func isOnOurNetwork(_ url: URL) -> Bool {
    guard let host = url.host, let target = ipv4(host) else { return true }
    let interfaces = localIPv4Interfaces()
    guard !interfaces.isEmpty else { return true }
    return interfaces.contains { (target & $0.mask) == ($0.address & $0.mask) }
}

/// Parse a dotted-quad into its raw 32 bits, or nil if it is not one.
private func ipv4(_ text: String) -> UInt32? {
    var parsed = in_addr()
    guard inet_pton(AF_INET, text, &parsed) == 1 else { return nil }
    return parsed.s_addr
}

/// Every IPv4 address this device holds, with its netmask.
///
/// Loopback included, and deliberately: `127.0.0.1` is on a network this
/// device is unambiguously on, and excluding it made the check refuse the one
/// address that can never fail — which is how the direct path is reached when
/// the Mac and the client are the same machine.
private func localIPv4Interfaces() -> [(address: UInt32, mask: UInt32)] {
    var head: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&head) == 0, let first = head else { return [] }
    defer { freeifaddrs(head) }

    var found: [(UInt32, UInt32)] = []
    for entry in sequence(first: first, next: { $0.pointee.ifa_next }) {
        let flags = entry.pointee.ifa_flags
        guard flags & UInt32(IFF_UP) != 0 else { continue }
        guard let address = entry.pointee.ifa_addr, address.pointee.sa_family == sa_family_t(AF_INET) else { continue }
        guard let netmask = entry.pointee.ifa_netmask else { continue }
        let raw = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr.s_addr }
        let mask = netmask.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr.s_addr }
        found.append((raw, mask))
    }
    return found
}
