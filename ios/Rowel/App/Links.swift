/// Everywhere the app sends someone outside itself.
///
/// One file, because these move together. Keeping them here means changing a
/// destination is one edit rather than a search across the views.
///
/// One host, three things behind it, split by path — `docs/deployment.md` has
/// the full picture:
///
/// - `/v1/*` and `/healthz` are the Relay itself.
/// - `/install` is a Cloudflare redirect to the repository. It is deliberately
///   *not* served by the Relay: a relay that also hands out the installer turns
///   one compromise into a supply-chain event.
/// - `/`, `/get`, `/help` and `/privacy` are static pages at the edge, with no
///   origin. They resolve when the Relay is down, which is the state a privacy
///   link most needs to survive.
///
/// `e2e/tests/deployed.test.js` checks that every URL below is a 200.

import Foundation

public enum Links {
    /// Where the product lives. Also the Relay; see the note above.
    public static let site = URL(string: "https://rowel.novabox.ai")!

    /// The one-line installer for the Bridle, pasted into Terminal on the Mac.
    ///
    /// It is shown as text rather than tapped, so it is a string first and a URL
    /// never — nobody opens this in Safari.
    public static let installCommand = "curl -fsSL https://rowel.novabox.ai/install | sh"

    /// The command that shows a pairing code, run after the installer.
    public static let pairCommand = "bridle pair"

    public static let help = URL(string: "https://rowel.novabox.ai/help")!
    public static let privacy = URL(string: "https://rowel.novabox.ai/privacy")!
}
