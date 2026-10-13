# pier: ideas backlog

Beyond SPEC.md v1. ⭐ = strong candidate (high value / low cost or unique).

## CLI power tools

- ⭐ **`pier wait <target|port> [--timeout 60] [--healthy]`**: block until the port is listening (and returns 2xx).
  - For scripts and CI: `pier wait 3000 && playwright test`.
- ⭐ **`pier watch`**: live TUI table, like `top`.
  - Keys: `o` open, `k` kill, `enter` info, `/` search, `a` toggle noise.
- ⭐ **`pier stale [--days 3]` / `pier prune`**: list or kill forgotten dev servers.
  - Criteria: long uptime, idle CPU, no recent traffic. (Right now there are 15-day-old servers.)
- ⭐ **Shell completions** with dynamic targets: `pier kill <TAB>` lists live ports and names.
  - ArgumentParser generates zsh/bash/fish scripts, and a custom completion provider can feed live targets.
- **`pier kill --project relay` / `--owner claude` / `--all-dev`**: bulk kill by filter.
- **`pier ls --owner claude|vscode|iterm`, `--kind infra`, `--project x`**: filters.
- **`pier env <target>`**: print the process environment (own user only), useful for debugging `PORT` or `NODE_ENV`.
- **`pier doctor`**: check Automation permission, Docker socket, cloudflared, and LAN/firewall state.
- **`pier history`**: sqlite log of what ran when (project, port, start/stop), e.g. "what was on 3000 yesterday?".
- **EADDRINUSE shell hook**: a zsh hook spots "address already in use" in output and suggests `pier kill <port>`.

## Ports and URLs

- ⭐ **Port registry**: each project gets a stable port, stored in config.
  - `next dev -p $(pier port)` resolves the port from the cwd's project.
  - `pier port --conflicts` detects overlaps.
  - Ends the "relay and haf-pet both want 3000" problem.
- ⭐ **`*.localhost` proxy**: `relay.localhost` → :3100.
  - Browsers resolve `*.localhost` to loopback natively, so no DNS hacks are needed.
  - Gives stable URLs whatever the port, which keeps cookies and OAuth callbacks stable.
  - Optional local HTTPS with a trusted local CA, mkcert-style.
  - Similar to puma-dev, Laravel Valet and portless.
- **Bonjour/mDNS share**: advertise `relay.local` on the LAN so phones get a name instead of an IP.
- **`pier open --sim`**: open in the booted iOS Simulator (`xcrun simctl openurl booted`). `--android` via adb.
- **Request log / req-per-second**: comes free once the proxy exists. Shows live traffic per service in the menu bar.

## Smarter restart and logs (without `pier run`)

- ⭐ **launchd-owned services**: exact restart via `launchctl kickstart -k`, logs via the plist's StandardOutPath.
  - For example, codex-router is launchd-managed.
- ⭐ **`brew services`**: restart and logs for Homebrew Postgres, Redis and similar.
- ⭐ **Docker**: logs via `docker logs -f` and restart via `docker restart`.
  - Also group by compose project, and show container ports that are *not* published.
- **Supervisor detection**: pm2, overmind, foreman. Delegate restart and logs to them.

## Menu bar app extras (M2+)

- **Hover thumbnail**: live page preview from an offscreen WKWebView snapshot.
- **"Ready" notification**: e.g. "relay-crm ready on :3100" when health flips to ok after `next dev` compiles. Optionally auto-open the browser.
- **CPU sparkline** per service, plus a warning on battery when a forgotten server is hogging CPU.
- **Per-project color/emoji**, set when pinning.
- **App Intents / Shortcuts / Siri**: "Kill port 3000", "Open relay".
- **URL scheme** (`pier://open/relay`) and a desktop **widget**.

## Agents (M4+)

- ⭐ **Claude Code cleanup hook**: a `SessionEnd` hook runs `pier kill --owner claude --session <id>`.
  - Servers an agent started die with the session, since the owner chain already identifies Claude Code.
- **MCP tools**:
  - `wait_for_healthy`
  - `fetch_page` (title, status, console errors)
  - `screenshot`
  - `free_port`
  - `logs` (managed, launchd, docker)
- **`pier ls --json` contract**: versioned schema, so Raycast/Alfred extensions can be built cheaply on top.

## Ecosystem

- **Raycast extension** that wraps `pier --json`. Small effort, big audience.
- **Alfred workflow.**
- **`pier ls --host <ssh-host>`**: scan a remote Mac or Linux box over SSH, which needs the Linux `/proc` backend.

## Security

- ⭐ **`pier audit`**: warn about services bound to 0.0.0.0 while on untrusted Wi-Fi.
  - Flags unauthenticated databases exposed on the LAN, checks firewall state, and prints a one-line fix per service.
- **LAN-exposure badge turns red** when on a public network (SSID not in a trusted list).
