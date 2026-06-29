# Pool Supervision — Chapter 9

This project builds on `supervise_database` (ch09). The supervision structure from the previous step is kept intact; the focus here is **worker pool management via supervision** and **process registration without a coordinator GenServer**.

## The Problem: The Database Coordinator Bottleneck

In `supervise_database`, `Todo.Database` is a `GenServer` whose sole job is to route requests to a pool of `DatabaseWorker` processes. Every `store` and `get` call passes through this single process:

```
store("bob", data)
  → GenServer.call(Todo.Database, {:choose_worker, key})  # serialized here
    → DatabaseWorker.store(worker_pid, key, data)
```

The coordinator becomes a bottleneck: all worker selection is serialized through one mailbox, and the coordinator itself is a single point of failure that takes the entire pool down with it when it crashes.

## The Fix: Database as a Supervisor

`pool_supervision` turns `Todo.Database` from a `GenServer` into a **supervisor** that owns its workers directly. Worker selection is moved out of the coordinator's mailbox and computed inline — no message round-trip needed.

```elixir
# Todo.Database — now a supervisor, not a GenServer
def start_link do
  children = Enum.map(1..@pool_size, &worker_spec/1)
  Supervisor.start_link(children, strategy: :one_for_one)
end

defp choose_worker(key) do
  :erlang.phash2(key, @pool_size) + 1   # pure computation, no GenServer call
end
```

`Todo.Database` declares itself as a supervisor via a custom `child_spec/1`:

```elixir
def child_spec(_) do
  %{
    id: __MODULE__,
    start: {__MODULE__, :start_link, []},
    type: :supervisor
  }
end
```

This tells the parent supervisor (`Todo.System`) to treat it as a nested supervisor, so the `:one_for_all` / `:rest_for_one` restart rules apply correctly.

## The Problem: Workers Were Identified by PID

With the old coordinator GenServer, callers received a `worker_pid` and used it to send messages. PIDs are ephemeral — after a restart the old PID is dead, and any caller that cached it would silently fail.

## The Fix: Named Workers via a Process Registry

Each `DatabaseWorker` is now registered under a stable name in a `Registry` (backed by `Todo.ProcessRegistry`). Instead of storing and passing PIDs, callers use a `via_tuple` that the registry resolves at call time:

```elixir
# Todo.DatabaseWorker
def start_link({db_folder, worker_id}) do
  GenServer.start_link(__MODULE__, db_folder, name: via_tuple(worker_id))
end

def store(worker_id, key, data) do
  GenServer.cast(via_tuple(worker_id), {:store, key, data})
end

defp via_tuple(worker_id) do
  Todo.ProcessRegistry.via_tuple({__MODULE__, worker_id})
end
```

```elixir
# Todo.ProcessRegistry
defmodule Todo.ProcessRegistry do
  def start_link do
    Registry.start_link(keys: :unique, name: __MODULE__)
  end

  def via_tuple(key) do
    {:via, Registry, {__MODULE__, key}}
  end
end
```

A `via_tuple` is a `{:via, module, term}` tuple that OTP understands natively. When passed as `name:` to `GenServer.start_link`, the registry records the mapping. When passed to `GenServer.call/cast`, OTP asks the registry to resolve the current PID — so callers always find the live process even after a restart.

## `Todo.ProcessRegistry` as a Sibling Supervisor Child

Because workers register themselves on start, the registry must be running before any worker starts. It is added as the **first child** in `Todo.System`:

```elixir
defmodule Todo.System do
  def start_link do
    Supervisor.start_link(
      [
        Todo.ProcessRegistry,   # ← must start before workers register
        Todo.Database,
        Todo.Cache
      ],
      strategy: :one_for_one
    )
  end
end
```

## Process Tree

```
Supervisor (:one_for_one)
├── Todo.ProcessRegistry  (Registry — holds name→pid mappings)
├── Todo.Database  (Supervisor :one_for_one)
│     ├── DatabaseWorker #1  (registered as {DatabaseWorker, 1})
│     ├── DatabaseWorker #2  (registered as {DatabaseWorker, 2})
│     └── DatabaseWorker #3  (registered as {DatabaseWorker, 3})
└── Todo.Cache
      ├── Todo.Server "alice"
      ├── Todo.Server "bob"
      └── ...
```

## Crash Isolation

| What crashes | What gets restarted | What survives |
|---|---|---|
| `DatabaseWorker #2` | `DatabaseWorker #2` only (re-registers itself) | All other workers, `Todo.Cache`, `Todo.ProcessRegistry` |
| `Todo.Database` supervisor | `Todo.Database` + all 3 workers (re-register) | `Todo.Cache` + all `Todo.Server`s |
| `Todo.Cache` | `Todo.Cache` + all `Todo.Server`s | `Todo.Database` + its workers |

Worker crashes are now fully isolated — a single bad disk write only takes down that one worker, not the whole pool.

## What Changed vs `supervise_database`

| File | Before (`supervise_database`) | After (`pool_supervision`) |
|---|---|---|
| `Todo.Database` | `GenServer` — stores worker PIDs in state, serializes `choose_worker` calls | `Supervisor` — owns workers directly, `choose_worker` is a pure hash |
| `Todo.DatabaseWorker` | started anonymously, identified by PID | started with a registry name, identified by stable `worker_id` |
| `Todo.ProcessRegistry` | did not exist | new module — wraps `Registry` with a `via_tuple` helper |
| `Todo.System` | `[Todo.Database, Todo.Cache]` | `[Todo.ProcessRegistry, Todo.Database, Todo.Cache]` |

## Try It in IEx

```elixir
# Start the supervision tree
{:ok, _sup} = Todo.System.start_link()

# Add an entry for bob
bobs_list = Todo.Cache.server_process("bob's list")
Todo.Server.add_entry(bobs_list, %{date: ~D[2024-01-10], title: "Buy milk"})

# Verify it was persisted
Todo.Server.entries(bobs_list, ~D[2024-01-10])

# Kill one database worker — only that worker restarts, pool stays healthy
worker_pid = Registry.lookup(Todo.ProcessRegistry, {Todo.DatabaseWorker, 1}) |> hd() |> elem(0)
Process.exit(worker_pid, :kill)

# The worker re-registers; the pool is immediately usable again
Todo.Server.entries(bobs_list, ~D[2024-01-10])
```
