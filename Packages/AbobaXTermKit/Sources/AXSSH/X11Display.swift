import Foundation

/// Supplies the local X display that `ssh -Y` forwards remote programs to.
/// The app implements it with its built-in X server.
public protocol X11DisplayProviding: Sendable {
    /// Makes sure the display is up and returns the DISPLAY value for ssh, e.g. ":41".
    func prepareDisplay() async throws -> String
}
