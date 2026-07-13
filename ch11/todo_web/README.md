# Todo Web — Chapter 11

This project builds on `todo_poolboy`. The Poolboy database pool, cache, registry, and metrics stay the same; the change is **exposing the todo system over HTTP with [Plug](https://github.com/elixir-plug/plug) and [Cowboy](https://github.com/ninenines/cowboy)**.

## The Goal: Talk to the System Over the Network

Until now, clients were IEx sessions in the same BEAM. That works for demos, but a real interface needs an HTTP boundary: accept requests, look up (or start) a list server via `Todo.Cache`, and return a response.

`Todo.Web` is a `Plug.Router` that Cowboy serves. It sits in the supervision tree next to the rest of the OTP app — if the HTTP listener dies, the supervisor restarts it like any other child.

## The Fix: `Plug.Cowboy.child_spec/1` + `Plug.Router`

`mix.exs` adds the dependency (Poolboy remains from the previous step):

```elixir
defp deps do
  [
    {:poolboy, "~> 1.5"},
    {:plug_cowboy, "~> 2.9"}
  ]
end
```

`Todo.Web` declares how Cowboy should start it, then routes requests into the existing cache/server API:

```elixir
def child_spec(_arg) do
  Plug.Cowboy.child_spec(
    scheme: :http,
    options: [port: 5454],
    plug: __MODULE__
  )
end

get "/entries" do
  conn = Plug.Conn.fetch_query_params(conn)
  list_name = Map.fetch!(conn.params, "list")
  date = Date.from_iso8601!(Map.fetch!(conn.params, "date"))

  entries =
    list_name
    |> Todo.Cache.server_process()
    |> Todo.Server.entries(date)

  # ... format and send_resp
end
```

`Todo.System` starts the web server as a sibling of the other children:

```elixir
Supervisor.start_link(
  [
    Todo.Metrics,
    Todo.ProcessRegistry,
    Todo.Database,
    Todo.Cache,
    Todo.Web
  ],
  strategy: :one_for_one
)
```

A few things worth noting:

- **`Plug.Cowboy.child_spec/1`** returns a proper OTP child spec — Cowboy (via Ranch) owns acceptors and connection processes under that child.
- **Routes call the same API as IEx.** `Todo.Cache.server_process/1` and `Todo.Server` are unchanged; HTTP is just another client.
- **Query params carry the payload** for both `GET /entries` and `POST /add_entry` (title included on the query string for the demo).
- **Port `5454`** is hard-coded in the child spec for simplicity.

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
      ├── Todo.Cache  (DynamicSupervisor :one_for_one)
      │     ├── Todo.Server "alice"   (registered as {Todo.Server, "alice"}, restart: :temporary)
      │     ├── Todo.Server "bob"     (registered as {Todo.Server, "bob"}, restart: :temporary)
      │     └── ... (children added on demand)
      └── Todo.Web  (Plug.Cowboy HTTP listener on :5454)
```

## What Changed vs `todo_poolboy`

| File | Before (`todo_poolboy`) | After (`todo_web`) |
|---|---|---|
| `mix.exs` | Poolboy only | + `{:plug_cowboy, "~> 2.9"}` |
| `Todo.Web` | — | new `Plug.Router` + Cowboy child spec |
| `Todo.System` | metrics, registry, DB, cache | + `Todo.Web` |
| Database / cache / servers | unchanged | unchanged |

## Try It

```bash
# Terminal 1
iex -S mix

# Terminal 2
curl -d '' 'http://localhost:5454/add_entry?list=bob&date=2018-12-19&title=Dentist'
curl 'http://localhost:5454/entries?list=bob&date=2018-12-19'
```

### Load test with wrk

`wrk.lua` hammers random lists with a mix of GET/POST. Delete `persist/` first, start in prod, then run wrk from another shell:

```bash
# Terminal 1 — delete persist/, then:
MIX_ENV=prod iex -S mix

# Terminal 2
wrk -t4 -c28 -d30s --latency -s wrk.lua http://localhost:5454
```
