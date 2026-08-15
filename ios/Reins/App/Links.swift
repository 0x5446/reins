/// Everywhere the app sends someone outside itself.
///
/// One file, because these move together and because they are the part of the
/// product that cannot be finished in a source tree: the host has to be
/// deployed and the pages written before any of them resolve. Keeping them here
/// means that is one edit rather than a search across the views, and it makes
/// the list of what shipping still needs readable in one screen.
///
/// Everything is on one host on purpose. The Relay already answers on
/// `reins.novabox.ai`, its own routes live under `/v1` and `/healthz`, and
/// `/install` is served by it too — so a second static site would exist only to
/// hold two pages. See `docs/deployment.md`.

import Foundation

public enum Links {
    /// Where the product lives. Also the Relay; see the note above.
    public static let site = URL(string: "https://reins.novabox.ai")!

    /// The one-line installer for the Bridle, pasted into Terminal on the Mac.
    ///
    /// It is shown as text rather than tapped, so it is a string first and a URL
    /// never — nobody opens this in Safari.
    public static let installCommand = "curl -fsSL https://reins.novabox.ai/install | sh"

    /// The command that shows a pairing code, run after the installer.
    public static let pairCommand = "bridle pair"

    public static let help = URL(string: "https://reins.novabox.ai/help")!
    public static let privacy = URL(string: "https://reins.novabox.ai/privacy")!
}
