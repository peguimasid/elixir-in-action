# Key Value — Chapter 10

This is a standalone Chapter 10 example (not part of the to-do system). The focus here is **comparing a process-owned map with an ETS table for concurrent key-value storage**, and measuring how much throughput you gain when reads and writes no longer serialize through a single `GenServer`.

## The Goal: Share Data Without a Bottleneck

A `GenServer` that holds a map works fine for a single client: `put` and `get` go through the process mailbox, the process updates or reads its state, and replies. Under concurrent load that becomes a bottleneck — every operation waits its turn in one mailbox, even when the operations are independent.

ETS (Erlang Term Storage) is the BEAM's answer: an in-memory table that multiple processes can read and write concurrently, without routing every access through a single owner process. The owner still creates and owns the table (so it can be cleaned up if the owner dies), but the hot path — `put` and `get` — talks to ETS directly.

## The Baseline: `KeyValue` as a Map-Backed `GenServer`

```elixir
defmodule KeyValue do
  use GenServer

  def start_link do
    GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  end

  def put(key, value) do
    GenServer.cast(__MODULE__, {:put, key, value})
  end

  def get(key) do
    GenServer.call(__MODULE__, {:get, key})
  end

  @impl GenServer
  def init(_) do
    {:ok, %{}}
  end

  @impl GenServer
  def handle_cast({:put, key, value}, store) do
    {:noreply, Map.put(store, key, value)}
  end

  @impl GenServer
  def handle_call({:get, key}, _, store) do
    {:reply, Map.get(store, key), store}
  end
end
```

Every `put` and `get` is a message to one process. The map lives entirely in that process's heap, so concurrency is limited to how fast the mailbox can be drained.

## The Fix: `EtsKeyValue` with a Public ETS Table

```elixir
defmodule EtsKeyValue do
  use GenServer

  def start_link do
    GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  end

  def put(key, value) do
    :ets.insert(__MODULE__, {key, value})
  end

  def get(key) do
    case :ets.lookup(__MODULE__, key) do
      [{^key, value}] -> value
      [] -> nil
    end
  end

  @impl GenServer
  def init(_) do
    :ets.new(__MODULE__, [:named_table, :public, write_concurrency: true])
    {:ok, nil}
  end
end
```

A few things worth noting:

- **The `GenServer` still exists**, but only to create and own the ETS table in `init/1`. Its process state is `nil` — the data lives in the table, not in the GenServer's heap.
- **`:named_table`** registers the table under the module name (`EtsKeyValue`), so callers can address it without holding a table reference.
- **`:public`** lets any process read and write the table, not just the owner. That's what makes concurrent `put`/`get` possible without messaging the GenServer.
- **`write_concurrency: true`** tunes the table for many concurrent writers (at some cost to single-writer throughput).
- **`put/2` and `get/1` never call `GenServer`.** They hit `:ets.insert/2` and `:ets.lookup/2` directly in the caller's process, so independent operations truly run in parallel.

## Benchmarking Both Approaches

`Bench` starts the given module, then fans out concurrent load processes that each `put` and `get` a slice of a million keys repeatedly:

```elixir
defmodule Bench do
  @total_keys 1_000_000

  def run(module, opts \\ []) do
    concurrency = min(Keyword.get(opts, :concurrency, 1), @total_keys)
    num_updates = Keyword.get(opts, :num_updates, 10)
    # ... spawn `concurrency` tasks, each updating its key range ...
  end
end
```

Pass either `KeyValue` or `EtsKeyValue` as the module. Raising `:concurrency` is where the difference shows: the map-backed GenServer stays roughly flat (one mailbox), while the ETS version scales with the number of concurrent clients.

## Process / Data Layout

```
KeyValue (GenServer)
└── state: %{key => value, ...}   ← all reads/writes go through this process

EtsKeyValue (GenServer)
├── process state: nil            ← owner only; no data here
└── ETS table :EtsKeyValue        ← :public, named; callers insert/lookup directly
      ├── {key1, value1}
      ├── {key2, value2}
      └── ...
```

## `GenServer` Map vs ETS

| | `KeyValue` (map in GenServer) | `EtsKeyValue` (ETS table) |
|---|---|---|
| Where data lives | process heap (`%{}`) | ETS table owned by the GenServer |
| How `put`/`get` work | `cast` / `call` into one mailbox | `:ets.insert` / `:ets.lookup` in the caller |
| Concurrent clients | serialized through one process | true parallel access (`:public` + `write_concurrency`) |
| Role of the GenServer | store + serve every request | create/own the table; not on the hot path |
| Best fit | small shared state, low concurrency | high-read / high-write shared caches and lookups |

ETS doesn't replace processes — you still want a supervised owner so the table's lifetime is tied to something that can crash and be restarted. What it removes is the requirement that *every* access go through that owner.

## Try It in IEx

```elixir
# Map-backed GenServer
KeyValue.start_link()
KeyValue.put(:answer, 42)
KeyValue.get(:answer)
#=> 42

# ETS-backed store — same API shape
EtsKeyValue.start_link()
EtsKeyValue.put(:answer, 42)
EtsKeyValue.get(:answer)
#=> 42

# Compare throughput (single client vs many)
Bench.run(KeyValue, concurrency: 1)
#=> 1.640.260 operations/sec

Bench.run(EtsKeyValue, concurrency: 1)
#=> 16.666.792 operations/sec

Bench.run(KeyValue, concurrency: 100)
#=> 1.462.603 operations/sec

Bench.run(EtsKeyValue, concurrency: 100)
#=> 13.151.777 operations/sec
```

Numbers above are from one run on this machine: Apple M4 Max, 16 cores, 64 GB RAM

Your absolute ops/sec will almost certainly differ (often by a lot) on other hardware — that's expected. What should hold is the *relative* gap: ETS stays roughly an order of magnitude ahead of the map-backed GenServer.

Even with a single client, `EtsKeyValue` is roughly **10×** faster than `KeyValue`. That isn't concurrency yet: it's the cost of going through a `GenServer`. Every `KeyValue.put/2` is a `cast` and every `get/1` is a `call`, so each operation pays for message passing, mailbox scheduling, and callback dispatch. `EtsKeyValue` skips all of that — `:ets.insert/2` and `:ets.lookup/2` run in the caller's process against a shared table.

At `concurrency: 100`, `KeyValue` stays flat (~1.400.000–1.600.000 ops/sec): a hundred clients still line up behind one mailbox, so more processes don't buy more throughput. `EtsKeyValue` stays in the ~13.000.000–16.000.000 range — still an order of magnitude ahead — because those clients actually touch the table in parallel. A small dip versus the single-client ETS run is normal under write contention and scheduler noise; the important result is that the GenServer map never scales, while ETS keeps delivering far higher throughput.
