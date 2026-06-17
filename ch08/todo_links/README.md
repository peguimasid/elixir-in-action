# Todo Links — Chapter 8

This project builds directly on `supervised_todo_cache`. The supervision tree and overall architecture are identical — the only change is replacing every bare `start` call with `start_link` so that child processes are **linked** to the process that spawned them.

## The Problem: Dangling Processes

In `supervised_todo_cache`, `Todo.Cache` starts its children with plain `start`:

```elixir
# supervised_todo_cache — no link
Todo.Database.start()
{:ok, new_server} = Todo.Server.start(todo_list_name)
```

`start` spawns the child but does **not** create a process link. If `Todo.Cache` crashes and the supervisor restarts it:

- `init/1` runs again and starts a brand-new `Todo.Database`
- The old `Todo.Database` (and its 3 workers) keeps running as an **orphan** — no owner, never restarted, never cleaned up
- Every `Todo.Server` that was spawned on demand also keeps running as an orphan, holding stale state and wasting memory

Over time this leaks processes and can cause subtle bugs (e.g. two databases racing to write the same file).

## The Fix: `start_link`

`todo_links` switches every child startup to `start_link`:

```elixir
# todo_links — linked
Todo.Database.start_link()
{:ok, new_server} = Todo.Server.start_link(todo_list_name)
```

`start_link` creates a **bidirectional link** between the caller and the spawned process. Links propagate exits: if either end crashes, the other receives an exit signal and terminates as well (unless it is trapping exits).

With links in place:

- If `Todo.Cache` crashes → the exit signal travels down the link to `Todo.Database`, which terminates; `Todo.Database`'s own exit signal propagates to each of its 3 `DatabaseWorker` processes, which also terminate. Every `Todo.Server` linked to the cache terminates too. No orphans survive.
- The supervisor then restarts `Todo.Cache` fresh, which re-runs `init/1` and starts a clean `Todo.Database` with clean workers.
- If a `Todo.DatabaseWorker` crashes → the exit propagates up to `Todo.Database`, which crashes, which propagates up to `Todo.Cache`, which crashes, and the supervisor restarts the whole subtree cleanly.

## Process Tree

```
Supervisor (:one_for_one)
└── Todo.Cache
    ├───(linked)──> Todo.Database
    │                   ├───(linked)──> DatabaseWorker #0
    │                   ├───(linked)──> DatabaseWorker #1
    │                   └───(linked)──> DatabaseWorker #2
    ├───(linked)──> Todo.Server "alice"
    ├───(linked)──> Todo.Server "bob"
    └─── ...
```

**Legend:**
- Arrows (`───(linked)──>`) show processes started with `start_link`, meaning they are linked to their parent.
- If any process in a subtree crashes, all its linked children are terminated with it—no orphaned processes remain.

Every arrow is a `start_link` link. A crash anywhere in the tree tears down the entire subtree — and nothing is left dangling.

## What Changed vs `supervised_todo_cache`

| File | Before (`supervised_todo_cache`) | After (`todo_links`) |
|---|---|---|
| `Todo.Cache.init/1` | `Todo.Database.start()` | `Todo.Database.start_link()` |
| `Todo.Cache.handle_call/3` | `Todo.Server.start(name)` | `Todo.Server.start_link(name)` |

Everything else — the supervisor setup, the database pool, the server logic, persistence — is unchanged.

## Try It in IEx

```elixir
# Start the supervision tree
{:ok, sup} = Todo.System.start_link()

# Get (or create) a server for "bob"
bobs_list = Todo.Cache.server_process("bob's list")

# Add an entry
Todo.Server.add_entry(bobs_list, %{date: ~D[2023-12-19], title: "Dentist"})

# Read entries back
Todo.Server.entries(bobs_list, ~D[2023-12-19])

# Kill the cache — the supervisor restarts it; all linked children die with it
cache_pid = Process.whereis(Todo.Cache)
Process.exit(cache_pid, :kill)

# The supervisor brings back a clean cache (and a clean database) automatically
Process.whereis(Todo.Cache)
```
