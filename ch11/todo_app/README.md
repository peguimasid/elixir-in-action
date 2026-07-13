# Todo App — Chapter 11

This project builds on `todo_metrics` (ch10). The supervision tree — `Todo.Metrics`, `Todo.ProcessRegistry`, `Todo.Database` and its worker pool, and `Todo.Cache` as a `DynamicSupervisor` — is kept exactly as it was; the focus here is **turning the system into a proper OTP application that starts itself**.

## The Goal: Stop Starting the Tree by Hand

Until now, every IEx session or test had to call `Todo.System.start_link()` (or start pieces of the tree manually) before anything worked. That's fine while exploring, but a real Elixir project is an *application*: something the BEAM starts for you when the node boots, and stops when the node shuts down.

OTP already has this concept. An application is a reusable unit with a callback module that implements `Application.start/2`. Mix wires that callback into the generated `.app` file via `mod:`, and the runtime starts the whole supervision tree automatically.

## The Fix: `Todo.Application` + `mod` in `mix.exs`

`Todo.Application` is a thin callback module — its only job is to kick off the existing top-level supervisor:

```elixir
defmodule Todo.Application do
  use Application

  @impl Application
  def start(_, _) do
    Todo.System.start_link()
  end
end
```

And `mix.exs` tells OTP which module owns the app:

```elixir
def application do
  [
    extra_applications: [:logger],
    mod: {Todo.Application, []}
  ]
end
```

A few things worth noting:

- **`use Application`** brings in the `Application` behaviour and a default `child_spec`-friendly shape for the callback module.
- **`start/2`** must return `{:ok, pid}` (or `{:ok, pid, state}`) of the top-level process — here that's whatever `Todo.System.start_link/0` returns, which is the root supervisor.
- **`mod: {Todo.Application, []}`** is what makes the difference vs ch10: without it, Mix still builds a `:todo` app, but nothing starts the supervision tree. With it, `mix run`, `iex -S mix`, releases, and `mix test` all boot `Todo.System` for free.
- **Nothing else in the tree changed.** `Todo.System` still supervises the same children with `:one_for_one`; the application layer just becomes the entry point above it.

## Process Tree

```
Todo.Application  (OTP application callback)
└── Todo.System  (Supervisor :one_for_one)
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

## What Changed vs `todo_metrics`

| File | Before (`todo_metrics`) | After (`todo_app`) |
|---|---|---|
| `Todo.Application` | did not exist | new `Application` callback that starts `Todo.System` |
| `mix.exs` | `extra_applications: [:logger]` only | also sets `mod: {Todo.Application, []}` |
| `Todo.System`, `Todo.Metrics`, `Todo.Cache`, … | unchanged | unchanged |
| tests | had to start pieces of the tree manually | rely on the app already being started |

## Try It in IEx

```elixir
# Boot the project — the application starts Todo.System automatically
# $ iex -S mix

# No Todo.System.start_link() needed anymore
bobs_list = Todo.Cache.server_process("bob's list")
Todo.Server.add_entry(bobs_list, %{date: ~D[2024-01-10], title: "Buy milk"})
Todo.Server.entries(bobs_list, ~D[2024-01-10])

# Todo.Metrics is already looping in the background
#=> [memory_usage: 34012345, process_count: 84]
```
