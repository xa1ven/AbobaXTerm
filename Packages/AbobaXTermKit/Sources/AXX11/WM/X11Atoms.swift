import Foundation

/// Atoms the window manager uses, interned once at startup.
enum XAtom: String, CaseIterable, Sendable {
    // Core types and selections
    case atom = "ATOM"
    case cardinal = "CARDINAL"
    case string = "STRING"
    case window = "WINDOW"
    case integer = "INTEGER"
    case utf8String = "UTF8_STRING"
    case compoundText = "COMPOUND_TEXT"
    case text = "TEXT"
    case textPlainUTF8 = "text/plain;charset=utf-8"
    case primary = "PRIMARY"
    case clipboard = "CLIPBOARD"
    case targets = "TARGETS"
    case multiple = "MULTIPLE"
    case timestamp = "TIMESTAMP"
    case incr = "INCR"
    case abxSelection = "_ABX_SELECTION"
    case manager = "MANAGER"
    case resourceManager = "RESOURCE_MANAGER"
    case xsettingsScreen = "_XSETTINGS_S0"
    case xsettingsSettings = "_XSETTINGS_SETTINGS"

    // ICCCM
    case wmName = "WM_NAME"
    case wmClass = "WM_CLASS"
    case wmHints = "WM_HINTS"
    case wmNormalHints = "WM_NORMAL_HINTS"
    case wmTransientFor = "WM_TRANSIENT_FOR"
    case wmClientMachine = "WM_CLIENT_MACHINE"
    case wmProtocols = "WM_PROTOCOLS"
    case wmDeleteWindow = "WM_DELETE_WINDOW"
    case wmTakeFocus = "WM_TAKE_FOCUS"
    case wmState = "WM_STATE"
    case wmChangeState = "WM_CHANGE_STATE"
    case motifWMHints = "_MOTIF_WM_HINTS"

    // EWMH
    case netSupported = "_NET_SUPPORTED"
    case netSupportingWMCheck = "_NET_SUPPORTING_WM_CHECK"
    case netNumberOfDesktops = "_NET_NUMBER_OF_DESKTOPS"
    case netCurrentDesktop = "_NET_CURRENT_DESKTOP"
    case netDesktopGeometry = "_NET_DESKTOP_GEOMETRY"
    case netDesktopViewport = "_NET_DESKTOP_VIEWPORT"
    case netWorkarea = "_NET_WORKAREA"
    case netActiveWindow = "_NET_ACTIVE_WINDOW"
    case netClientList = "_NET_CLIENT_LIST"
    case netCloseWindow = "_NET_CLOSE_WINDOW"
    case netFrameExtents = "_NET_FRAME_EXTENTS"
    case netRequestFrameExtents = "_NET_REQUEST_FRAME_EXTENTS"
    case netWMName = "_NET_WM_NAME"
    case netWMIcon = "_NET_WM_ICON"
    case netWMPing = "_NET_WM_PING"
    case netWMDesktop = "_NET_WM_DESKTOP"
    case netWMMoveResize = "_NET_WM_MOVERESIZE"
    case netWMAllowedActions = "_NET_WM_ALLOWED_ACTIONS"
    case netWMState = "_NET_WM_STATE"
    case netWMStateHidden = "_NET_WM_STATE_HIDDEN"
    case netWMStateFocused = "_NET_WM_STATE_FOCUSED"
    case netWMStateModal = "_NET_WM_STATE_MODAL"
    case netWMStateFullscreen = "_NET_WM_STATE_FULLSCREEN"
    case netWMStateMaximizedVert = "_NET_WM_STATE_MAXIMIZED_VERT"
    case netWMStateMaximizedHorz = "_NET_WM_STATE_MAXIMIZED_HORZ"
    case netWMStateAbove = "_NET_WM_STATE_ABOVE"
    case netWMWindowType = "_NET_WM_WINDOW_TYPE"
    case netWMWindowTypeNormal = "_NET_WM_WINDOW_TYPE_NORMAL"
    case netWMWindowTypeDialog = "_NET_WM_WINDOW_TYPE_DIALOG"
    case netWMWindowTypeUtility = "_NET_WM_WINDOW_TYPE_UTILITY"
    case netWMWindowTypeSplash = "_NET_WM_WINDOW_TYPE_SPLASH"
    case netWMWindowTypeToolbar = "_NET_WM_WINDOW_TYPE_TOOLBAR"
    case netWMWindowTypeMenu = "_NET_WM_WINDOW_TYPE_MENU"
    case netWMWindowTypeDropdownMenu = "_NET_WM_WINDOW_TYPE_DROPDOWN_MENU"
    case netWMWindowTypePopupMenu = "_NET_WM_WINDOW_TYPE_POPUP_MENU"
    case netWMWindowTypeTooltip = "_NET_WM_WINDOW_TYPE_TOOLTIP"
    case netWMWindowTypeNotification = "_NET_WM_WINDOW_TYPE_NOTIFICATION"
    case netWMWindowTypeCombo = "_NET_WM_WINDOW_TYPE_COMBO"
    case netWMWindowTypeDND = "_NET_WM_WINDOW_TYPE_DND"
    case gtkFrameExtents = "_GTK_FRAME_EXTENTS"
}

/// Atom ids on the current server connection.
struct XAtomTable: Sendable {
    private var ids: [XAtom: UInt32] = [:]
    private var names: [UInt32: XAtom] = [:]

    subscript(_ atom: XAtom) -> UInt32 { ids[atom] ?? 0 }

    /// The known atom with this id, if any.
    func known(_ id: UInt32) -> XAtom? { names[id] }

    static func intern(on connection: XConnection) async throws -> XAtomTable {
        var table = XAtomTable()
        // Pipelined: all requests go out before the first reply is awaited.
        try await withThrowingTaskGroup(of: (XAtom, UInt32).self) { group in
            for atom in XAtom.allCases {
                group.addTask { (atom, try await connection.internAtom(atom.rawValue)) }
            }
            for try await (atom, id) in group {
                table.ids[atom] = id
                table.names[id] = atom
            }
        }
        return table
    }

    /// Test helper: a table with made-up ids.
    static func synthetic() -> XAtomTable {
        var table = XAtomTable()
        for (index, atom) in XAtom.allCases.enumerated() {
            table.ids[atom] = UInt32(1000 + index)
            table.names[UInt32(1000 + index)] = atom
        }
        return table
    }
}
