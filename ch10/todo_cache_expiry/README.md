# Todo Cache Expiry — Chapter 10

This project builds on `todo_metrics` (ch10). The supervision tree, `Todo.Cache`, `Todo.Database` and its worker pool, `Todo.ProcessRegistry`, and the periodic `Todo.Metrics` task are all kept exactly as they were; the focus here is **making idle `Todo.Server` processes expire on their own using `GenServer` timeouts**.

## The Goal: Stop Paying for Idle Servers

Every to-do list gets its own `Todo.Server` process, started on demand and kept alive under `Todo.Cache`'s `DynamicSupervisor` forever — even after nobody has touched it in hours. That's wasted memory: an in-memory `Todo.List` sitting in a process nobody is using. Since the list is always persisted to `Todo.Database` on every write, a `Todo.Server` doesn't actually need to stay alive between requests — it can safely shut down when idle and be recreated later, transparently, from whatever was last saved.

## The Fix: A `GenServer` Timeout That Ends the Process

`Todo.Server` gains a module attribute for the idle threshold and passes it as the timeout value in every `{:noreply, ...}` / `{:reply, ...}` tuple it returns:

```elixir
defmodule Todo.Server do
  use GenServer, restart: :temporary

  # ... start_link/1, add_entry/2, entries/2, via_tuple/1 unchanged ...

  @expiry_idle_timeout :timer.seconds(10)

  @impl GenServer
  def init(name) do
    IO.puts("Starting to-do server for #{name}.")
    {:ok, {name, nil}, {:continue, :init}}
  end

  @impl GenServer
  def handle_continue(:init, {name, nil}) do
    todo_list = Todo.Database.get(name) || Todo.List.new()
    {:noreply, {name, todo_list}, @expiry_idle_timeout}
  end

  @impl GenServer
  def handle_cast({:add_entry, new_entry}, {name, todo_list}) do
    new_list = Todo.List.add_entry(todo_list, new_entry)
    Todo.Database.store(name, new_list)
    {:noreply, {name, new_list}, @expiry_idle_timeout}
  end

  @impl GenServer
  def handle_call({:entries, date}, _, {name, todo_list}) do
    {:reply, Todo.List.entries(todo_list, date), {name, todo_list}, @expiry_idle_timeout}
  end

  @impl GenServer
  def handle_info(:timeout, {name, todo_list}) do
    IO.puts("Stopping to-do server for #{name}")
    {:stop, :normal, {name, todo_list}}
  end
end
```

A few things worth noting:

- **`@expiry_idle_timeout :timer.seconds(10)`** is the fourth element every callback now returns alongside its state. In `GenServer`, this value tells OTP "if no message arrives within this many milliseconds, send me a `:timeout` message" — and the timer resets on *every* handled message, so it only fires after a genuine idle period.
- **Every `handle_continue/2`, `handle_cast/2`, and `handle_call/3` clause passes `@expiry_idle_timeout`.** Missing it on even one clause would mean that particular transition never re-arms the timer, so the timeout has to be threaded through consistently.
- **`handle_info(:timeout, ...)`** is the new callback that actually reacts to the timer firing. It logs and returns `{:stop, :normal, state}`, which terminates the process cleanly — `:normal` is not treated as a crash, so no error is logged and no supervisor alarm is raised.
- **`restart: :temporary` is what makes this safe.** Because `Todo.Cache`'s `DynamicSupervisor` never restarts a `:temporary` child, the expired process simply disappears; it is not immediately respawned. `Todo.Cache.server_process/1` is the only thing that brings a `Todo.Server` back, and only when someone asks for it again.
- **No data is lost.** Every write already goes through `Todo.Database.store/2` before the process replies, so by the time a server times out, its in-memory state has long since been durably persisted. The next `Todo.Cache.server_process/1` call simply starts a fresh process that reloads the same list via `Todo.Database.get/1`.

## Wiring: Nothing Changes

`Todo.Cache` still looks up or starts a `Todo.Server` the same way it always has — it has no idea whether the process it gets back is the original one or a freshly-restarted one:

```elixir
defmodule Todo.Cache do
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

If the old process already expired and exited, `Todo.ProcessRegistry` no longer has an entry for it, so `start_child/1` succeeds with a brand-new pid instead of hitting `{:error, {:already_started, pid}}`. Either way, the caller gets back a live `Todo.Server` it can use.

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
      ├── Todo.Server "alice"   (registered as {Todo.Server, "alice"}, restart: :temporary, exits after 10s idle)
      ├── Todo.Server "bob"     (registered as {Todo.Server, "bob"}, restart: :temporary, exits after 10s idle)
      └── ... (children added on demand; expired ones vanish and are recreated on next access)
```

## What Changed vs `todo_metrics`

| File | Before (`todo_metrics`) | After (`todo_cache_expiry`) |
|---|---|---|
| `Todo.Server` | `GenServer` callbacks return two/three-element tuples with no timeout | every `init`/`handle_continue`/`handle_cast`/`handle_call` clause returns a fourth `@expiry_idle_timeout` element; new `handle_info(:timeout, ...)` stops the process after 10s of inactivity |
| `Todo.Server` public API | `start_link/1`, `add_entry/2`, `entries/2` | unchanged — same names, arities, and behavior |
| `Todo.Metrics`, `Todo.System`, `Todo.Cache`, `Todo.Database`, `Todo.DatabaseWorker`, `Todo.ProcessRegistry`, `Todo.List` | — | unchanged |

## `GenServer` Timeouts as a Cache-Expiry Mechanism

| | Without expiry (`todo_metrics`) | With expiry (`todo_cache_expiry`) |
|---|---|---|
| Idle `Todo.Server` processes | live forever once started | exit after `@expiry_idle_timeout` (10s) of no calls/casts |
| Memory for inactive lists | held indefinitely | reclaimed automatically |
| State durability | relies on writes going to `Todo.Database` | unchanged — same guarantee, now also the safety net for expiry |
| Access after expiry | n/a | transparent — `Todo.Cache.server_process/1` restarts the process and reloads state from `Todo.Database` |

Using the built-in `GenServer` timeout keeps this entirely inside the process's own callbacks — no external janitor process, no `Process.send_after/3` bookkeeping, and no change to any caller. The trade-off is the same timeout value governs both call/cast replies and idle detection, so picking a very small timeout can be indistinguishable from processes never staying alive at all — 10 seconds here is a deliberately short value for demonstration.

## Try It in IEx

```elixir
{:ok, _sup} = Todo.System.start_link()

bobs_list = Todo.Cache.server_process("bob's list")
Todo.Server.add_entry(bobs_list, %{date: ~D[2024-01-10], title: "Buy milk"})
Todo.Server.entries(bobs_list, ~D[2024-01-10])
#=> [%{date: ~D[2024-01-10], title: "Buy milk", id: 1}]

# Wait more than 10 seconds without touching bobs_list...
Process.sleep(:timer.seconds(11))
#=> prints "Stopping to-do server for bob's list"

# The old pid is dead, but the data survived in Todo.Database
Process.alive?(bobs_list)
#=> false

new_bobs_list = Todo.Cache.server_process("bob's list")
new_bobs_list != bobs_list
#=> true
Todo.Server.entries(new_bobs_list, ~D[2024-01-10])
#=> [%{date: ~D[2024-01-10], title: "Buy milk", id: 1}]
```
