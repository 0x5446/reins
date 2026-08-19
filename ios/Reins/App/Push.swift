/// Asking iOS where this phone can be reached, and telling the machine.
///
/// The notifications in `Notifier` are posted by this app while it holds a
/// tunnel, which covers someone already looking at their phone and nothing
/// else. iOS suspends a backgrounded app within minutes and the tunnel goes
/// with it, so every question the agent asks after that reaches a machine
/// waiting on a person who was never told. Being elsewhere is the premise of
/// the product, so that is the common case.
///
/// A token is only asked for after someone has said yes to notifications, and
/// it goes to the paired machine inside the Noise channel. The Relay is handed
/// it one wake at a time, at the moment a push is sent, and is never told what
/// the push is about — the words in the banner come from a constant on the
/// Relay, and the real ones are written locally after the app reconnects.

import Foundation
import UIKit
import UserNotifications

/// Which APNs host will accept the tokens this build is issued.
///
/// Read from the provisioning profile the app was signed with rather than
/// derived from the build configuration, because the build configuration is not
/// what decides it: `aps-environment` comes from the profile, so a Release
/// build signed for development is a sandbox token wearing a production badge.
/// The two fail the same way — nothing is delivered, no error anywhere — which
/// makes a guess here the most expensive kind of wrong.
public enum PushEnvironment {
    /// `sandbox` or `production`, as APNs names them.
    public static let current: String = readFromProfile() ?? "production"

    private static func readFromProfile() -> String? {
        // Absent on the Simulator, which cannot receive a push anyway, and
        // absent from an App Store build — which is the one case where the
        // fallback is right, because App Store distribution is always
        // production.
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url),
              // A CMS envelope with a plist inside. Rather than decode the
              // signature, find the plist between its own markers: the payload
              // is ASCII XML and the markers cannot appear in the binary
              // wrapper around it.
              let text = String(data: data, encoding: .isoLatin1),
              let start = text.range(of: "<?xml"),
              let end = text.range(of: "</plist>")
        else { return nil }
        let plist = String(text[start.lowerBound..<end.upperBound])
        guard let bytes = plist.data(using: .isoLatin1),
              let parsed = try? PropertyListSerialization.propertyList(from: bytes, format: nil) as? [String: Any],
              let entitlements = parsed["Entitlements"] as? [String: Any],
              let environment = entitlements["aps-environment"] as? String
        else { return nil }
        // Apple spells it `development`; APNs spells the host `sandbox`.
        return environment == "development" ? "sandbox" : "production"
    }
}

/// Holds the device token iOS hands back, for whoever is connected at the time.
///
/// A separate object because the two events have nothing to do with each other:
/// iOS answers whenever it feels like it, often before any machine is
/// connected, and a tunnel is established and torn down several times a day
/// afterwards. Each side reads the latest state of the other rather than trying
/// to be present at the right moment.
@MainActor
@Observable
public final class PushRegistrar {
    /// The token, or nil while iOS has not answered or permission was refused.
    public private(set) var token: String?
    /// Whether iOS has answered at all, either way.
    public private(set) var answered = false

    /// Called on every answer, so whoever is connected can pass it on.
    ///
    /// A callback rather than something to observe, because there is exactly
    /// one interested party and the interesting moment is the transition. An
    /// observer would also fire on the launch where nothing changed.
    public var onAnswer: ((String?) -> Void)?

    public init() {}

    /// Ask iOS for a token. Safe to call repeatedly; iOS answers each time.
    ///
    /// Only worth calling once notifications have been allowed — registering
    /// without permission returns a token that can wake nothing, and the
    /// machine would ring it forever.
    public func register() {
        UIApplication.shared.registerForRemoteNotifications()
    }

    /// iOS answered.
    /// - Parameter data: the raw token bytes.
    public func accept(_ data: Data) {
        token = data.map { String(format: "%02x", $0) }.joined()
        answered = true
        onAnswer?(token)
    }

    /// iOS refused, or the device cannot register.
    ///
    /// Recorded rather than retried: the usual causes are a Simulator, a device
    /// with no network at launch, or an app whose entitlement is missing, and
    /// none of them is fixed by asking again immediately. The next launch asks
    /// again, which is the right cadence.
    public func refuse() {
        token = nil
        answered = true
        onAnswer?(nil)
    }
}

/// The delegate that exists only to receive the token.
///
/// SwiftUI has no other way to see `didRegisterForRemoteNotifications`: it is
/// an `UIApplicationDelegate` callback and there is no `onReceive` for it.
public final class PushDelegate: NSObject, UIApplicationDelegate {
    /// Set before the app finishes launching.
    @MainActor public static var registrar: PushRegistrar?

    public func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data,
    ) {
        Task { @MainActor in PushDelegate.registrar?.accept(deviceToken) }
    }

    public func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error,
    ) {
        Task { @MainActor in PushDelegate.registrar?.refuse() }
    }
}
