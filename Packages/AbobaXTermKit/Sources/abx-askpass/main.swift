// abx-askpass: SSH_ASKPASS helper for AbobaXTerm.
//
// ssh runs this program with the prompt as argv[1] and reads the answer from
// stdout. The helper never touches the Keychain itself: it forwards the prompt
// to the running app over a private Unix socket and prints whatever the app
// returns. Exit status 1 means "cancelled".

import AXAskpassProtocol
import Darwin
import Foundation

let environment = ProcessInfo.processInfo.environment

guard let socketPath = environment[AskpassEnvironment.socketPath],
      let token = environment[AskpassEnvironment.token]
else {
    FileHandle.standardError.write(Data("abx-askpass: must be launched by AbobaXTerm\n".utf8))
    exit(1)
}

let prompt = CommandLine.arguments.dropFirst().joined(separator: " ")
let request = AskpassRequest(token: token, prompt: prompt, hint: environment["SSH_ASKPASS_PROMPT"])

do {
    let fd = try UnixSocket.connect(path: socketPath)
    defer { close(fd) }
    try UnixSocket.writeAll(fd: fd, data: AskpassCodec.encodeLine(request))
    let reply = try UnixSocket.readLine(fd: fd)
    let response = try AskpassCodec.decodeLine(AskpassResponse.self, from: reply)
    guard let answer = response.answer else { exit(1) }
    FileHandle.standardOutput.write(Data((answer + "\n").utf8))
    exit(0)
} catch {
    FileHandle.standardError.write(Data("abx-askpass: \(error)\n".utf8))
    exit(1)
}
