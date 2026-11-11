import AXModels
import Foundation
import Testing

@Suite struct SessionCodingTests {
    @Test func roundTripAllFields() throws {
        let session = Session(
            name: "Prod", host: "10.0.0.1", port: 2222, user: "root",
            auth: .publicKey(path: "~/.ssh/id_ed25519"), jumpHost: "admin@bastion",
            extraOptions: "-o ServerAliveInterval=30", x11Forwarding: true, folderID: UUID(),
            isFavorite: true, color: .teal, icon: "server.rack", notes: "note",
            createdAt: Date(timeIntervalSince1970: 1_000_000), lastConnectedAt: Date(timeIntervalSince1970: 2_000_000))
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(Session.self, from: encoder.encode(session))
        #expect(decoded == session)
    }

    @Test func decodesMinimalJSONWithDefaults() throws {
        let json = #"{"host":"example.com"}"#
        let session = try JSONDecoder().decode(Session.self, from: Data(json.utf8))
        #expect(session.host == "example.com")
        #expect(session.auth == .system)
        #expect(session.port == nil)
        #expect(session.isFavorite == false)
        #expect(session.extraOptions.isEmpty)
    }

    @Test func authMethodJSONShape() throws {
        let data = try JSONEncoder().encode(AuthMethod.publicKey(path: "/k"))
        let object = try JSONSerialization.jsonObject(with: data) as? [String: String]
        #expect(object == ["type": "publicKey", "keyPath": "/k"])
        #expect(try JSONDecoder().decode(AuthMethod.self, from: Data(#"{"type":"password"}"#.utf8)) == .password)
    }

    @Test func unknownColorIsIgnored() throws {
        let json = #"{"host":"h","color":"chartreuse"}"#
        let session = try JSONDecoder().decode(Session.self, from: Data(json.utf8))
        #expect(session.color == nil)
    }

    @Test func displayNameAndTarget() {
        #expect(Session(host: "h").displayName == "h")
        #expect(Session(host: "h", port: 22, user: "u").target == "u@h:22")
        #expect(Session(host: "::1", port: 22).target == "[::1]:22")
        #expect(Session(name: " My box ", host: "h").displayName == "My box")
    }

    @Test func searchMatchesNameHostUser() {
        let s = Session(name: "Web", host: "web01.example.com", user: "deploy")
        #expect(s.matches("WEB01"))
        #expect(s.matches("deploy"))
        #expect(s.matches(""))
        #expect(!s.matches("db"))
    }
}

@Suite struct QuickConnectTests {
    @Test(arguments: [
        ("host", nil, "host", nil),
        ("root@host", "root", "host", nil),
        ("root@host:2222", "root", "host", 2222),
        ("ssh://me@1.2.3.4:22/", "me", "1.2.3.4", 22),
        ("[fe80::1]:2200", nil, "fe80::1", 2200),
        ("fe80::1", nil, "fe80::1", nil),
        ("user@corp@host", "user@corp", "host", nil),
    ] as [(String, String?, String, Int?)])
    func parses(input: String, user: String?, host: String, port: Int?) throws {
        let s = try #require(Session.parseQuickConnect(input))
        #expect(s.user == user)
        #expect(s.host == host)
        #expect(s.port == port)
    }

    @Test(arguments: ["", "  ", "@host", "host:abc", "host:70000", "-oProxyCommand=x", "a b"])
    func rejects(input: String) {
        #expect(Session.parseQuickConnect(input) == nil)
    }
}
