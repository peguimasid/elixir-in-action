# Todo Agent — Chapter 10

This project builds on `todo_metrics` (ch10). The supervision tree, `Todo.Cache`, `Todo.Database` and its worker pool, `Todo.ProcessRegistry`, and the periodic `Todo.Metrics` task are all kept exactly as they were; the focus here is **rewriting `Todo.Server` from a `GenServer` to an `Agent`**.

## The Goal: Simplify a State-Wrapper Process

`Todo.Server` has always done one thing: hold a single piece of state (a `{name, todo_list}` tuple) and expose functions to read and update it. It has no complex call/cast protocol, no multiple message types to pattern-match on, and no need for `handle_continue`, timeouts, or custom `init` logic beyond loading the list. That's exactly the shape `Agent` was built for — a thin, purpose-built abstraction over "a process that wraps state" that's built on top of `GenServer` internally.

## The Fix: `Todo.Server` as an `Agent`

```elixir
defmodule Todo.Server do
  use Agent, restart: :temporary

  def start_link(name) do
    Agent.start_link(
      fn ->
        IO.puts("Starting to-do server for #{name}.")
        todo_list = Todo.Database.get(name) || Todo.List.new()
        {name, todo_list}
      end,
      name: via_tuple(name)
    )
  end

  def add_entry(todo_server, new_entry) do
    Agent.cast(todo_server, fn {name, todo_list} ->
      new_list = Todo.List.add_entry(todo_list, new_entry)
      Todo.Database.store(name, new_list)
      {name, new_list}
    end)
  end

  def entries(todo_server, date) do
    Agent.get(todo_server, fn {_name, todo_list} ->
      Todo.List.entries(todo_list, date)
    end)
  end

  defp via_tuple(name) do
    Todo.ProcessRegistry.via_tuple({__MODULE__, name})
  end
end
```

A few things worth noting:

- **`use Agent, restart: :temporary`** replaces `use GenServer, restart: :temporary`. The `:temporary` restart strategy is unchanged — if a to-do server crashes, `Todo.Cache`'s `DynamicSupervisor` won't try to restart it, since the caller is expected to look it up again via `Todo.Cache.server_process/1`.
- **`Agent.start_link/2`** takes an initializer function instead of an `init/1` callback. The function runs in the new process and its return value becomes the agent's state — here that's the same `{name, todo_list}` tuple the `GenServer` version stored. This also collapses the old `init/1` + `handle_continue/2` two-step (used to avoid blocking the caller on the database read) into a single function, since `Agent.start_link/2` already runs the initializer inside the spawned process rather than the caller.
- **`Agent.cast/2`** replaces `handle_cast/2`. Instead of matching on a `{:add_entry, new_entry}` message inside a callback, the update logic is passed directly as an anonymous function that takes the current state and returns the new state.
- **`Agent.get/2`** replaces `handle_call/3` + a manual `{:reply, ...}` tuple. The function receives the current state and its return value is sent straight back to the caller.
- **No more `@impl GenServer` callbacks** — `init/1`, `handle_continue/2`, `handle_cast/2`, and `handle_call/3` all disappear. The client API functions (`start_link/1`, `add_entry/2`, `entries/2`) are the entire module now.
- **The public API is unchanged.** `Todo.Server.start_link/1`, `add_entry/2`, and `entries/2` have the exact same names and arities as before, so `Todo.Cache` and every caller work without modification.

## Wiring: Nothing Changes

`Todo.Cache` still starts `Todo.Server` processes the same way, and `Todo.System`'s supervision tree is untouched:

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

Because `Agent` is itself implemented on top of `GenServer`, an `Agent`-based `Todo.Server` still looks like an ordinary OTP process to its supervisor: same `child_spec`, same linking behavior, same crash semantics.

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
      ├── Todo.Server "alice"   (Agent, registered as {Todo.Server, "alice"}, restart: :temporary)
      ├── Todo.Server "bob"     (Agent, registered as {Todo.Server, "bob"}, restart: :temporary)
      └── ... (children added on demand, never known up front)
```

## What Changed vs `todo_metrics`

| File | Before (`todo_metrics`) | After (`todo_agent`) |
|---|---|---|
| `Todo.Server` | `GenServer` with `init/1`, `handle_continue/2`, `handle_cast/2`, `handle_call/3` | `Agent` with an initializer function passed to `start_link/2`, plus `Agent.cast/2` and `Agent.get/2` |
| `Todo.Server` public API | `start_link/1`, `add_entry/2`, `entries/2` | unchanged — same names, arities, and behavior |
| `Todo.Metrics`, `Todo.System`, `Todo.Cache`, `Todo.Database`, `Todo.DatabaseWorker`, `Todo.ProcessRegistry`, `Todo.List` | — | unchanged |

## `Agent` vs `GenServer`

| | `Agent` (`Todo.Server`) | `GenServer` |
|---|---|---|
| Purpose | wrap and expose a piece of state | general-purpose process behavior: state, calls, casts, timeouts, custom callbacks |
| API shape | `start_link/2`, `get/2`, `get_and_update/2`, `update/2`, `cast/2` — state is passed straight into anonymous functions | `handle_call/3`, `handle_cast/2`, `handle_info/2`, etc. — messages are matched inside callbacks |
| Boilerplate | minimal — no callback module required | more explicit, but supports arbitrary message protocols |
| Best fit | simple state holders like `Todo.Server` | processes needing custom message handling, `handle_info`, or complex lifecycle hooks |

`Agent` is literally a `GenServer` under the hood with a fixed, minimal callback implementation. Since `Todo.Server` never needed anything beyond "read this state" / "update this state," switching to `Agent` removes boilerplate without losing any behavior — the trade-off only becomes relevant if the server later needs custom message handling (e.g. `handle_info` for monitors, or a third message type), at which point `GenServer` would be worth reintroducing.

## Try It in IEx

```elixir
{:ok, _sup} = Todo.System.start_link()

bobs_list = Todo.Cache.server_process("bob's list")
Todo.Server.add_entry(bobs_list, %{date: ~D[2024-01-10], title: "Buy milk"})
Todo.Server.entries(bobs_list, ~D[2024-01-10])
#=> [%{date: ~D[2024-01-10], title: "Buy milk", id: 1}]

# Same process is returned on lookup, exactly as with the GenServer version
^bobs_list = Todo.Cache.server_process("bob's list")
```
