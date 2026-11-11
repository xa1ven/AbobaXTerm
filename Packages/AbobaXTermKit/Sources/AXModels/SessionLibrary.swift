import Foundation

/// Everything stored in sessions.json: folders and sessions.
public struct SessionLibrary: Codable, Hashable, Sendable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var folders: [Folder]
    public var sessions: [Session]

    public init(folders: [Folder] = [], sessions: [Session] = []) {
        self.schemaVersion = Self.currentSchemaVersion
        self.folders = folders
        self.sessions = sessions
    }

    private enum CodingKeys: String, CodingKey { case schemaVersion, folders, sessions }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? Self.currentSchemaVersion
        folders = try c.decodeIfPresent([Folder].self, forKey: .folders) ?? []
        sessions = try c.decodeIfPresent([Session].self, forKey: .sessions) ?? []
    }

    // MARK: Queries

    public func session(id: UUID) -> Session? {
        sessions.first { $0.id == id }
    }

    public func folder(id: UUID) -> Folder? {
        folders.first { $0.id == id }
    }

    /// Direct child folders of `parentID` (nil = root), sorted by name.
    public func childFolders(of parentID: UUID?) -> [Folder] {
        folders
            .filter { $0.parentID == parentID }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Sessions directly inside `folderID` (nil = root), sorted by display name.
    public func sessions(in folderID: UUID?) -> [Session] {
        sessions
            .filter { $0.folderID == folderID }
            .sorted(by: Self.byName)
    }

    public var favorites: [Session] {
        sessions.filter(\.isFavorite).sorted(by: Self.byName)
    }

    public func search(_ query: String) -> [Session] {
        sessions.filter { $0.matches(query) }.sorted(by: Self.byName)
    }

    /// `folderID` plus all folders nested inside it.
    public func subtree(of folderID: UUID) -> Set<UUID> {
        var result: Set<UUID> = [folderID]
        var queue = [folderID]
        while let current = queue.popLast() {
            for child in folders where child.parentID == current && !result.contains(child.id) {
                result.insert(child.id)
                queue.append(child.id)
            }
        }
        return result
    }

    /// Path like "Work / Prod" for a folder.
    public func path(of folderID: UUID?) -> String {
        var names: [String] = []
        var current = folderID
        var guardSet: Set<UUID> = []
        while let id = current, let folder = folder(id: id), guardSet.insert(id).inserted {
            names.insert(folder.name, at: 0)
            current = folder.parentID
        }
        return names.joined(separator: " / ")
    }

    // MARK: Mutations

    public mutating func upsert(_ session: Session) {
        if let index = sessions.firstIndex(where: { $0.id == session.id }) {
            sessions[index] = session
        } else {
            sessions.append(session)
        }
    }

    public mutating func removeSession(id: UUID) {
        sessions.removeAll { $0.id == id }
    }

    public mutating func upsert(_ folder: Folder) {
        if let index = folders.firstIndex(where: { $0.id == folder.id }) {
            folders[index] = folder
        } else {
            folders.append(folder)
        }
    }

    /// Removes a folder; its sessions and subfolders move up to its parent.
    public mutating func removeFolder(id: UUID) {
        guard let folder = folder(id: id) else { return }
        for i in sessions.indices where sessions[i].folderID == id {
            sessions[i].folderID = folder.parentID
        }
        for i in folders.indices where folders[i].parentID == id {
            folders[i].parentID = folder.parentID
        }
        folders.removeAll { $0.id == id }
    }

    /// Moves a session into a folder (nil = root).
    public mutating func move(sessionID: UUID, to folderID: UUID?) {
        guard let index = sessions.firstIndex(where: { $0.id == sessionID }) else { return }
        sessions[index].folderID = folderID
    }

    /// Moves a folder under another one; refuses to create cycles.
    @discardableResult
    public mutating func move(folderID: UUID, to parentID: UUID?) -> Bool {
        if let parentID, subtree(of: folderID).contains(parentID) { return false }
        guard let index = folders.firstIndex(where: { $0.id == folderID }) else { return false }
        folders[index].parentID = parentID
        return true
    }

    private static func byName(_ a: Session, _ b: Session) -> Bool {
        a.displayName.localizedStandardCompare(b.displayName) == .orderedAscending
    }
}
