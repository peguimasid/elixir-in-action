# Dynamic Workers — Chapter 9

This project builds on `pool_supervision` (ch09). The database supervisor, the worker registry, and `Todo.System` are kept exactly as they were; the focus here is **managing an unbounded, unpredictable set of `Todo.Server` processes with a `DynamicSupervisor`**.

## The Problem: `Todo.Cache` Was a Bottleneck Coordinator

In `pool_supervision`, `Todo.Cache` is a plain `GenServer` that keeps a `%{name => pid}` map in its state and starts a new `Todo.Server` on demand:

```elixir
# Todo.Cache (pool_supervision) — a GenServer holding every PID in its state
def server_process(todo_list_name) do
  GenServer.call(__MODULE__, {:server_process, todo_list_name})
end

def handle_call({:server_process, todo_list_name}, _, todo_servers) do
  case Map.fetch(todo_servers, todo_list_name) do
    {:ok, todo_server} ->
      {:reply, todo_server, todo_servers}

    :error ->
      {:ok, new_server} = Todo.Server.start_link(todo_list_name)
      todo_servers = Map.put(todo_servers, todo_list_name, new_server)
      {:reply, new_server, todo_servers}
  end
end
```

This has the same problem the database coordinator had before `pool_supervision`: every single `server_process/1` lookup — for every to-do list, by every caller — is serialized through one process's mailbox. It's also a structural supervisor of sorts (it decides whether to start a server), but it isn't a *real* supervisor, so a crashed `Todo.Server` is never restarted and a crash in `Todo.Cache` itself takes down every list at once along with the whole PID map.

## The Fix: `Todo.Cache` Becomes a `DynamicSupervisor`

`dynamic_workers` turns `Todo.Cache` into a `DynamicSupervisor` — a supervisor designed for children that are started one at a time, on demand, with no fixed list known up front (exactly the to-do-list-per-name shape we have here).

```elixir
defmodule Todo.Cache do
  def start_link() do
    IO.puts("Starting to-do cache.")
    DynamicSupervisor.start_link(name: __MODULE__, strategy: :one_for_one)
  end

  def child_spec(_arg) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, []},
      type: :supervisor
    }
  end

  def server_process(todo_list_name) do
    case start_child(todo_list_name) do
      {:ok, pid} -> pid
      {:error, {:already_started, pid}} -> pid
    end
  end

  defp start_child(todo_list_name) do
    DynamicSupervisor.start_child(__MODULE__, {Todo.Server, todo_list_name})
  end
end
```

Two things disappear completely:

- **The state map.** `DynamicSupervisor` already tracks its children; `Todo.Cache` no longer needs to hold `%{name => pid}` itself.
- **The serialized `GenServer.call`.** `start_child` still goes through the supervisor's mailbox, but `Map.fetch`/`Map.put` bookkeeping is gone — the supervisor's own child-tracking does that job.

Just like `Todo.Database` in `pool_supervision`, `Todo.Cache` needs a custom `child_spec/1` so its parent (`Todo.System`) starts it correctly and treats it as a supervisor (not a worker) for restart purposes.

## The Problem: "Already Started" Is Now Possible

A `DynamicSupervisor` has no idea that two different callers might ask for the *same* `todo_list_name` at the same time — it will happily try to start two children for "bob's list". For that to fail gracefully instead of creating duplicate servers, `Todo.Server` needs a stable, registry-backed identity, the same mechanism `pool_supervision` already introduced for `DatabaseWorker`.

## The Fix: `Todo.Server` Registers Itself by Name

`Todo.Server` now registers under a `via_tuple` in `Todo.ProcessRegistry`, exactly like `DatabaseWorker` does:

```elixir
defmodule Todo.Server do
  use GenServer, restart: :temporary

  def start_link(name) do
    GenServer.start_link(Todo.Server, name, name: via_tuple(name))
  end

  defp via_tuple(name) do
    Todo.ProcessRegistry.via_tuple({__MODULE__, name})
  end

  # ...
end
```

This makes `start_child/1` idempotent: if a `Todo.Server` for "bob's list" is already registered, the registry rejects the second `start_link` with `{:error, {:already_started, pid}}`, which `DynamicSupervisor.start_child/2` propagates back to `Todo.Cache.server_process/1`. `server_process/1` handles both outcomes identically, so callers always get back the one live PID for that name regardless of how many processes raced to request it.

## `restart: :temporary` — Why To-Do Servers Should *Not* Restart

`Todo.Server` also adds `use GenServer, restart: :temporary`. Compare the two workers under `Todo.Cache`'s supervision:

- `Todo.DatabaseWorker` (under `Todo.Database`, a plain `Supervisor`) keeps the default `:permanent` restart — if a database worker crashes, the data it manages is still expected to exist, so it must come back.
- `Todo.Server` represents one user's in-memory to-do list. If it crashes, restarting it from scratch with no arguments wouldn't even work — `DynamicSupervisor` only knows the `{Todo.Server, name}` child spec used at the *first* `start_child` call, and on crash it has nothing to restart with. More importantly, the list isn't actually lost: it was already persisted to `Todo.Database` on every `add_entry`, so the next call to `Todo.Cache.server_process/1` simply starts a fresh `Todo.Server` that reloads the list from disk via `handle_continue(:init, ...)`.

`:temporary` tells the supervisor "never restart this child automatically" — fitting for a process whose lifecycle is driven entirely by caller demand, not by supervision policy.

## Process Tree

```
Supervisor (:one_for_one)
├── Todo.ProcessRegistry  (Registry — holds name→pid mappings)
├── Todo.Database  (Supervisor :one_for_one)
│     ├── DatabaseWorker #1  (registered as {DatabaseWorker, 1})
│     ├── DatabaseWorker #2  (registered as {DatabaseWorker, 2})
│     └── DatabaseWorker #3  (registered as {DatabaseWorker, 3})
└── Todo.Cache  (DynamicSupervisor :one_for_one)
      ├── Todo.Server "alice"   (registered as {Todo.Server, "alice"}, restart: :temporary)
      ├── Todo.Server "bob"     (registered as {Todo.Server, "bob"}, restart: :temporary)
      └── ... (children added on demand, never known up front)
```

## What Changed vs `pool_supervision`

| File | Before (`pool_supervision`) | After (`dynamic_workers`) |
|---|---|---|
| `Todo.Cache` | `GenServer` — keeps a `%{name => pid}` map, serializes lookups through `handle_call` | `DynamicSupervisor` — children started on demand via `start_child/2`, no manual state map |
| `Todo.Server` | started anonymously via `GenServer.start_link/2`, default `:permanent` restart | registered via `via_tuple/1` in `Todo.ProcessRegistry`, `restart: :temporary` |
| `Todo.Database`, `Todo.DatabaseWorker`, `Todo.ProcessRegistry`, `Todo.System` | unchanged | unchanged |

## Crash Isolation

| What crashes | What gets restarted | What survives |
|---|---|---|
| `Todo.Server` for "bob" | **nothing automatically** (`:temporary`) — next `server_process("bob's list")` call starts a fresh one, reloaded from `Todo.Database` | All other to-do servers, `Todo.Cache`, `Todo.Database` and its workers |
| `Todo.Cache` (the `DynamicSupervisor` itself) | `Todo.Cache` restarts empty; in-flight `Todo.Server`s are gone, but their data is safe in `Todo.Database` | `Todo.Database` + its workers, `Todo.ProcessRegistry` |
| `DatabaseWorker #2` | `DatabaseWorker #2` only (re-registers itself) | Everything else, including all `Todo.Server`s |

## Try It in IEx

```elixir
# Start the supervision tree
{:ok, _sup} = Todo.System.start_link()

# Add an entry for bob — Todo.Cache dynamically starts a Todo.Server for this name
bobs_list = Todo.Cache.server_process("bob's list")
Todo.Server.add_entry(bobs_list, %{date: ~D[2024-01-10], title: "Buy milk"})

# Verify it was persisted
Todo.Server.entries(bobs_list, ~D[2024-01-10])

# Calling server_process/1 again for the same name returns the same PID,
# even though two DynamicSupervisor.start_child calls happen under the hood
^bobs_list = Todo.Cache.server_process("bob's list")

# Kill bob's server — it is NOT restarted (restart: :temporary)
Process.exit(bobs_list, :kill)
Process.alive?(bobs_list)
#=> false

# But the data survives: the next lookup starts a brand-new process
# that reloads the list from Todo.Database
new_bobs_list = Todo.Cache.server_process("bob's list")
new_bobs_list != bobs_list
#=> true
Todo.Server.entries(new_bobs_list, ~D[2024-01-10])
#=> still shows "Buy milk"
```
