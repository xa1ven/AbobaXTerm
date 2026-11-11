// Development harness for the embedded X server.
//
// Starts the server, runs a command with DISPLAY pointing at it, optionally
// plays scripted input, then dumps every X window (state + PNG) to a directory.
//
//   abx-x11-harness --out DIR [--show] [--wait SECONDS] [--script STEPS] -- COMMAND...
//
// STEPS is a ';'-separated list:
//   wait:1.5            sleep
//   click:N:X:Y[:B]     click in the N-th mapped window (0 = bottom-most) at X,Y with button B
//   move:N:X:Y          move the pointer
//   type:TEXT           type text
//   key:CODE[:shift]    tap a Mac virtual key code
//   keydown:CODE / keyup:CODE   hold and release a key
//   shortcut:N:CODE     Command+key in the N-th window (as translated by the app)
//   copy:TEXT           put text on the (private) pasteboard and offer it to X
//   pasteboard          print the pasteboard text
//   close:N             ask the N-th window to close
//   dump:NAME           write a snapshot named NAME
//
// The command gets DISPLAY, XAUTHORITY and ABX_XAUTH (the xauth stand-in for `ssh -o XAuthLocation=`).
import AppKit
import AXX11

@MainActor
final class Harness {
    var out = FileManager.default.currentDirectoryPath
    var show = false
    var scale: Double?
    var wait = 3.0
    var script: [String] = []
    var command: [String] = []
    let service: X11Service

    init(arguments: [String]) {
        var args = arguments.dropFirst()
        while let arg = args.popFirst() {
            switch arg {
            case "--out": out = args.popFirst() ?? out
            case "--show": show = true
            case "--scale": scale = Double(args.popFirst() ?? "")
            case "--wait": wait = Double(args.popFirst() ?? "") ?? wait
            case "--script": script = (args.popFirst() ?? "").split(separator: ";").map(String.init)
            case "--": command = Array(args); args = []
            default: FileHandle.standardError.write(Data("unknown argument \(arg)\n".utf8))
            }
        }
        let runtime = URL(fileURLWithPath: out).appendingPathComponent("runtime", isDirectory: true)
        try? FileManager.default.createDirectory(at: runtime, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        service = X11Service(runtimeDirectory: runtime)
        service.presentsWindows = show
        // Never touch the user's real clipboard from the harness.
        service.pasteboard = NSPasteboard(name: NSPasteboard.Name("com.mikhail.AbobaXTerm.harness"))
        service.scaleOverride = scale.map { CGFloat($0) }
    }

    func log(_ text: String) { FileHandle.standardError.write(Data((text + "\n").utf8)) }

    func run() async {
        do {
            let started = Date()
            let display = try await service.ensureRunning()
            log("server ready on \(display) in \(Int(Date().timeIntervalSince(started) * 1000)) ms")
        } catch {
            log("start failed: \(error.localizedDescription)")
            exit(1)
        }

        var client: Process?
        if !command.isEmpty {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = command
            var environment = ProcessInfo.processInfo.environment
            environment.merge(service.localClientEnvironment()) { $1 }
            environment["ABX_XAUTH"] = X11Service.xauthLocation(runtimeDirectory: service.runtimeDirectory)
            process.environment = environment
            do { try process.run() } catch { log("cannot run command: \(error.localizedDescription)") }
            client = process
        }

        try? await Task.sleep(for: .seconds(wait))
        for step in script { await perform(step) }
        dump("final")
        client?.terminate()
        service.shutdown()
        exit(0)
    }

    func mapped() -> [X11Service.WindowDump] {
        service.debugWindows(includePixels: false).filter(\.isMapped)
    }

    func perform(_ step: String) async {
        let parts = step.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        func window(_ index: Int) -> UInt32? {
            let all = mapped()
            guard parts.count > index, let n = Int(parts[index]), all.indices.contains(n) else {
                log("step '\(step)': no such window")
                return nil
            }
            return all[n].id
        }
        func int(_ index: Int) -> Int { parts.count > index ? Int(parts[index]) ?? 0 : 0 }
        switch parts.first {
        case "wait":
            try? await Task.sleep(for: .seconds(Double(parts.count > 1 ? parts[1] : "") ?? 1))
        case "click":
            if let id = window(1) { service.debugClick(window: id, x: int(2), y: int(3), button: parts.count > 4 ? int(4) : 1) }
        case "move":
            if let id = window(1) { service.debugMovePointer(window: id, x: int(2), y: int(3)) }
        case "type":
            service.debugType(parts.dropFirst().joined(separator: ":"))
        case "key":
            service.debugTap(keyCode: UInt8(int(1)), shift: parts.count > 2 && parts[2] == "shift")
        case "copy":
            service.pasteboard.clearContents()
            service.pasteboard.setString(parts.dropFirst().joined(separator: ":"), forType: .string)
            service.debugOfferPasteboard()
        case "pasteboard":
            log("pasteboard: \(service.pasteboard.string(forType: .string) ?? "<empty>")")
        case "keydown":
            service.debugKey(keyCode: UInt8(int(1)), down: true)
        case "keyup":
            service.debugKey(keyCode: UInt8(int(1)), down: false)
        case "shortcut":
            if let id = window(1), !service.debugShortcut(window: id, keyCode: UInt8(int(2))) { log("step '\(step)': not a shortcut") }
        case "close":
            if let id = window(1) { service.debugClose(window: id) }
        case "dump":
            dump(parts.count > 1 ? parts[1] : "step")
        default:
            log("unknown step '\(step)'")
        }
        try? await Task.sleep(for: .milliseconds(150))
    }

    func dump(_ name: String) {
        var lines: [String] = []
        for (index, window) in service.debugWindows().enumerated() {
            let kind = window.overrideRedirect ? "popup" : "window"
            let frame = window.hostFrame.map { " host=\(Int($0.minX)),\(Int($0.minY)) \(Int($0.width))x\(Int($0.height))" } ?? ""
            lines.append("\(index) 0x\(String(window.id, radix: 16)) \(kind) mapped=\(window.isMapped) "
                + "\(window.width)x\(window.height)+\(window.x)+\(window.y)\(frame) \"\(window.title)\"")
            if let png = window.png {
                try? png.write(to: URL(fileURLWithPath: out).appendingPathComponent("\(name)-\(index).png"))
            }
        }
        let text = lines.joined(separator: "\n")
        try? text.write(toFile: out + "/\(name).txt", atomically: true, encoding: .utf8)
        log("--- \(name)\n\(text)")
    }
}

let app = NSApplication.shared
let harness = Harness(arguments: CommandLine.arguments)
app.setActivationPolicy(harness.show ? .regular : .accessory)
Task { @MainActor in await harness.run() }
app.run()
