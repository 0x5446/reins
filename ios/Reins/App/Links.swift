/// Everywhere the app sends someone outside itself.
///
/// One file, because these move together and because they are the part of the
/// product that cannot be finished in a source tree: the domain has to be
/// registered, the pages written, and the install script published before a
/// single one of them resolves. Keeping them here means that is one edit rather
/// than a search across the views, and it makes the list of what shipping still
/// needs readable in one screen.
///
/// See `docs/deployment.md` for what has to exist behind each of these.

import Foundation

public enum Links {
    /// Where the product lives.
    public static let site = URL(string: "https://reins.app")!

    /// The one-line installer for the Bridle, pasted into Terminal on the Mac.
    ///
    /// It is shown as text rather than tapped, so it is a string first and a URL
    /// never — nobody opens this in Safari.
    public static let installCommand = "curl -fsSL https://reins.app/install | sh"

    /// The command that shows a pairing code, run after the installer.
    public static let pairCommand = "bridle pair"

    public static let help = URL(string: "https://reins.app/help")!
    public static let privacy = URL(string: "https://reins.app/privacy")!
}
