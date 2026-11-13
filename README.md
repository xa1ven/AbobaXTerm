# AbobaXTerm
Любительский порт Мобы на мак

Personal native macOS SSH client: saved sessions, tabbed terminal (SwiftTerm),
SFTP side panel and a built-in X11 display. Fan-made, not affiliated with Mobatek.
Free for personal use, not for sale: see [LICENSE](LICENSE). Site: https://abobaxterm.site

## Requirements

- macOS 26+, Xcode 27+
- `brew install xcodegen`

X11 needs nothing installed: the X server is inside the app (no XQuartz).

## Build

```sh
make            # generate AbobaXTerm.xcodeproj from project.yml and build (Debug)
make run        # build and launch
make test       # unit tests of the Swift package
make open       # open the generated project in Xcode
make xserver    # rebuild the bundled X server from X.org sources (rarely needed)
```

`Vendor/xserver` holds the X server that goes into the app (`Xvfb`, `xkbcomp`, keyboard data). It is
built by `Scripts/build-xserver.sh` from pinned X.org source releases, statically linked, and committed,
so a normal build does not compile it again. The script needs only the Xcode command line tools and
network access; it sets up its own meson/ninja/pkgconf under `build/` and installs nothing system-wide.

`AbobaXTerm.xcodeproj` is generated from `project.yml` and is not committed.
On the first build in Xcode, allow the SwiftTerm build plugin ("Trust & Enable").

## Layout

```
App/                         app target (entry point, Info.plist, assets)
Scripts/build-xserver.sh     builds Vendor/xserver from X.org sources
Vendor/xserver/              bundled X server: bin/Xvfb, bin/xkbcomp, share/X11/xkb (see VERSIONS)
Packages/AbobaXTermKit/      all logic, as a local Swift package
  Sources/AXL10n             interface language (English/Russian): L("English text") lookup, Russian.swift dictionary
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
- A session summary is printed once ssh has signed in: the text is written to
  `/tmp/abx-<uid>/banner-*.txt` and ssh shows it with `LocalCommand` (`cat`), before anything the
  server says. A mux client runs no `LocalCommand`, and a `LocalCommand` of the user must not be
  replaced, so in both cases the tab prints the summary itself before starting ssh.
- A local tab starts with a card (`LocalBanner` in AXSSH): shell, system OpenSSH and agent keys,
  the app's shortcuts and a note about the app. The address in it is an OSC 8 link, opened with ⌘-click.
- Paste goes through `PastePolicy` (AXTerminal): text with a line break opens an editor sheet,
  and `PasteSanitizer` turns chat-app typography (curly quotes, long dashes) back into ASCII.
  Full-screen programs (alternate screen) get several lines without the sheet.
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
  (override-redirect windows) become borderless panels. The server is our own static build of X.org
  `Xvfb` in `Contents/Resources/xserver` (core fonts: only the built-in `fixed` and `cursor`; no GLX).
  It runs `./xkbcomp` relative to its working directory, so the app works from any location.
- ssh side of X11: `ssh -Y` with `DISPLAY=:N` (N from 41 up) and `-o XAuthLocation=/tmp/abx-<uid>/abx-xauth`,
  a generated script that answers `xauth list` with the server's cookie. Display number and cookie are
  kept in `/tmp/abx-<uid>/x11-state`, so a ControlMaster that outlives the app keeps working. X11 sessions
  use a separate master (`cm-<id>-x-…`), because a master forwards X11 to the DISPLAY it was started with.
- Keyboard for X11: keycodes follow the Linux convention (evdev scancode + 8), so VM consoles and other
  programs that forward raw keys get the right ones; keysyms are built from the Mac layouts (Latin as
  group 1, the current non-Latin layout as group 2) and follow input-source switches. Control = Control,
  Option = Alt, Command = Super.
- Command shortcuts in X11 windows (Settings > X11, on by default): ⌘C/V/X/A/Z are sent the way the
  program expects, chosen by its WM_CLASS: Control+key for regular programs; Control+Shift+C/V for
  modern terminals; for classic ones (xterm, rxvt) ⌘C copies the PRIMARY selection to the pasteboard
  and ⌘V offers the pasteboard as PRIMARY and sends Shift+Insert. Control+C is never sent to a
  terminal. Other Command combinations go through as Super; the Super press is held back until it is
  clear what Command is used for, so programs see no stray Super tap.
- Retina for X11: the server runs at device-pixel resolution and the app acts as XSETTINGS manager
  (`Gdk/WindowScalingFactor`, `Xft/DPI`, plus `Xft.dpi` in the root RESOURCE_MANAGER), so GTK/Qt programs
  draw at 2x. Settings > X11 turns this off for programs that cannot scale. The root size and scale are
  fixed per server run: after a change the server restarts once no X window is open.
- Clipboard for X11: text is mirrored between the Mac pasteboard and the X CLIPBOARD selection (taken over
  when an X window becomes key; fetched whenever an X program copies, INCR transfers included).
- Data: `~/Library/Application Support/AbobaXTerm/sessions.json` (+ `.bak`).

## Integration test (optional)

`AskpassEndToEndTests` runs real ssh + askpass against a local throwaway sshd; it is skipped unless
`ABX_E2E_SSHD_PORT`, `ABX_E2E_AUTHORIZED_KEYS` and `ABX_E2E_HELPER` are set (see the test file).
`SFTPIntegrationTests` does the same for SFTP (`ABX_E2E_SFTP_PORT`, `ABX_E2E_SFTP_KEY`,
`ABX_E2E_SFTP_KNOWN_HOSTS`, `ABX_E2E_SFTP_DIR`).
