import AXModels
import Foundation

/// A row in the sidebar.
public enum SidebarItem: Hashable, Sendable {
    case session(UUID)
    /// The same session shown in the Favorites section (separate tag so both
    /// rows are not highlighted at once).
    case favorite(UUID)
    case folder(UUID)

    public var sessionID: UUID? {
        switch self {
        case .session(let id), .favorite(let id): id
        case .folder: nil
        }
    }

    var dragPayload: String {
        switch self {
        case .session(let id), .favorite(let id): "session:\(id.uuidString)"
        case .folder(let id): "folder:\(id.uuidString)"
        }
    }

    init?(dragPayload: String) {
        let parts = dragPayload.split(separator: ":", maxSplits: 1)
        guard parts.count == 2, let id = UUID(uuidString: String(parts[1])) else { return nil }
        switch parts[0] {
        case "session": self = .session(id)
        case "folder": self = .folder(id)
        default: return nil
        }
    }
}

public struct EditorRequest: Identifiable {
    public let id = UUID()
    public var session: Session
    public var isNew: Bool
    public var initialSection: EditorSection? = nil
}

public struct DeletionRequest: Identifiable {
    public enum Target: Equatable {
        case session(UUID)
        case folder(UUID)
    }

    public let id = UUID()
    public var target: Target
    public var name: String
}

public struct FolderNameRequest: Identifiable {
    public enum Mode: Equatable {
        case create(parent: UUID?)
        case rename(UUID)
    }

    public let id = UUID()
    public var mode: Mode
    public var name: String
}

public struct ErrorMessage: Identifiable {
    public let id = UUID()
    public var title: String
    public var message: String
}

/// Tabs of the sidebar.
public enum SidebarMode: String, CaseIterable, Sendable {
    case sessions, files
}
