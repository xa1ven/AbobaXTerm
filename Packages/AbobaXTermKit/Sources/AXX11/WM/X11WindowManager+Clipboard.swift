import AppKit

/// Bridges the Mac pasteboard and the X selections (plain text).
///
/// CLIPBOARD, Mac -> X: when an X window becomes key and the pasteboard has
/// changed, the manager takes ownership of CLIPBOARD and serves the text on
/// request. X -> Mac: when a client takes ownership, its text is fetched
/// right away and put on the pasteboard.
///
/// PRIMARY (the text currently selected with the mouse) is only touched for
/// classic terminals, on Command+C and Command+V: mirroring it all the time
/// would overwrite the Mac pasteboard on every selection.
struct X11ClipboardState {
    /// Pasteboard change count already mirrored to (or received from) X.
    var syncedChangeCount = -1
    var ownsSelection = false
    /// The manager owns PRIMARY (a classic terminal is about to paste the pasteboard).
    var ownsPrimary = false
    /// Chunks of an INCR transfer in progress.
    var incoming: [UInt8]?
    /// Upper bound for one clipboard text, either direction.
    static let maxBytes = 8 << 20
}

extension X11WindowManager {
    func startClipboard() {
        connection.xfixesSelectSelectionInput(ext, helperWindow, selection: atoms[.clipboard])
    }

    // MARK: Mac -> X

    /// Offers the pasteboard text to X clients if it changed since the last sync.
    func offerPasteboard() {
        guard pasteboard.changeCount != clipboard.syncedChangeCount else { return }
        clipboard.syncedChangeCount = pasteboard.changeCount
        guard pasteboard.availableType(from: [.string]) != nil else { return }
        clipboard.ownsSelection = true
        connection.setSelectionOwner(atoms[.clipboard], owner: helperWindow)
    }

    /// A client wants the clipboard contents (it is pasting).
    func selectionRequested(requestor: UInt32, selection: UInt32, target: UInt32, property requested: UInt32, time: UInt32) {
        // Obsolete clients pass None and expect the target atom to be used as the property.
        let property = requested == 0 ? target : requested
        var answered = false
        let owned = (selection == atoms[.clipboard] && clipboard.ownsSelection)
            || (selection == atoms[.primary] && clipboard.ownsPrimary)
        if owned {
            switch atoms.known(target) {
            case .targets:
                let targets: [XAtom] = [.targets, .timestamp, .utf8String, .textPlainUTF8, .string, .text]
                connection.changeProperty(requestor, property, type: atoms[.atom], longs: targets.map { atoms[$0] })
                answered = true
            case .timestamp:
                connection.changeProperty(requestor, property, type: atoms[.integer], longs: [serverTime])
                answered = true
            case .utf8String, .textPlainUTF8, .text:
                if let text = pasteboard.string(forType: .string), text.utf8.count <= X11ClipboardState.maxBytes {
                    let type = atoms.known(target) == .text ? atoms[.utf8String] : target
                    connection.changeProperty(requestor, property, type: type, format: 8, data: Array(text.utf8))
                    answered = true
                }
            case .string:
                if let text = pasteboard.string(forType: .string),
                   let latin = text.data(using: .isoLatin1, allowLossyConversion: true), latin.count <= X11ClipboardState.maxBytes {
                    connection.changeProperty(requestor, property, type: atoms[.string], format: 8, data: [UInt8](latin))
                    answered = true
                }
            default:
                break
            }
        }
        // SelectionNotify; property None tells the requestor the conversion failed.
        var w = ByteWriter()
        w.u8(31); w.u8(0); w.u16(0)
        w.u32(time); w.u32(requestor); w.u32(selection); w.u32(target); w.u32(answered ? property : 0)
        w.zeros(8)
        connection.sendEvent(to: requestor, event: w.bytes)
    }

    func selectionCleared(selection: UInt32) {
        if selection == atoms[.clipboard] { clipboard.ownsSelection = false }
        if selection == atoms[.primary] { clipboard.ownsPrimary = false }
    }

    /// Makes the pasteboard text the primary selection (pasted by Shift+Insert in classic terminals).
    func offerPrimarySelection() {
        guard pasteboard.availableType(from: [.string]) != nil else { return }
        clipboard.ownsPrimary = true
        connection.setSelectionOwner(atoms[.primary], owner: helperWindow)
    }

    // MARK: X -> Mac

    /// CLIPBOARD has a new owner: if it is a client, ask for its text.
    func selectionOwnerChanged(selection: UInt32, owner: UInt32) {
        guard selection == atoms[.clipboard], owner != 0, owner != helperWindow else { return }
        clipboard.ownsSelection = false
        fetchSelection(atoms[.clipboard], target: atoms[.utf8String])
    }

    /// Copies the text selected in an X program (PRIMARY) to the pasteboard.
    func copyPrimarySelection() {
        guard !clipboard.ownsPrimary else { return }
        fetchSelection(atoms[.primary], target: atoms[.utf8String])
    }

    private func fetchSelection(_ selection: UInt32, target: UInt32) {
        clipboard.incoming = nil
        connection.deleteProperty(helperWindow, atoms[.abxSelection])
        connection.convertSelection(selection, target: target, property: atoms[.abxSelection],
                                    requestor: helperWindow, time: serverTime)
    }

    /// The owner answered our conversion request.
    func selectionArrived(selection: UInt32, target: UInt32, property: UInt32) async {
        if property == 0 {
            // Refused. Programs from before UTF-8 only offer Latin-1 STRING.
            if target == atoms[.utf8String] { fetchSelection(selection, target: atoms[.string]) }
            return
        }
        guard property == atoms[.abxSelection],
              let value = try? await connection.property(helperWindow, property, delete: true, maxBytes: X11ClipboardState.maxBytes)
        else { return }
        if value.type == atoms[.incr] {
            // Large data comes in pieces: each one is announced by a PropertyNotify (see `helperPropertyChanged`).
            clipboard.incoming = []
        } else {
            storeOnPasteboard(value.data, latin1: value.type == atoms[.string])
        }
    }

    /// Next piece of an INCR transfer; a zero-length piece ends it.
    func helperPropertyChanged(_ atom: UInt32, deleted: Bool) async {
        guard atom == atoms[.abxSelection], !deleted, clipboard.incoming != nil,
              let value = try? await connection.property(helperWindow, atom, delete: true, maxBytes: X11ClipboardState.maxBytes),
              var buffer = clipboard.incoming else { return }
        if value.data.isEmpty {
            clipboard.incoming = nil
            storeOnPasteboard(buffer, latin1: value.type == atoms[.string])
        } else if buffer.count + value.data.count <= X11ClipboardState.maxBytes {
            buffer.append(contentsOf: value.data)
            clipboard.incoming = buffer
        } else {
            clipboard.incoming = nil
        }
    }

    private func storeOnPasteboard(_ bytes: [UInt8], latin1: Bool) {
        guard !bytes.isEmpty else { return }
        let text = (latin1 ? nil : String(bytes: bytes, encoding: .utf8))
            ?? String(bytes: bytes, encoding: .isoLatin1) ?? String(decoding: bytes, as: UTF8.self)
        if pasteboard.string(forType: .string) != text {
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
        }
        // This text came from X: do not offer it back (that would take the selection away from its owner).
        clipboard.syncedChangeCount = pasteboard.changeCount
    }
}
