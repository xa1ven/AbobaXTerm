import Foundation

/// Desktop settings published to X clients the way a Linux desktop does it:
/// XSETTINGS for toolkits (GTK, Qt, Java) and X resources for everything
/// that reads `Xft.dpi`.
///
/// This is what makes clients render at 2x on a Retina display: the server
/// runs at device-pixel resolution and the toolkits are told to scale up.
struct X11Settings: Equatable, Sendable {
    enum Value: Equatable, Sendable {
        case int(Int32)
        case string(String)
    }

    var values: [String: Value]

    /// `scale` is the integer UI scale (1 or 2).
    static func desktop(scale: Int) -> X11Settings {
        X11Settings(values: [
            // GTK renders everything `scale` times larger and takes font DPI from UnscaledDPI;
            // other toolkits only see Xft/DPI, which therefore carries the scale.
            "Gdk/WindowScalingFactor": .int(Int32(scale)),
            "Gdk/UnscaledDPI": .int(96 * 1024),
            "Xft/DPI": .int(Int32(96 * 1024 * scale)),
            "Xft/Antialias": .int(1),
            "Xft/Hinting": .int(1),
            "Xft/HintStyle": .string("hintslight"),
            "Xft/RGBA": .string("none"),
            "Gtk/CursorThemeSize": .int(Int32(24 * scale)),
        ])
    }

    /// Contents of the `_XSETTINGS_SETTINGS` property (XSETTINGS spec, little-endian).
    func encoded(serial: UInt32) -> [UInt8] {
        var w = ByteWriter()
        w.u8(0); w.zeros(3) // byte order: LSB first
        w.u32(serial)
        w.u32(UInt32(values.count))
        for name in values.keys.sorted() {
            guard let value = values[name] else { continue }
            let nameBytes = Array(name.utf8)
            switch value {
            case .int: w.u8(0)
            case .string: w.u8(1)
            }
            w.u8(0)
            w.u16(UInt16(nameBytes.count))
            w.raw(nameBytes); w.pad()
            w.u32(serial)
            switch value {
            case .int(let v):
                w.i32(v)
            case .string(let s):
                let bytes = Array(s.utf8)
                w.u32(UInt32(bytes.count))
                w.raw(bytes); w.pad()
            }
        }
        return w.bytes
    }

    /// Contents of the root window's RESOURCE_MANAGER property (what `xrdb` would load).
    static func resources(scale: Int) -> String {
        let lines = [
            "Xft.dpi:\t\(96 * scale)",
            "Xft.antialias:\t1",
            "Xft.hinting:\t1",
            "Xft.hintstyle:\thintslight",
            "Xft.rgba:\tnone",
            "Xcursor.size:\t\(24 * scale)",
            // The server only has the small built-in Latin-1 bitmap font: have xterm use
            // the remote machine's fonts instead (Unicode, and they follow Xft.dpi).
            "XTerm*faceName:\tmonospace",
            "XTerm*faceSize:\t10",
        ]
        return lines.joined(separator: "\n") + "\n"
    }
}
