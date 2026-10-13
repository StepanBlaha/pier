<p align="center">
  <img src="assets/mascot/saluting.png" alt="pier mascot: a seagull in a sailor hat" width="200">
</p>

<h1 align="center">pier</h1>

<p align="center">
  <b>See what's running on localhost and which project it belongs to.</b><br>
  A macOS menu bar app and CLI to find, identify, open, restart and stop your local dev servers.
</p>

---

`lsof` tells you `node 4821 *:3000`. pier tells you this:

```
$ pier
PORT   NAME                      PROJECT       FRAMEWORK/INFRA  HEALTH  BIND   UPTIME
3000   frontend                  frontend      Next.js          ● ok    LAN    3h
3100   Relay CRM                 relay-crm     Next.js          ● ok    local  11d
4200   LiteLLM API - Swagger UI  codex-router  FastAPI          ● ok    local  15d
11434  Ollama                    -             Ollama           ● ok    local  15d
```

For each listening port, pier works out the **project** (from the process's working directory), the
**framework** (Next.js, Vite, Astro, Rails, Django, FastAPI and more), **infrastructure** (Postgres,
Redis, Ollama, Docker containers), the **page title and favicon**, the **git branch**, its **health**,
whether it's **reachable from your LAN**, and **what started it** (VS Code, iTerm, tmux, Claude Code).

## Install

<img src="assets/mascot/clipboard.png" alt="gull with a clipboard" width="130" align="right">

```bash
brew install stepanblaha/tap/pier
```

The formula builds pier from source with the Xcode Command Line Tools, so macOS never shows a Gatekeeper
warning. Then install the menu bar app:

```bash
pier app install
```

<details>
<summary>Build manually</summary>

```bash
git clone https://github.com/StepanBlaha/pier && cd pier
swift build -c release
ln -sf "$PWD/.build/release/pier" ~/.local/bin/pier   # any directory on your PATH
```

Requires macOS 14+ and Swift 6 (Xcode or the Command Line Tools).
</details>

## Usage

<img src="assets/mascot/standing.png" alt="gull standing" width="130" align="right">

Most commands take a **target**: a port (`3100`) or a fuzzy name (`relay`, `next`, `postgres`).

### Inspect

| Command | What it does |
|---|---|
| `pier` / `pier ls` | Lists everything listening, labeled by project. `--all` includes system noise, `--json` gives JSON |
| `pier watch` | Live `top`-like view. Keys: `o` open · `c` copy · `k` kill · `/` filter · `⏎` details |
| `pier info <target>` | Shows full details: path, branch, runtime, owners, CPU and memory, favicon, command line |
| `pier url <target>` | Prints the URL, pipe-friendly. `--lan` gives the LAN URL, `--tunnel` the public URL |
| `pier stale` | Lists forgotten dev servers: long uptime, idle, no open connections |

### Act

| Command | What it does |
|---|---|
| `pier open <target>` | Opens the service in your browser, switching to an existing tab if one is open. `--editor` opens the project, `--terminal` jumps to the terminal that started it |
| `pier kill <target>` | Stops the service with SIGTERM, then SIGKILL. Asks first for databases, Docker and system services |
| `pier prune` | Stops all stale dev servers after one confirmation. `--dry-run` shows what it would stop |
| `pier qr <target>` | Prints a QR code of the LAN URL in your terminal, for testing on your phone |
| `pier free [port]` | Prints the next free port |

### Managed mode

<img src="assets/mascot/laptop.png" alt="gull on a laptop" width="130" align="right">

When pier starts a service, it can capture logs and restart it exactly.

| Command | What it does |
|---|---|
| `pier run` | Runs your `package.json` `dev` script under pier. `pier run -- python app.py` runs any command |
| `pier logs <target> -f` | Follows a managed service's logs |
| `pier restart <target>` | Restarts a service. A service pier didn't start is taken over so its logs are captured from now on |
| `pier up` / `pier down` | Starts or stops a whole stack defined in [`pier.yml`](docs/pier-yml.md) |

### Share & integrate

| Command | What it does |
|---|---|
| `pier expose <target>` | Gives you a public HTTPS URL through a Cloudflare quick tunnel (needs `cloudflared`) |
| `pier mcp` | Runs an MCP server so Claude Code and other agents can see your services, read logs and restart them |
| `pier completions --install` | Turns on tab completion for live ports and names (zsh, bash, fish) |
| `pier hello` | Shows the pier gull in your terminal, with a random tip |

Every command supports `--json`. Exit codes: `0` ok, `1` not found or error, `2` ambiguous target.

## Menu bar app

<img src="assets/mascot/waving.png" alt="gull waving" width="130" align="right">

Press <kbd>⌥⌘P</kbd> anywhere, type a few letters and hit <kbd>⏎</kbd> to open a service. You can
also pin and rename services, see the details panel, view live logs, show a QR code, open the project in
your editor, jump to its terminal, restart or stop it, or expose it with a tunnel. Optional
notifications tell you when a managed service crashes.

## Use with Claude Code

<img src="assets/mascot/thinking.png" alt="gull thinking" width="130" align="right">

```bash
claude mcp add pier -- pier mcp
```

Then just ask: *"what's running on my machine?"*, *"start the dev server and wait until it's healthy"*,
*"show me the last 50 log lines of relay"*.

## Works in any terminal

<img src="assets/mascot/coffee.png" alt="gull with coffee" width="130" align="right">

Terminal.app, iTerm2, Ghostty, kitty, WezTerm, Warp, Alacritty, VS Code and JetBrains terminals, tmux,
screen and ssh are all supported. pier respects `NO_COLOR`, `FORCE_COLOR` and `TERM=dumb`, uses
only the 16 basic colors so it reads well on light and dark themes, and falls back to ASCII when the
locale isn't UTF-8.

## How it works

- **Discovery** uses native `libproc` calls (no shelling out to `lsof`) and scans all ports in about 0.1s.
- **Identification** combines the process's working directory, its arguments, `package.json`,
  `.git/HEAD`, known infrastructure ports, the Docker Engine API, and a quick HTTP probe for the page
  title and favicon.
- **Managed mode** runs your command in a pseudo-terminal, so colors still work. Output goes to a
  ring buffer served over a unix socket. There's no background daemon.

pier is not sandboxed because it needs process info and signals, so it isn't on the Mac App Store.

## License

[MIT](LICENSE) © Štěpán Bláha
