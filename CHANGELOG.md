# Changelog

All notable changes to pier. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/)
and versions follow [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added
- Landing page at https://stepanblaha.github.io/pier/ (source in `site/`).

## [0.1.2] - 2026-10-13

### Added
- `pier help` greets you with the saluting gull and a speech bubble (interactive terminals only; piped
  help stays plain, `PIER_NO_MASCOT=1` hides it).

### Changed
- No em or en dashes anywhere in output, docs or screenshots.

### Fixed
- Help examples were misaligned by one column.

## [0.1.1] - 2026-10-13

### Fixed
- `pier hello` linked to a misspelled GitHub URL.

### Changed
- Help text, tips and docs use generic example names.
- README rewrite with screenshots, badges and the gull; new CONTRIBUTING, CODE_OF_CONDUCT, SECURITY
  and issue templates.

## [0.1.0] - 2026-10-13

First release.

- **CLI:** `ls`, `watch`, `info`, `url`, `open`, `stop`, `kill`, `stale`, `prune`, `qr`, `free`, `run`,
  `logs`, `restart`, `up`, `down`, `expose`, `mcp`, `app`, `config`, `pin`, `rename`, `completions`, `hello`.
- **Identification:** project, framework, infrastructure, Docker containers, page title and favicon,
  git branch, health, LAN exposure, owning terminal or editor, tunnels.
- **Managed mode:** `pier run` with logs and exact restarts, adoption of running servers, `pier.yml` stacks.
- **Menu bar app:** project grouping, hover actions, details panel, logs window, stacks, Run…,
  stale clean-up, pins and renames, crash notifications, ⌥⌘P hotkey.
- **MCP server** for Claude Code and other agents.
- Works in any terminal, with a pixel-art gull that degrades to ASCII.

[Unreleased]: https://github.com/StepanBlaha/pier/compare/v0.1.2...HEAD
[0.1.2]: https://github.com/StepanBlaha/pier/compare/v0.1.1...v0.1.2
[0.1.1]: https://github.com/StepanBlaha/pier/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/StepanBlaha/pier/releases/tag/v0.1.0
