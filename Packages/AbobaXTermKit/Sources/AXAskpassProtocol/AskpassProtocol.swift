import Foundation

/// Wire protocol between `abx-askpass` (spawned by ssh as SSH_ASKPASS) and the
/// app. One newline-terminated JSON request, one newline-terminated JSON reply.
public enum AskpassEnvironment {
    public static let socketPath = "ABX_ASKPASS_SOCKET"
    public static let token = "ABX_ASKPASS_TOKEN"
}

public struct AskpassRequest: Codable, Sendable, Equatable {
    public var token: String
    public var prompt: String
    /// Value of SSH_ASKPASS_PROMPT set by ssh: "confirm", "none" or nil.
    public var hint: String?

    public init(token: String, prompt: String, hint: String?) {
        self.token = token
        self.prompt = prompt
        self.hint = hint
    }
}

public struct AskpassResponse: Codable, Sendable, Equatable {
    /// nil means "cancelled": the helper exits with status 1.
    public var answer: String?

    public init(answer: String?) {
        self.answer = answer
    }
}

public enum AskpassCodec {
    public static func encodeLine<T: Encodable>(_ value: T) throws -> Data {
        var data = try JSONEncoder().encode(value)
        data.append(0x0A)
        return data
    }

    public static func decodeLine<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        var line = data
        if let newline = line.firstIndex(of: 0x0A) { line = line[..<newline] }
        return try JSONDecoder().decode(type, from: line)
    }
}
