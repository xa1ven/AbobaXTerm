import AXModels
import Foundation
import Testing

@Suite struct SessionLibraryTests {
    func makeLibrary() -> (SessionLibrary, work: Folder, prod: Folder) {
        let work = Folder(name: "Work")
        let prod = Folder(name: "Prod", parentID: work.id)
        let lib = SessionLibrary(
            folders: [work, prod],
            sessions: [
                Session(name: "b", host: "b", folderID: work.id),
                Session(name: "a", host: "a", folderID: work.id, isFavorite: true),
                Session(name: "db", host: "db", folderID: prod.id),
                Session(name: "home", host: "home"),
            ])
        return (lib, work, prod)
    }

    @Test func childrenAndSorting() {
        let (lib, work, prod) = makeLibrary()
        #expect(lib.childFolders(of: nil).map(\.name) == ["Work"])
        #expect(lib.childFolders(of: work.id).map(\.id) == [prod.id])
        #expect(lib.sessions(in: work.id).map(\.name) == ["a", "b"])
        #expect(lib.sessions(in: nil).map(\.name) == ["home"])
        #expect(lib.favorites.map(\.name) == ["a"])
        #expect(lib.path(of: prod.id) == "Work / Prod")
    }

    @Test func removingFolderMovesContentsUp() {
        var (lib, work, prod) = makeLibrary()
        lib.removeFolder(id: work.id)
        #expect(lib.folder(id: work.id) == nil)
        #expect(lib.folder(id: prod.id)?.parentID == nil)
        #expect(lib.sessions(in: nil).map(\.name) == ["a", "b", "home"])
        #expect(lib.sessions.count == 4)
    }

    @Test func folderMoveRejectsCycles() {
        var (lib, work, prod) = makeLibrary()
        #expect(lib.move(folderID: work.id, to: prod.id) == false)
        #expect(lib.move(folderID: work.id, to: work.id) == false)
        #expect(lib.move(folderID: prod.id, to: nil) == true)
        #expect(lib.folder(id: prod.id)?.parentID == nil)
    }

    @Test func upsertAndSearch() {
        var (lib, _, _) = makeLibrary()
        var s = lib.sessions[0]
        s.name = "renamed"
        lib.upsert(s)
        #expect(lib.sessions.count == 4)
        #expect(lib.session(id: s.id)?.name == "renamed")
        lib.upsert(Session(name: "new", host: "n"))
        #expect(lib.sessions.count == 5)
        #expect(lib.search("D").map(\.name) == ["db", "renamed"]) // "renamed" contains "d"
    }

    @Test func manySessionsAreSupported() {
        var lib = SessionLibrary()
        for i in 0..<500 { lib.upsert(Session(name: "s\(i)", host: "h\(i)")) }
        #expect(lib.sessions.count == 500)
        #expect(lib.sessions(in: nil).first?.name == "s0")
        #expect(lib.sessions(in: nil).last?.name == "s499")
    }
}
