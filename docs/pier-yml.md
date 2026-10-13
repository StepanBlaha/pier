# pier.yml: stack files

A `pier.yml` describes a set of local services (web app, database, worker, ...). `pier up` starts all of them as
managed services, in dependency order, waiting until each one is ready. `pier down` stops them again.

`pier up` / `pier down` look for `pier.yml`, `pier.yaml`, `.pier.yml` or `.pier.yaml` in the current directory and
then in each parent directory, stopping at `$HOME`. Use `-f FILE` (or a directory) to point at one explicitly.

## Reference

```yaml
name: shop                  # optional; default = folder name of the pier.yml
services:
  web:
    run: pnpm dev            # string or array (see below)
    cwd: ./apps/web          # relative to the pier.yml; default = its directory
    port: 3100               # expected port: readiness + conflict check (optional)
    env: { NODE_ENV: development }
    depends_on: [db]         # list (or a single name)
    ready: http              # http | port | none | "log:<regex>"
    ready_timeout: 60        # seconds, default 60
  db:
    run: [docker, compose, up, postgres]
    port: 5432
```

| Key | Meaning |
|---|---|
| `name` | Stack name. Services are managed as `<name>/<service>`. Letters, digits, `.`, `_`, `-`. |
| `services.<key>.run` | **Required.** String or array of strings. |
| `cwd` | Working directory, relative to the pier.yml directory (`~` allowed). |
| `port` | Port the service will listen on (1-65535, unique per stack). Used for readiness and to detect conflicts. |
| `env` | Extra environment variables, added to your shell's environment. |
| `depends_on` | Services that must be ready first. |
| `ready` | How to know it is up. Default: `port` if `port` is set, else `none`. |
| `ready_timeout` | Seconds to wait for readiness (default 60). |

Unknown keys produce a warning and are ignored.

### `run`

- **Array**: executed as-is, no shell. Use this when you want exact arguments.
- **String**: split like a shell (quotes and backslashes work) and executed directly, **unless** it contains shell
  syntax outside single quotes: `&&`, `||`, `|`, `;`, `&`, `<`, `>`, `$`, backticks, parentheses, or a leading
  `VAR=value`. Then it runs as `/bin/sh -c "<the string>"`.

### `ready`

| Value | Ready when |
|---|---|
| `port` | something accepts TCP connections on `port` |
| `http` | `port` answers HTTP with a status below 500 |
| `log:<regex>` | the service's managed log output matches the regex, e.g. `"log:ready on"` |
| `none` | immediately after it was started |

`http` and `port` need `port:`. If the process exits with an error before it is ready, the service fails right away
and the last log lines are shown.

## What `pier up` does

```
pier up [service...] [-f FILE] [--dry-run] [--json]
```

1. Picks the named services plus everything they depend on (all, when none are named).
2. Orders them into waves: services in one wave are independent and start in parallel.
3. For each service: if `<stack>/<service>` is already running it is left alone ("already running"); if its `port`
   is taken by something else it fails and tells you who holds the port; otherwise it is started and waited for.
4. A failed service makes its dependents "skipped". Independent services still start.
5. Prints a summary table (service, port, state, url). Exit code is non-zero if anything failed or was skipped.

`--dry-run` prints the waves without starting anything. `--json` prints machine-readable results (no progress lines).
Services keep running after `pier up` exits (or you hit Ctrl-C); stop them with `pier down`.
Logs: `pier logs shop/web`.

```
pier down [service...] [-f FILE] [--all-stacks] [--json]
```

Stops the stack's managed services, dependents first. With names, stops only those (their dependencies stay up).
`--all-stacks` stops every stack started with `pier up`, from any directory. Stacks you started are remembered in
`~/Library/Application Support/pier/stacks.json` (the menu bar app lists them).

## Example 1: Next.js + Supabase

```yaml
name: shop
services:
  supabase:
    run: supabase start          # starts Docker containers, then exits
    port: 54321                  # API gateway
    ready: http
    ready_timeout: 180
  web:
    run: pnpm dev
    port: 3000
    depends_on: [supabase]
    ready: http
    env:
      NEXT_PUBLIC_SUPABASE_URL: http://localhost:54321
```

`supabase start` returns once the containers are up, so readiness is judged by the API answering on 54321, not by the
process staying alive. Tear down the containers themselves with `supabase stop`; `pier down` only stops the pier
wrapper.

## Example 2: Vite + FastAPI + Redis (Docker)

```yaml
name: shop
services:
  redis:
    run: docker run --rm --name shop-redis -p 6379:6379 redis:7
    port: 6379
  api:
    run: uv run uvicorn app.main:app --reload --port 8000
    cwd: ./api
    port: 8000
    depends_on: [redis]
    ready: "log:Application startup complete"
    env: { REDIS_URL: "redis://localhost:6379" }
  web:
    run: pnpm dev --port 5173
    cwd: ./web
    port: 5173
    depends_on: [api]
    ready: http
```

`docker run --rm` stays in the foreground, so stopping the service stops the container.

## Errors

Validation reports every problem at once, with the file, line and key path:

```
pier.yml:9: services.web.depends_on: unknown dependency 'dbb' (defined services: db, web)
pier.yml:14: services.api.port: port 3000 is already used by service 'web'
pier.yml:3: services.a.depends_on: dependency cycle: a -> b -> a
```

Public API (for the app and MCP): `StackLoader.load(url:)` / `find(from:)`, `StackPlanner.plan(_:selection:)`,
`StackRunner` (injectable `StackBackend`), `StackRegistry.known()`.
