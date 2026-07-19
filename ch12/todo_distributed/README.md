# Todo Env — Chapter 11

This project builds on `todo_web`. The HTTP interface, Poolboy pool, cache, registry, and metrics stay the same; the change is **moving hard-coded settings into [runtime config](https://hexdocs.pm/elixir/Config.html#module-config-provider)** so they can vary by Mix env and OS environment variables.

## The Goal: Configure Without Recompiling

In `todo_web`, the HTTP port (`5454`) and database folder (`./persist`) lived in the source. That works until you need a different port for tests while IEx is running, a separate persist dir so tests do not wipe the dev DB, or a shorter idle timeout in local development.

`config/runtime.exs` runs every time the app starts (after compilation). It reads env vars with sensible defaults, then sets Application config that the OTP children fetch at start time.

## The Fix: `config/runtime.exs` + `Application.fetch_env!/2`

Three settings are externalized:

| Setting | App config | Env var (non-test) | Default |
|---|---|---|---|
| HTTP port | `:todo, :http_port` | `TODO_HTTP_PORT` | `5454` |
| DB folder | `:todo, :database, :db_folder` | `TODO_DB_FOLDER` | `./persist` |
| Server idle expiry | `:todo, :todo_server_expiry` | `TODO_SERVER_EXPIRY` | `60` s (`10` s in `:dev`) |

In `:test`, the port and folder use separate vars/defaults (`TODO_TEST_HTTP_PORT` → `5455`, `TODO_TEST_DB_FOLDER` → `./test_persist`) so tests can run alongside a live IEx session without colliding.

`Todo.Web` and `Todo.Database` read config instead of constants:

```elixir
# Todo.Web
Plug.Cowboy.child_spec(
  scheme: :http,
  options: [port: Application.fetch_env!(:todo, :http_port)],
  plug: __MODULE__
)

# Todo.Database
db_folder = Keyword.fetch!(Application.fetch_env!(:todo, :database), :db_folder)
```

`Todo.Server` also picks up idle expiry from config (GenServer timeouts on each handle, stop on `:timeout`):

```elixir
defp expiry_idle_timeout(), do: Application.fetch_env!(:todo, :todo_server_expiry)
```

A few things worth noting:

- **`runtime.exs` is not compile-time.** Changing env vars and restarting is enough; no need to recompile.
- **Mix env drives defaults.** Test gets an isolated port and folder; dev gets a short server expiry for quicker demos.
- **Callers stay the same.** Routes, cache, and Poolboy workers do not care where the values came from.

## Process Tree

Same shape as `todo_web`; only the sources of port / folder / expiry changed:

```
Todo.Application  (OTP application callback)
└── Todo.System  (Supervisor :one_for_one)
      ├── Todo.Metrics  (Task — loops forever, prints metrics every 10s)
      ├── Todo.ProcessRegistry  (Registry — name→pid for servers, not DB workers)
      ├── Todo.Database  (Poolboy pool, size: 3 — folder from config)
      │     ├── DatabaseWorker
      │     ├── DatabaseWorker
      │     └── DatabaseWorker
      ├── Todo.Cache  (DynamicSupervisor :one_for_one)
      │     ├── Todo.Server "alice"   (idle timeout from config, restart: :temporary)
      │     ├── Todo.Server "bob"
      │     └── ... (children added on demand)
      └── Todo.Web  (Plug.Cowboy — port from config)
```

## What Changed vs `todo_web`

| File | Before (`todo_web`) | After (`todo_env`) |
|---|---|---|
| `config/runtime.exs` | — | new — port, db folder, server expiry |
| `Todo.Web` | hard-coded port `5454` | `Application.fetch_env!(:todo, :http_port)` |
| `Todo.Database` | `@db_folder "./persist"` | folder from `:todo, :database` |
| `Todo.Server` | no idle timeout | expiry from `:todo, :todo_server_expiry` |
| `test/http_server_test.exs` | — | Plug.Test coverage for routes |
| `test/test_helper.exs` | plain `ExUnit.start()` | clears configured test db folder first |

## Try It

```bash
# Terminal 1 — defaults (port 5454, ./persist)
iex -S mix

# Or override:
TODO_HTTP_PORT=8080 TODO_DB_FOLDER=./my_data iex -S mix

# Terminal 2
curl -d '' 'http://localhost:5454/add_entry?list=bob&date=2018-12-19&title=Dentist'
curl 'http://localhost:5454/entries?list=bob&date=2018-12-19'
```

### Run tests (isolated port / folder)

```bash
mix test
# uses port 5455 and ./test_persist by default
```

### Load test with wrk

Same as `todo_web`. Delete `persist/` first, start in prod, then run wrk from another shell:

```bash
# Terminal 1 — delete persist/, then:
MIX_ENV=prod iex -S mix

# Terminal 2
wrk -t4 -c28 -d30s --latency -s wrk.lua http://localhost:5454
```
