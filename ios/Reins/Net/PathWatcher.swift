/// Tells the tunnel when the phone's network changed underneath it.
///
/// A phone does not announce that it has left the flat, and neither does the
/// socket it was using: the radio hands over, the old flow stops being
/// delivered, and both ends go on believing. The system does know, though, and
/// `NWPathMonitor` is where it says so.
///
/// Two things depend on hearing it. A connection that is quietly dead should be
/// abandoned at the moment the path changed rather than forty seconds later,
/// and a relayed connection should move onto the local network the moment there
/// is one — neither of which can be discovered by asking, only by being told.
///
/// Reports transitions, not paths. `NWPathMonitor` emits on every flicker of
/// interface state, and acting on each of those would mean redialling a working
/// connection because the system re-evaluated something.

import Foundation
import Network

final class PathWatcher: @unchecked Sendable {
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "ai.novabox.reins.path")
    /// What the last reported path looked like, so an unchanged one stays
    /// silent. Starts as a value no real path produces, so the first update is
    /// always a change.
    private var last = "?"

    /// - Parameter onChange: called with whether the phone can now use Wi-Fi,
    ///   once per actual change.
    init(onChange: @escaping @Sendable (Bool) -> Void) {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let usable = path.status == .satisfied
            let wifi = usable && path.usesInterfaceType(.wifi)
            let signature = "\(usable)-\(wifi)"
            // The queue is serial, so this needs no further guarding.
            guard signature != self.last else { return }
            self.last = signature
            onChange(wifi)
        }
        monitor.start(queue: queue)
    }

    deinit {
        monitor.cancel()
    }
}
