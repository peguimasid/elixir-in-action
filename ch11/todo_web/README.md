# Todo Poolboy — Chapter 11

This project builds on `todo_app`. The OTP application, metrics, registry, and cache stay the same; the change is **replacing the hand-rolled database worker pool with [Poolboy](https://github.com/devinus/poolboy)**.

## The Goal: Stop Managing the Pool Yourself

In `todo_app`, `Todo.Database` was its own supervisor: it started three `Todo.DatabaseWorker` children, registered each via `Todo.ProcessRegistry`, and routed keys with `:erlang.phash2/2`. That works, but pool lifecycle (size, checkout, overflow, restarts) is boilerplate you shouldn't own.

Poolboy is a small Erlang library that owns that lifecycle. You declare a pool; it starts the workers and hands you a free one for each checkout.

## The Fix: `:poolboy.child_spec/3` + `:poolboy.transaction/2`

`mix.exs` adds the dependency:

```elixir
defp deps do
  [
    {:poolboy, "~> 1.5"}
  ]
end
```

`Todo.Database` is no longer a supervisor. Its `child_spec/1` returns Poolboy's spec, and `store`/`get` check out a worker for the duration of the call:

```elixir
def child_spec(_) do
  File.mkdir_p!(@db_folder)

  :poolboy.child_spec(
    __MODULE__,
    [
      name: {:local, __MODULE__},
      worker_module: Todo.DatabaseWorker,
      size: 3
    ],
    folder: @db_folder
  )
end

def store(key, data) do
  :poolboy.transaction(__MODULE__, fn worker_pid ->
    Todo.DatabaseWorker.store(worker_pid, key, data)
  end)
end
```

`Todo.DatabaseWorker` is simpler too: no registry / worker id. Poolboy calls `start_link/1` with the worker args (a keyword list), and clients talk to the pid Poolboy checks out:

```elixir
def start_link(worker_args) do
  GenServer.start_link(__MODULE__, Keyword.fetch!(worker_args, :folder))
end

def store(pid, key, data) do
  GenServer.cast(pid, {:store, key, data})
end
```

A few things worth noting:

- **`name: {:local, Todo.Database}`** registers the pool so `transaction/2` can find it by module name.
- **`worker_module` + `size`** tell Poolboy what to start and how many to keep warm.
- **Worker args must be a proplist** (e.g. `folder: @db_folder`). Poolboy's typespec expects that; a bare list like `[@db_folder]` runs but fails Dialyzer/ElixirLS.
- **Routing changed.** Before: sticky hash → same key always hit the same worker. Now: checkout any free worker. Fine for this file-backed demo; sticky routing would need different design if you still wanted it.
- **Workers leave the registry.** `Todo.ProcessRegistry` is still used by servers/cache, not by database workers.

## Process Tree

```
Todo.Application  (OTP application callback)
└── Todo.System  (Supervisor :one_for_one)
      ├── Todo.Metrics  (Task — loops forever, prints metrics every 10s)
      ├── Todo.ProcessRegistry  (Registry — name→pid for servers, not DB workers)
      ├── Todo.Database  (Poolboy pool, size: 3)
      │     ├── DatabaseWorker  (pid only — checked out via :poolboy.transaction)
      │     ├── DatabaseWorker
      │     └── DatabaseWorker
      └── Todo.Cache  (DynamicSupervisor :one_for_one)
            ├── Todo.Server "alice"   (registered as {Todo.Server, "alice"}, restart: :temporary)
            ├── Todo.Server "bob"     (registered as {Todo.Server, "bob"}, restart: :temporary)
            └── ... (children added on demand)
```

## What Changed vs `todo_app`

| File | Before (`todo_app`) | After (`todo_poolboy`) |
|---|---|---|
| `mix.exs` | no Poolboy | `{:poolboy, "~> 1.5"}` |
| `Todo.Database` | custom supervisor + `phash2` routing | `:poolboy.child_spec/3` + `:poolboy.transaction/2` |
| `Todo.DatabaseWorker` | registered via `{DatabaseWorker, id}`, addressed by id | anonymous pid, addressed after checkout |
| `Todo.System` / app / cache / metrics | unchanged | unchanged |

## Try It in IEx

```elixir
# $ iex -S mix

bobs_list = Todo.Cache.server_process("bob's list")
Todo.Server.add_entry(bobs_list, %{date: ~D[2024-01-10], title: "Buy milk"})
Todo.Server.entries(bobs_list, ~D[2024-01-10])

# Persistence still goes through the pool — three workers, checked out per call
```
