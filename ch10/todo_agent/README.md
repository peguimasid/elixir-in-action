# Todo Metrics — Chapter 10

This project builds on `dynamic_workers` (ch09). The whole supervision tree — `Todo.ProcessRegistry`, `Todo.Database` and its worker pool, and `Todo.Cache` as a `DynamicSupervisor` — is kept exactly as it was; the focus here is **adding a long-running background job that periodically reports system metrics using a `Task`**.

## The Goal: A Recurring Background Job

We want the system to periodically report on its own health — how much memory it's using and how many processes are alive — without blocking or interfering with any of the to-do work. This is a classic *background job*: it runs forever, does a little work on a timer, and needs to sit under supervision like everything else.

A plain `GenServer` would work, but it's overkill: there are no calls, no casts, and no client API — nothing ever talks to this process. It just loops. `Task` is the right abstraction for exactly this kind of self-contained, "start it and let it run" process.

## The Fix: `Todo.Metrics` as a Supervised `Task`

`Todo.Metrics` uses `Task` and exposes a `start_link/1` that spawns a process running a `loop/0`:

```elixir
defmodule Todo.Metrics do
  use Task

  def start_link(_arg) do
    Task.start_link(&loop/0)
  end

  def loop() do
    Process.sleep(:timer.seconds(10))
    IO.inspect(collect_metadata())
    loop()
  end

  def collect_metadata() do
    [
      memory_usage: :erlang.memory(:total),
      process_count: :erlang.system_info(:process_count)
    ]
  end
end
```

A few things worth noting:

- **`use Task`** injects a default `child_spec/1`, so `Todo.Metrics` can be dropped straight into a supervisor's child list by module name.
- **`Task.start_link/1`** links the task to its supervisor, so a crash propagates and the supervisor's restart policy kicks in.
- **The infinite `loop/0`** is what makes this a long-running job rather than a one-shot task: it sleeps 10 seconds, inspects the collected metadata, then recurses. Because it never returns, the process stays alive under supervision.
- **`collect_metadata/0`** reads two BEAM runtime stats — total memory (`:erlang.memory(:total)`) and the live process count (`:erlang.system_info(:process_count)`).

## Wiring It Into `Todo.System`

`Todo.Metrics` is added as the first child of the top-level supervisor:

```elixir
defmodule Todo.System do
  def start_link do
    Supervisor.start_link(
      [
        Todo.Metrics,
        Todo.ProcessRegistry,
        Todo.Database,
        Todo.Cache
      ],
      strategy: :one_for_one
    )
  end
end
```

Under `:one_for_one`, `Todo.Metrics` is fully independent: if the metrics task crashes it is restarted on its own, and if it were to be removed nothing else in the tree would notice. Because it neither depends on nor is depended upon by the other children, its position in the list doesn't matter for startup ordering.

## Process Tree

```
Supervisor (:one_for_one)
├── Todo.Metrics  (Task — loops forever, prints metrics every 10s)
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

## What Changed vs `dynamic_workers`

| File | Before (`dynamic_workers`) | After (`todo_metrics`) |
|---|---|---|
| `Todo.Metrics` | did not exist | new `Task` that loops forever, printing memory usage and process count every 10 seconds |
| `Todo.System` | supervises `Todo.ProcessRegistry`, `Todo.Database`, `Todo.Cache` | additionally supervises `Todo.Metrics` as its first child |
| `Todo.Cache`, `Todo.Server`, `Todo.Database`, `Todo.DatabaseWorker`, `Todo.ProcessRegistry` | unchanged | unchanged |

## `Task` vs `GenServer` for Background Work

| | `Task` (`Todo.Metrics`) | `GenServer` |
|---|---|---|
| Client API (calls/casts) | none — nothing sends it messages | expected — request/response is the point |
| State | none — everything lives in the loop's arguments | explicit process state |
| Best fit | fire-and-forget or self-driven loops | request handling, stateful coordination |

Since nobody ever queries the metrics process and it holds no meaningful state, `Task` keeps it minimal while still being a first-class, supervised OTP process.

## Try It in IEx

```elixir
# Start the supervision tree — Todo.Metrics starts looping immediately
{:ok, _sup} = Todo.System.start_link()

# Wait ~10 seconds and you'll see output like:
#=> [memory_usage: 34012345, process_count: 84]

# The rest of the to-do system works exactly as in dynamic_workers
bobs_list = Todo.Cache.server_process("bob's list")
Todo.Server.add_entry(bobs_list, %{date: ~D[2024-01-10], title: "Buy milk"})
Todo.Server.entries(bobs_list, ~D[2024-01-10])

# Adding more servers bumps the process_count reported by Todo.Metrics
Enum.each(1..50, &Todo.Cache.server_process("list-#{&1}"))
# next metrics tick will show a higher process_count
```
