# Security policy

pier inspects processes, sends signals, can expose a local port to the internet (`pier expose`) and
runs an MCP server that lets AI agents control local services. Security reports are taken seriously.

## Supported versions

Only the latest release gets fixes.

## Reporting a vulnerability

Please **don't open a public issue**. Report privately through
[GitHub's private vulnerability reporting](https://github.com/StepanBlaha/pier/security/advisories/new).

Include what you found, how to reproduce it and the impact you see. You'll get a reply within a few
days, and a fix and advisory as soon as possible.

## Things that are in scope

- Escaping the confirmation required to stop databases, Docker or system services (CLI, app or MCP).
- Injecting terminal escape sequences or other content through page titles, process names or container names.
- The managed-mode unix sockets or files in `~/Library/Application Support/pier` being readable or
  writable by other users.
- `pier expose` exposing something other than the service you asked for.
