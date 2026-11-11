import Foundation

/// A folder (group) of sessions. Folders can be nested via `parentID`.
public struct Folder: Identifiable, Hashable, Codable, Sendable {
    public var id: UUID
    public var name: String
    public var parentID: UUID?

    public init(id: UUID = UUID(), name: String, parentID: UUID? = nil) {
        self.id = id
        self.name = name
        self.parentID = parentID
    }
}
