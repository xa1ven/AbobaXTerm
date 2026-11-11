# AbobaXTerm
Любительский порт Мобы на мак

Personal native macOS SSH client: saved sessions, tabbed terminal (SwiftTerm),
SFTP side panel and a built-in X11 display. Not for distribution.

## Requirements

- macOS 26+, Xcode 27+
- `brew install xcodegen`
- For X11, until the X server is bundled with the app: the `Xvfb` binary from XQuartz
  (`/opt/X11/bin/Xvfb`). XQuartz itself is never launched.

## Build

```sh
make            # generate AbobaXTerm.xcodeproj from project.yml and build (Debug)
make run        # build and launch
make test       # unit tests of the Swift package
make open       # open the generated project in Xcode
```

`AbobaXTerm.xcodeproj` is generated from `project.yml` and is not committed.
On the first build in Xcode, allow the SwiftTerm build plugin ("Trust & Enable").

## Layout

```
App/                         app target (entry point, Info.plist, assets)
Packages/AbobaXTermKit/      all logic, as a local Swift package
  Sources/AXModels           Session, Folder, SessionLibrary, quick-connect parsing
  Sources/AXStorage          JSON repository, Keychain, ~/.ssh key scanner
  Sources/AXAskpassProtocol  wire protocol + Unix socket helpers
  Sources/AXSSH              ssh argv builder, askpass broker, ControlMaster, ssh -G
  Sources/AXTerminal         SwiftTerm view + terminal tab lifecycle, output highlighting
  Sources/AXSFTP             SFTP v3 client over an ssh channel (pipelined transfers)
  Sources/AXX11              built-in X11 display: X protocol client, window manager, compositor, input
  Sources/abx-x11-harness    development tool: runs AXX11 against a command, dumps windows as PNG
  Sources/AXEditor           code editor view (TextKit 1) + regex syntax highlighting
  Sources/AXUI               SwiftUI/AppKit: sidebar, session editor, tabs, file panel, remote editor
  Sources/abx-askpass        SSH_ASKPASS helper embedded in the .app
```

## How connections work

- Every tab runs `/usr/bin/ssh` in a PTY, so `~/.ssh/config`, ssh-agent and ProxyJump work as usual.
- `ControlMaster=auto` with sockets in `/tmp/abx-<uid>/` (Unix socket paths are limited to 104 bytes).
  Masters are closed when the app quits.
- The file panel waits for the master (`ssh -O check`), then opens the `sftp` subsystem as an extra
  channel of it (`ControlMaster=no`, `BatchMode=yes`), so it never authenticates separately.
  The SFTP client is our own (AXSFTP): requests are pipelined, 16 × 64 KiB in flight.
- Remote editor: double-click a file; ⌘S writes it back in place (owner and mode are kept).
  Size and mtime are compared with the loaded version before saving and when the window becomes active.
- Passwords live only in the Keychain. ssh asks for secrets through `abx-askpass`
  (`SSH_ASKPASS_REQUIRE=force`); the helper forwards the prompt to the app over a private Unix socket,
  and the app answers from the Keychain or shows a native dialog. Saved passwords are only auto-filled
  when the prompt names the session's own host, never a jump host.
- X11: the app has its own X display. A headless X.org server (`Xvfb`) runs as a hidden child process,
  started with the first session that has "X11 forwarding" on; `AXX11` connects to it as window manager
  and compositor. Every top-level X window lives in an off-screen pixmap (Composite), is mirrored into a
  native `NSWindow` on damage, and gets the user's mouse and keyboard through XTEST. Menus and tooltips
  (override-redirect windows) become borderless panels.
- ssh side of X11: `ssh -Y` with `DISPLAY=:N` (N from 41 up) and `-o XAuthLocation=/tmp/abx-<uid>/abx-xauth`,
  a generated script that answers `xauth list` with the server's cookie. Display number and cookie are
  kept in `/tmp/abx-<uid>/x11-state`, so a ControlMaster that outlives the app keeps working. X11 sessions
  use a separate master (`cm-<id>-x-…`), because a master forwards X11 to the DISPLAY it was started with.
- Keyboard for X11: keycode = Mac virtual key code + 8; the keymap is built from the Mac layouts (Latin as
  group 1, the current non-Latin layout as group 2) and follows input-source switches. Control = Control,
  Option = Alt, Command = Super.
- Data: `~/Library/Application Support/AbobaXTerm/sessions.json` (+ `.bak`).

## Integration test (optional)

`AskpassEndToEndTests` runs real ssh + askpass against a local throwaway sshd; it is skipped unless
`ABX_E2E_SSHD_PORT`, `ABX_E2E_AUTHORIZED_KEYS` and `ABX_E2E_HELPER` are set (see the test file).
`SFTPIntegrationTests` does the same for SFTP (`ABX_E2E_SFTP_PORT`, `ABX_E2E_SFTP_KEY`,
`ABX_E2E_SFTP_KNOWN_HOSTS`, `ABX_E2E_SFTP_DIR`).
