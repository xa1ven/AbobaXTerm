import AXSSH
import AXX11

/// Lets the ssh launcher use the app's built-in X server as its display.
struct EmbeddedX11Display: X11DisplayProviding {
    let service: X11Service

    func prepareDisplay() async throws -> String {
        try await service.ensureRunning()
    }
}
