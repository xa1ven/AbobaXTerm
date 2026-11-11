import Foundation

/// WM_NORMAL_HINTS: what sizes and positions the client accepts.
struct X11SizeHints: Equatable, Sendable {
    var userPosition = false
    var programPosition = false
    var minSize: (width: Int, height: Int)?
    var maxSize: (width: Int, height: Int)?
    var increment: (width: Int, height: Int)?
    var baseSize: (width: Int, height: Int)?

    static func == (a: X11SizeHints, b: X11SizeHints) -> Bool {
        a.userPosition == b.userPosition && a.programPosition == b.programPosition
            && a.minSize?.width == b.minSize?.width && a.minSize?.height == b.minSize?.height
            && a.maxSize?.width == b.maxSize?.width && a.maxSize?.height == b.maxSize?.height
            && a.increment?.width == b.increment?.width && a.increment?.height == b.increment?.height
            && a.baseSize?.width == b.baseSize?.width && a.baseSize?.height == b.baseSize?.height
    }

    var hasPosition: Bool { userPosition || programPosition }

    /// The client cannot be resized when it pins min and max to the same size.
    var isFixedSize: Bool {
        guard let minSize, let maxSize else { return false }
        return minSize.width == maxSize.width && minSize.height == maxSize.height
    }

    init() {}

    init(longs: [UInt32]) {
        guard let flags = longs.first else { return }
        func pair(_ index: Int) -> (width: Int, height: Int)? {
            guard longs.count > index + 1 else { return nil }
            return (Int(Int32(bitPattern: longs[index])), Int(Int32(bitPattern: longs[index + 1])))
        }
        userPosition = flags & 1 != 0
        programPosition = flags & 4 != 0
        if flags & 16 != 0, let p = pair(5), p.width > 0, p.height > 0 { minSize = p }
        if flags & 32 != 0, let p = pair(7), p.width > 0, p.height > 0 { maxSize = p }
        if flags & 64 != 0, let p = pair(9), p.width > 0, p.height > 0 { increment = p }
        if flags & 256 != 0, let p = pair(15), p.width >= 0, p.height >= 0 { baseSize = p }
        // ICCCM: a missing minimum size defaults to the base size and vice versa.
        if minSize == nil, let baseSize, baseSize.width > 0, baseSize.height > 0 { minSize = baseSize }
    }
}

/// What kind of top-level window the client declared (_NET_WM_WINDOW_TYPE).
enum X11WindowKind: Equatable, Sendable {
    case normal, dialog, utility, splash, menu, tooltip, notification, dragIcon
}

/// Client-set properties of a top-level window, in decoded form.
struct X11WindowProperties: Equatable, Sendable {
    var netName: String?
    var legacyName: String?
    var clientMachine: String?
    var instanceName: String?
    var className: String?
    var sizeHints = X11SizeHints()
    /// WM_HINTS.input: false means the client takes focus itself (or never).
    var acceptsInput = true
    var supportsDelete = false
    var supportsTakeFocus = false
    var transientFor: UInt32?
    var kind: X11WindowKind = .normal
    /// False when the client draws its own title bar (_MOTIF_WM_HINTS without decorations).
    var wantsDecorations = true
    var isModal = false

    var title: String {
        if let netName, !netName.isEmpty { return netName }
        if let legacyName, !legacyName.isEmpty { return legacyName }
        return className ?? instanceName ?? "X11"
    }

    /// How copy and paste shortcuts work in this program.
    var shortcutStyle: X11ShortcutStyle {
        X11ShortcutStyle(instanceName: instanceName, className: className)
    }

    /// Applies a freshly read property; returns false for properties that are not tracked.
    @discardableResult
    mutating func apply(_ atom: XAtom, _ value: XProperty?, atoms: XAtomTable) -> Bool {
        switch atom {
        case .netWMName:
            netName = value.map { String(decoding: $0.data, as: UTF8.self) }
        case .wmName:
            legacyName = value.map { Self.text($0.data) }
        case .wmClientMachine:
            clientMachine = value.map { Self.text($0.data) }
        case .wmClass:
            let parts = (value?.data ?? []).split(separator: 0, omittingEmptySubsequences: false).map { Self.text(Array($0)) }
            instanceName = parts.first.flatMap { $0.isEmpty ? nil : $0 }
            className = parts.count > 1 && !parts[1].isEmpty ? parts[1] : nil
        case .wmNormalHints:
            sizeHints = value.map { X11SizeHints(longs: $0.longs) } ?? X11SizeHints()
        case .wmHints:
            let longs = value?.longs ?? []
            acceptsInput = longs.count > 1 && longs[0] & 1 != 0 ? longs[1] != 0 : true
        case .wmProtocols:
            let list = value?.longs ?? []
            supportsDelete = list.contains(atoms[.wmDeleteWindow])
            supportsTakeFocus = list.contains(atoms[.wmTakeFocus])
        case .wmTransientFor:
            transientFor = value?.longs.first.flatMap { $0 == 0 ? nil : $0 }
        case .netWMWindowType:
            kind = Self.classify(value?.longs ?? [], atoms: atoms)
        case .motifWMHints:
            let longs = value?.longs ?? []
            // flags bit 1: the decorations field is valid; 0 there = no title bar or border.
            wantsDecorations = !(longs.count > 2 && longs[0] & 2 != 0 && longs[2] == 0)
        case .netWMState:
            isModal = (value?.longs ?? []).contains(atoms[.netWMStateModal])
        default:
            return false
        }
        return true
    }

    /// Properties read when a window is first managed and watched afterwards.
    static let tracked: [XAtom] = [
        .netWMName, .wmName, .wmClientMachine, .wmClass, .wmNormalHints, .wmHints,
        .wmProtocols, .wmTransientFor, .netWMWindowType, .motifWMHints, .netWMState,
    ]

    private static func classify(_ types: [UInt32], atoms: XAtomTable) -> X11WindowKind {
        // The list is in order of preference; the first one we know wins.
        for type in types {
            switch atoms.known(type) {
            case .netWMWindowTypeNormal: return .normal
            case .netWMWindowTypeDialog: return .dialog
            case .netWMWindowTypeUtility, .netWMWindowTypeToolbar: return .utility
            case .netWMWindowTypeSplash: return .splash
            case .netWMWindowTypeMenu, .netWMWindowTypeDropdownMenu, .netWMWindowTypePopupMenu, .netWMWindowTypeCombo: return .menu
            case .netWMWindowTypeTooltip: return .tooltip
            case .netWMWindowTypeNotification: return .notification
            case .netWMWindowTypeDND: return .dragIcon
            default: continue
            }
        }
        return .normal
    }

    /// STRING / COMPOUND_TEXT are Latin-1 in theory; most clients write UTF-8 there today.
    private static func text(_ bytes: [UInt8]) -> String {
        let trimmed = bytes.last == 0 ? Array(bytes.dropLast()) : bytes
        if let utf8 = String(bytes: trimmed, encoding: .utf8) { return utf8 }
        return String(bytes: trimmed, encoding: .isoLatin1) ?? ""
    }
}
