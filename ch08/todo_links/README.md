# Supervised Todo Cache — Chapter 8

This project extends the todo cache from previous chapters by placing `Todo.Cache` under an OTP `Supervisor`. The supervisor monitors the cache process and automatically restarts it if it crashes, making the system fault-tolerant without any manual intervention.

## Process Tree

```
Supervisor (:one_for_one)
└── Todo.Cache (GenServer, registered by name)
    ├── Todo.Database (GenServer, started by Cache on init)
    │   ├── Todo.DatabaseWorker #0 (GenServer)
    │   ├── Todo.DatabaseWorker #1 (GenServer)
    │   └── Todo.DatabaseWorker #2 (GenServer)
    └── Todo.Server per list (GenServer, started on demand)
```

## How It Works

- **`Todo.Cache`** — the central registry. It maps todo-list names to their `Todo.Server` PIDs. On first access it spawns a new server; on subsequent calls it returns the cached PID.
- **`Todo.Database`** — a pool coordinator. It hashes the list name with `:erlang.phash2/2` to consistently route reads and writes to one of 3 `DatabaseWorker` processes, avoiding write contention.
- **`Todo.DatabaseWorker`** — performs the actual file I/O. Writes are async (`cast`), reads are sync (`call`). Data is serialized with `:erlang.term_to_binary/1` and persisted under `./persist/`.
- **`Todo.Server`** — holds the in-memory state for a single named todo list. On startup it fetches its list from the database via `handle_continue/2` (deferred init), so the cache is never blocked during disk reads.
- **`Todo.List`** — a pure data structure (no process). Provides add/filter/update/delete operations on entries stored in a map keyed by auto-incrementing IDs.

## How the Supervisor Knows How to Start a Child

When you call:

```elixir
Supervisor.start_link([Todo.Cache], strategy: :one_for_one)
# or equivalently:
Supervisor.start_link([{Todo.Cache, nil}], strategy: :one_for_one)
```

the supervisor needs a **child specification** — a map that tells it _how_ to start, stop, and restart the child. It gets this by calling `Todo.Cache.child_spec(nil)` on each entry in the list.

`child_spec/1` is automatically injected into `Todo.Cache` by `use GenServer`. The generated default looks roughly like:

```elixir
def child_spec(init_arg) do
  %{
    id: Todo.Cache,
    start: {Todo.Cache, :start_link, [init_arg]},
    restart: :permanent,
    shutdown: 5000,
    type: :worker
  }
end
```

So `Todo.Cache` in the list is shorthand for `{Todo.Cache, nil}`, which is shorthand for the full child spec map above. The supervisor stores this spec and uses it every time it needs to (re)start the child — calling `Todo.Cache.start_link(nil)` under the hood.

You can override `child_spec/1` in your module if you need custom restart behaviour, a different shutdown timeout, or to classify the process as a `:supervisor` instead of a `:worker`.

## Supervisor Strategy: `:one_for_one`

With `:one_for_one`, if a child process crashes only **that** process is restarted — siblings are left untouched. Here `Todo.Cache` is the only direct child, so a crash restarts the cache (and triggers a fresh `Todo.Database` startup inside `init/1`) without affecting any other part of the system.

## Try It in IEx

```elixir
# Start the supervision tree
{:ok, sup} = Supervisor.start_link([Todo.Cache], strategy: :one_for_one)

# Get (or create) a server for "bob"
bobs_list = Todo.Cache.server_process("bob's list")

# Add an entry
Todo.Server.add_entry(bobs_list, %{date: ~D[2023-12-19], title: "Dentist"})

# Read entries back
Todo.Server.entries(bobs_list, ~D[2023-12-19])

# Kill the cache — the supervisor restarts it automatically
cache_pid = Process.whereis(Todo.Cache)
Process.exit(cache_pid, :kill)

# After restart, the cache is alive again under the same name
Process.whereis(Todo.Cache)
```
