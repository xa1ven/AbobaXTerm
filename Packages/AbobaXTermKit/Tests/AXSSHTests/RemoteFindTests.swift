@testable import AXSSH
import Foundation
import Testing

@Suite struct RemoteFindTests {
    @Test func patterns() {
        #expect(RemoteFind.namePattern(for: "nginx") == "*nginx*")
        #expect(RemoteFind.namePattern(for: "*.conf") == "*.conf")
        #expect(RemoteFind.namePattern(for: " log?.txt ") == "log?.txt")
    }

    @Test func commandQuotesUserInput() {
        let cmd = RemoteFind.command(root: "/home/my dir", query: "a'b; rm -rf /", limit: 500)
        #expect(cmd.hasPrefix("find '/home/my dir' -mindepth 1 "))
        #expect(cmd.contains("-iname '*a'\\''b; rm -rf /*' -print"))
        #expect(cmd.hasSuffix("| head -n 501"))
    }

    @Test func commandRunsInLocalShell() throws {
        // Real find over a temp tree, through /bin/sh like the remote side.
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("abx-find-\(UUID().uuidString)").path
        let fm = FileManager.default
        try fm.createDirectory(atPath: root + "/etc/nginx", withIntermediateDirectories: true)
        try fm.createDirectory(atPath: root + "/.cache", withIntermediateDirectories: true)
        for f in ["/etc/nginx/Nginx.conf", "/etc/hosts", "/.cache/nginx.tmp", "/readme.md"] {
            fm.createFile(atPath: root + f, contents: nil)
        }
        defer { try? fm.removeItem(atPath: root) }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", RemoteFind.command(root: root, query: "NGINX", limit: 100)]
        let pipe = Pipe()
        p.standardOutput = pipe
        try p.run()
        let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()

        #expect(RemoteFind.parse(out, root: root, includeHidden: false) == [root + "/etc/nginx", root + "/etc/nginx/Nginx.conf"])
        #expect(RemoteFind.parse(out, root: root, includeHidden: true).count == 3)
    }

    @Test func parseHandlesSlashRoot() {
        #expect(RemoteFind.parse("/etc\n/.x\n", root: "/", includeHidden: false) == ["/etc"])
    }
}
