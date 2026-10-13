# pier: spec (v1)

> Browse, identify and control everything listening on localhost. macOS menu bar app + CLI.

Formerly the `local/` idea. Renamed because `local` is a zsh/bash builtin (builtins win over PATH, so a `local` binary is unreachable).

## Positioning

- **Audience:** public, open source (MIT). Built for my own dev workflow first, then polished for release.
- **Problem:** `lsof` shows `node  4821  *:3011`. With 6 node processes running, you can't tell which project is which, whether it's healthy, or who started it.
- **Differentiator:** answers "which project is this?" (project, framework, title, branch). It also manages processes it launches (logs and restart) and exposes everything to AI agents over MCP.
- **Prior art:** Port Kill, LocalPorts, the Raycast "Kill Port" extension, Portr. These do listing and killing, not identification, managed processes or agent access.

## Form factor

- **Pier.app:** SwiftUI `MenuBarExtra`. The primary UI.
- **`pier` CLI:** companion with full parity plus scripting (`--json`).
- Both are built from one Swift package and share the `PierCore` library.

## Tech + architecture

- **Language:** Swift only. **Target:** macOS 14+. No Linux in v1 (a Linux port of the CLI via `/proc` is possible later).
- **Package layout:** `PierCore` (scan, identify, IPC, config), plus a `pier` CLI target (swift-argument-parser) and a `Pier.app` target.
- **Scanning:** native `libproc` / `proc_pidinfo`, not shelling out to `lsof`.
  - Scans on demand when the popover opens or a CLI command runs.
  - A light 3s background poll keeps the menu bar badge count current.
- **No daemon.** Each `pier run` wrapper owns its child process.
  - It exposes a unix socket at `~/Library/Application Support/pier/run/<pid>.sock` and writes a manifest JSON beside it.
  - The app and CLI discover managed services through these manifests and talk to the sockets.
  - Quitting the app does not kill managed processes.
- **Config:** `~/Library/Application Support/pier/config.json`, shared by the CLI and the app. Holds pins, renames, custom favicons, hotkey, noise filter and notification prefs.
- **Not sandboxed.** It needs libproc, signals and the Docker socket, so the Mac App Store is impossible.

## Service identification (all v1)

| # | Signal | List row | Detail |
|---|--------|:---:|:---:|
| 1 | Process + **cwd → project folder name** | ✓ | ✓ |
| 2 | Framework detection (package.json, cmdline: Next/Vite/Astro/Rails/Django/Flask…) | icon | ✓ |
| 3 | Known infra (Postgres 5432, Redis 6379, Mongo, Supabase local, Ollama 11434…) | ✓ | ✓ |
| 4 | Docker: container port mapped to container/compose service (Docker socket) | ✓ | ✓ |
| 5 | HTTP probe: `<title>` + favicon. Lazy, cached, 300ms timeout | ✓ | ✓ |
| 6 | Git branch of cwd (for worktrees and duplicate instances) | | ✓ |
| 7 | Bind scope: 127.0.0.1 vs 0.0.0.0. If LAN exposed, show LAN IP + QR | LAN badge | ✓ |
| 8 | Protocol sniff: HTTP / HTTPS / WS / gRPC / raw TCP | | ✓ |
| 9 | Health: green 2xx, red 5xx, grey timeout | dot | ✓ |
| 10 | Owner chain: launched by VS Code / iTerm / Terminal / tmux / Claude Code / launchd | | ✓ |
| 11 | Uptime + CPU / RAM | | ✓ |
| 12 | Tunnels: ngrok / cloudflared / Tailscale Funnel public URL | | ✓ |
| 13 | System noise filter (ControlCenter :5000/:7000 AirPlay, rapportd, Spotify…). Hidden by default, toggle to show | | |
| 14 | Runtime version (node 20.11, python 3.12) | | ✓ |

- **Row format:** favicon · title or project · framework icon · `:port` · health dot · LAN badge.
- **Duplicate binds:** IPv4 + IPv6 binds and SO_REUSEPORT duplicates merge into one row per (port, pid).
- **Root/other-user processes:** shown as port + name with a "limited info" label (cwd isn't readable without root).

## Two service classes

- **Discovered:** anything found by the port scan.
  - Supports open, copy, kill, open project, jump to terminal, QR, pin/rename.
  - **Restart** is best-effort. pier captures the cmdline, cwd and env (`ps eww`, own user only), kills the process, then respawns it inside a pier wrapper. The service then becomes **managed** ("adoption"), so logs are available from that point on.
  - **Logs** are unavailable, with a hint: "start via `pier run` for logs".
- **Managed:** started via `pier run`.
  - A PTY wrapper keeps colors working in your terminal and tees output into a ring buffer (~10k lines) served over the socket.
  - Restart is exact, logs are live, and the row gets a "managed" badge.

## Actions (all v1)

1. **Open in browser.** Reuses an existing tab on that port via AppleScript (Chrome, Safari, Arc).
   - Automation permission is requested lazily on first use.
   - If denied, falls back to `open URL`.
2. **Copy URL:** local, LAN or tunnel.
3. **Kill:** SIGTERM, then SIGKILL after a timeout.
   - Dev servers die without a prompt. DBs, Docker and system services ask for confirmation.
   - Root processes use an admin prompt (`osascript … with administrator privileges`). There is no privileged helper.
   - Kill is never offered for PID 1 or filtered system noise.
4. **Restart:** exact for managed services, adoption for discovered ones.
5. **Open project** in VS Code, Cursor or Finder (from the cwd).
6. **Jump to owning terminal:** focus the iTerm, Terminal or VS Code tab that launched the process.
7. **Logs:** managed services only. Shown in a separate resizable window.
8. **Expose:** one-click cloudflared tunnel.
9. **Show QR** for the LAN URL.
10. **Pin / rename / favorite:** custom name and favicon, persisted per project.

## Menu bar UX

- **Icon:** anchor glyph plus a live service count (`⚓ 5`). An amber dot appears if any service is unhealthy.
- **Global hotkey:** `⌥⌘P` (configurable). Opens the popover with search focused. Fuzzy-type a name, Enter to open.
- **Groups:** Pinned → Managed → Projects → Infra (DBs, Docker) → System (collapsed, filtered noise).
- **Row keys:**
  - Click: open
  - `⌘C`: copy URL
  - `⌘⌫`: kill
  - `→` or chevron: detail panel (slides in inside the popover)
- **Notifications** (opt-in, crash-only by default):
  - Managed service crashed.
  - New service started (off by default).

## CLI

```
pier                         # = pier ls
pier ls [--json] [--all]     # port, project, framework, health, uptime; --all includes system noise
pier open <port|name>        # fuzzy match: `pier open haf`
pier kill <port|name>        # SIGTERM → SIGKILL
pier info <port|name>        # full detail view
pier run [-- cmd]            # managed mode; no cmd = package.json "dev" script
pier logs <port|name> [-f]   # managed only
pier restart <port|name>
pier qr <port|name>          # ASCII QR of the LAN URL
pier url <port|name> [--lan|--tunnel]
pier expose <port>           # cloudflared tunnel
pier free [port]             # next free port
pier mcp                     # MCP server (stdio) for Claude Code / agents
pier app install             # copy Pier.app to ~/Applications, enable launch-at-login
```

- `--json` works on every command.
- **MCP tools:**
  - list services
  - service info
  - read logs (managed services)
  - kill and restart
  - find free port

## Distribution (no Apple Developer account, by choice)

- No notarization, which rules out the official `homebrew/cask` and makes a downloaded DMG unattractive because of Gatekeeper friction.
- **Primary install path:** own tap, `brew install stepanblaha/tap/pier`.
  - The formula **builds from source** with `swift build -c release`, producing both the CLI and Pier.app. Needs only the Xcode Command Line Tools.
  - Locally built binaries are never quarantined, so there is no Gatekeeper prompt.
  - `pier app install` copies the app to `~/Applications` and registers launch-at-login via `SMAppService` (ad-hoc signed locally).
- **Secondary install path:** an ad-hoc signed zip on GitHub Releases, with the `xattr -dr com.apple.quarantine` one-liner in the README.
- **Later:** submit the CLI to `homebrew-core` once the repo reaches about 75 stars.

## Milestones

- **M1, Core + CLI**
  - libproc scan.
  - Identification signals 1-3, 7-11, 13, 14.
  - Commands `ls/info/open/kill/url/free/qr` with `--json`.
  - The CLI is useful on its own at this point.
- **M2, Menu bar app**
  - Popover, groups, search and hotkey, detail panel.
  - Pins/rename, QR, open project, jump to terminal, browser tab reuse, health badge.
- **M3, Managed mode + rich identification**
  - `pier run` PTY wrapper, sockets and manifests, logs window.
  - Restart (exact and adoption), crash notifications.
  - Docker mapping (4), HTTP title/favicon probe (5), git branch (6).
- **M4, Agents + ship**
  - `pier mcp`.
  - `pier expose` and tunnel detection (12).
  - Tap formula, README with demo GIF, first release.
- **v1.1:** `pier.yml` stack files (one-click start of a whole stack, e.g. Next + Supabase + worker).

**v1 is done when:** `brew install stepanblaha/tap/pier` works on a clean Mac, and within 30 seconds every running dev server shows up labeled by project, with no Gatekeeper prompt.

## Name check (2026-10-12)

- `pier` is free as both a Homebrew formula and a cask.
- Soft collision: `pier-cli/pier` on GitHub (602★, a Rust shell-script runner, not in brew). Accepted.
- Fallback cask name if needed: `pier-app`.
