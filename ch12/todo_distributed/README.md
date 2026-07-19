# Todo Distributed — Chapter 12

This project builds on `todo_env`. Runtime config, HTTP, Poolboy, and the cache stay in place; the change is **running the same OTP app on multiple BEAM nodes** so todo servers are discoverable cluster-wide and writes are replicated to every node's local database.

## The Goal: One Logical System Across Nodes

In `todo_env`, a todo list name maps to a process via a **local** `Registry`. That only works inside one BEAM. Start a second node and you get a second, independent system: separate caches, separate files under `./persist`, no shared identity.

Chapter 12 connects named nodes into a cluster and makes two things cluster-aware:

1. **Process discovery** — at most one `Todo.Server` per list name across the cluster (`:global`)
2. **Data replication** — a store on one node is written on every connected node (`:rpc.multicall`)

Each node still keeps its own on-disk folder (so two nodes started from the same project root do not clobber each other). Replication keeps those folders in sync on write.

## The Fix: `:global` Names + `:rpc.multicall`

### Cluster-wide server names

`Todo.ProcessRegistry` is gone. Servers register with Erlang's global name service instead:

```elixir
# Todo.Server
def start_link(name) do
  GenServer.start_link(Todo.Server, name, name: global_name(name))
end

def whereis(name) do
  case :global.whereis_name({__MODULE__, name}) do
    :undefined -> nil
    pid -> pid
  end
end

defp global_name(name), do: {:global, {__MODULE__, name}}
```

`Todo.Cache` looks up the global name first, then starts a child only if none exists. That way a request on node2 can reuse a server already running on node1:

```elixir
def server_process(todo_list_name) do
  existing_process(todo_list_name) || new_process(todo_list_name)
end
```

If two nodes race to start the same list, `DynamicSupervisor.start_child/2` may return `{:error, {:already_started, pid}}` — the cache returns that pid either way.

### Replicated stores, local reads

`Todo.Database.store/2` no longer writes only locally. It fans out to every connected node:

```elixir
def store(key, data) do
  {_results, bad_nodes} =
    :rpc.multicall(__MODULE__, :store_local, [key, data], :timer.seconds(5))

  Enum.each(bad_nodes, &IO.puts("Store failed on node #{&1}"))
  :ok
end
```

`store_local/2` is the Poolboy checkout that used to be `store/2`. Reads stay local (`get/1`) — once replication has run, any node can load the list from its own disk.

The database folder is scoped by the short node name so multiple nodes share one project tree safely:

```elixir
[name_prefix, _] = "#{node()}" |> String.split("@")
db_folder = "#{Keyword.fetch!(db_settings, :db_folder)}/#{name_prefix}/"
# e.g. ./persist/node1/, ./persist/node2/
```

### Synchronous workers

`Todo.DatabaseWorker.store/2` is a `GenServer.call` (was a cast). Multicall needs the remote write to finish before the RPC returns; fire-and-forget casts would race with later reads on other nodes.

### Supervision tree

`Todo.ProcessRegistry` is removed from `Todo.System`. Metrics is commented out for this chapter's demos (noise while juggling multiple shells):

```elixir
Supervisor.start_link(
  [
    # Todo.Metrics,
    Todo.Database,
    Todo.Cache,
    Todo.Web
  ],
  strategy: :one_for_one
)
```

A few things worth noting:

- **`:global` is cluster-wide.** After `Node.connect/1`, `whereis` and name registration see processes on other nodes.
- **Replication is eager on write.** A successful `add_entry` on one node should leave the same term on every node's disk (failed nodes are logged via `bad_nodes`).
- **HTTP is unchanged.** Each node can listen on its own port (`TODO_HTTP_PORT`); the interesting part is which node owns the list server and that stores hit the whole cluster.
- **Callers stay the same.** Routes and IEx still go through `Todo.Cache.server_process/1`.

## Process Tree

Per node (shape is almost `todo_env`, minus registry/metrics):

```
Todo.Application  (OTP application callback)
└── Todo.System  (Supervisor :one_for_one)
      ├── Todo.Database  (Poolboy pool, size: 3 — folder ./persist/<node>/)
      │     ├── DatabaseWorker
      │     ├── DatabaseWorker
      │     └── DatabaseWorker
      ├── Todo.Cache  (DynamicSupervisor :one_for_one)
      │     └── Todo.Server "bob"   (named {:global, {Todo.Server, "bob"}})
      │           └── may live on this node or another; cache uses whereis first
      └── Todo.Web  (Plug.Cowboy — port from config)
```

Across two connected nodes:

```
node1@...                         node2@...
├── Database → ./persist/node1/   ├── Database → ./persist/node2/
├── Cache (may start servers)     ├── Cache (may start servers)
└── Web :5454                     └── Web :5455

store → :rpc.multicall → store_local on node1 and node2
```

## What Changed vs `todo_env`

| File | Before (`todo_env`) | After (`todo_distributed`) |
|---|---|---|
| `Todo.ProcessRegistry` | local `Registry` for server names | **removed** |
| `Todo.Server` | `via` Registry tuple | `{:global, {Todo.Server, name}}` + `whereis/1` |
| `Todo.Cache` | always `start_child` | `whereis` then start; handle `:already_started` |
| `Todo.Database` | single `./persist` folder, local `store` | per-node subfolder; `store` → multicall `store_local` |
| `Todo.DatabaseWorker` | `store` via cast | `store` via call (sync for RPC) |
| `Todo.System` | Metrics + ProcessRegistry + … | Metrics commented out; no ProcessRegistry |

## Try It

Start two named nodes from `ch12/todo_distributed`, give them different HTTP ports, then connect them.

```bash
# Terminal 1
TODO_HTTP_PORT=5454 iex --sname node1 -S mix

# Terminal 2
TODO_HTTP_PORT=5455 iex --sname node2 -S mix
```

In either IEx session, connect the cluster (use the host suffix `Node.self()` prints, often your machine short name):

```elixir
Node.connect(:node2@yourhost)   # from node1
Node.list()                     # should include the other node
```

Add an entry via node1's HTTP port, then read it from node2 — the list server is unique cluster-wide, and the write was replicated:

```bash
# Terminal 3
curl -d '' 'http://localhost:5454/add_entry?list=bob&date=2018-12-19&title=Dentist'
curl 'http://localhost:5455/entries?list=bob&date=2018-12-19'
```

You should also see files under both `./persist/node1/` and `./persist/node2/`.

### Same APIs from IEx

```elixir
bob = Todo.Cache.server_process("bob")
Todo.Server.add_entry(bob, %{date: ~D[2018-12-19], title: "Dentist"})
Todo.Server.entries(bob, ~D[2018-12-19])
```

Call `Todo.Cache.server_process("bob")` on the other node: you get the **same** pid (or a local one only if none existed yet).

### Run tests

```bash
mix test
# uses port 5455 and ./test_persist/<node>/ by default
```
