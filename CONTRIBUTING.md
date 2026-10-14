# Contributing to pier

Thanks for helping the gull keep watch. Bug reports, ideas and pull requests are all welcome.

## Reporting bugs and ideas

- **Bugs:** open an issue with the *Bug report* template. Include `pier --version`, your macOS version,
  your terminal, and the output of the failing command (add `--json` where it helps).
  Please replace project names or paths you don't want public.
- **Ideas:** check [docs/IDEAS.md](docs/IDEAS.md) first, then open a *Feature request*.
- **Security issues:** don't open a public issue. See [SECURITY.md](SECURITY.md).

## Building

Requirements: macOS 14+, Swift 6 (Xcode 16+ or the Command Line Tools).

```bash
git clone https://github.com/StepanBlaha/pier && cd pier
swift build                      # CLI (pier) and menu bar app (PierApp)
swift test                       # the whole suite
.build/debug/pier ls             # try the CLI
.build/debug/pier app install    # build Pier.app from your checkout into ~/Applications
```

## Project layout

| Path | What lives there |
|---|---|
| `Sources/PierCore/` | Everything shared: scanning (`Scan/`), identification (`Identify/`), HTTP probing (`Probe/`), managed mode (`Managed/`), stacks, MCP, Docker, tunnels, config, the terminal mascot |
| `Sources/pier/` | The CLI (swift-argument-parser commands, terminal rendering, `pier watch`) |
| `Sources/PierApp/` | The SwiftUI menu bar app |
| `Tests/PierCoreTests/` | Unit and end-to-end tests |
| `packaging/` | App bundle, icon, Homebrew formula template, release scripts |
| `tools/` | Asset generators (terminal mascot art, README terminal screenshots) |
| `docs/` | `pier.yml` reference, the original spec, the ideas backlog |
| `site/` | The landing page at [stepanblaha.github.io/pier](https://stepanblaha.github.io/pier/) (Next.js static export, deployed by `.github/workflows/site.yml`) |

## Pull requests

1. Keep changes focused; one feature or fix per PR.
2. Add or update tests in `Tests/PierCoreTests/`. Logic that the app uses belongs in `PierCore`,
   where it can be tested.
3. Run `swift test` before pushing. CI runs the same on macOS.
4. The CLI must work in any terminal: use the `Term` helpers for output (colors, glyphs, width) and
   `Term.clean` for anything that comes from outside (page titles, process names).
5. Never kill or restart processes you didn't start in tests. Use throwaway servers
   (`python3 -m http.server`) and clean them up.
6. Describe user-visible changes in [CHANGELOG.md](CHANGELOG.md) under *Unreleased*.

## Releasing (maintainers)

1. Bump `Sources/PierCore/Version.swift` and move *Unreleased* in the changelog under the new version.
2. Commit, then `git tag vX.Y.Z && git push origin vX.Y.Z`. The release workflow builds and publishes the app zip.
3. Run `packaging/release.sh` to update the Homebrew formula.

By contributing you agree that your work is released under the [MIT license](LICENSE), and to follow
the [code of conduct](CODE_OF_CONDUCT.md).
