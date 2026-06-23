# Supervise Database — Chapter 9

This project builds on `todo_links` (ch08). The linking story is already solved — every child is started with `start_link`. The new focus is **supervision granularity**: moving `Todo.Database` out of `Todo.Cache` and directly under the top-level supervisor so that crashes in the database subtree don't tear down the entire cache.

## The Problem: Over-coupled Crash Scope

In `todo_links`, `Todo.Cache.init/1` starts the database:

```elixir
# todo_links — database is a child of the cache
def init(_) do
  Todo.Database.start_link()
  {:ok, %{}}
end
```

Because `Todo.Database` is linked to `Todo.Cache`, a failure anywhere in the database subtree propagates upward:

```
DatabaseWorker crash
  → Todo.Database crashes
    → Todo.Cache crashes (linked)
      → Supervisor restarts Todo.Cache
        → Every active Todo.Server is killed
```

A transient disk error in a single worker wipes out all in-flight todo sessions — far more disruption than necessary.

## The Fix: Sibling Supervision

`supervise_database` removes the `Todo.Database.start_link()` call from `Todo.Cache.init/1` and registers `Todo.Database` as a **sibling** child of the supervisor:

```elixir
# Todo.System
Supervisor.start_link(
  [
    Todo.Database,  # ← now a direct supervisor child
    Todo.Cache
  ],
  strategy: :one_for_one
)
```

With `:one_for_one`, each child is restarted independently. A crash in `Todo.Database` (or any of its workers) only restarts the database subtree — `Todo.Cache` and all its `Todo.Server` processes stay alive.

## Process Tree

```
Supervisor (:one_for_one)
├── Todo.Database
│     ├───(linked)──> DatabaseWorker #0
│     ├───(linked)──> DatabaseWorker #1
│     └───(linked)──> DatabaseWorker #2
└── Todo.Cache
      ├───(linked)──> Todo.Server "alice"
      ├───(linked)──> Todo.Server "bob"
      └─── ...
```

**Legend:**
- `───(linked)──>` — process started with `start_link`; a crash in either direction terminates both.
- `Todo.Database` and `Todo.Cache` are siblings under the supervisor. Crashing one does **not** affect the other.

## Crash Isolation in Practice

| What crashes | What gets restarted | What survives |
|---|---|---|
| `DatabaseWorker` | `DatabaseWorker` → `Todo.Database` (and its workers) | `Todo.Cache` + all `Todo.Server`s |
| `Todo.Cache` | `Todo.Cache` (and all its `Todo.Server`s) | `Todo.Database` + its workers |
| `Todo.Server "alice"` | `Todo.Server "alice"` only | Everything else |

## What Changed vs `todo_links`

| File | Before (`todo_links`) | After (`supervise_database`) |
|---|---|---|
| `Todo.Cache.init/1` | calls `Todo.Database.start_link()` | removed — database is no longer a cache child |
| `Todo.System.start_link/0` | supervises only `Todo.Cache` | supervises both `Todo.Database` and `Todo.Cache` |

## Try It in IEx

```elixir
# Start the supervision tree
{:ok, sup} = Todo.System.start_link()

# Get (or create) a server for "bob"
bobs_list = Todo.Cache.server_process("bob's list")

# Add an entry
Todo.Server.add_entry(bobs_list, %{date: ~D[2023-12-19], title: "Dentist"})

# Kill a DatabaseWorker — only the database subtree restarts
db_pid = Process.whereis(Todo.Database)
Process.exit(db_pid, :kill)

# Cache and Todo.Server for "bob" are still alive
Process.whereis(Todo.Cache)   # still the same PID
bobs_list                     # still valid
```
