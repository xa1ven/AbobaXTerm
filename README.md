# AbobaXTerm
Любительский порт Мобы на мак

Personal native macOS SSH client: saved sessions, tabbed terminal (SwiftTerm),
SFTP side panel and X11 forwarding. Not for distribution.

## Requirements

- macOS 26+, Xcode 27+
- `brew install xcodegen`
- XQuartz for X11 (`brew install --cask xquartz`, then log out and back in)

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
- X11: sessions with "X11 forwarding" run `ssh -Y -o XAuthLocation=/opt/X11/bin/xauth` (macOS ssh
  otherwise looks for xauth in `/usr/X11R6`, which does not exist). DISPLAY is the launchd socket
  XQuartz registers at login, so XQuartz starts on the first X window; without it the app launches
  XQuartz and uses `:0`. X11 sessions use a separate master (`cm-<id>-x-…`), because a master forwards
  X11 to the DISPLAY it was started with.
- Data: `~/Library/Application Support/AbobaXTerm/sessions.json` (+ `.bak`).

## Integration test (optional)

`AskpassEndToEndTests` runs real ssh + askpass against a local throwaway sshd; it is skipped unless
`ABX_E2E_SSHD_PORT`, `ABX_E2E_AUTHORIZED_KEYS` and `ABX_E2E_HELPER` are set (see the test file).
`SFTPIntegrationTests` does the same for SFTP (`ABX_E2E_SFTP_PORT`, `ABX_E2E_SFTP_KEY`,
`ABX_E2E_SFTP_KNOWN_HOSTS`, `ABX_E2E_SFTP_DIR`).
