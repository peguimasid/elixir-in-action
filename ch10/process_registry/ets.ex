defmodule SimpleRegistry do
  use GenServer

  def start_link() do
    GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  end

  def register(key) do
    Process.link(Process.whereis(__MODULE__))

    if :ets.insert_new(:simple_registry, {key, self()}) do
      :ok
    else
      :error
    end
  end

  def whereis(key) do
    case :ets.lookup(:simple_registry, key) do
      [{^key, pid}] -> pid
      [] -> nil
    end
  end

  # Server calls

  @impl true
  def init(_) do
    Process.flag(:trap_exit, true)

    :ets.new(:simple_registry, [
      :named_table,
      :public,
      read_concurrency: true,
      write_concurrency: true
    ])

    {:ok, nil}
  end

  @impl true
  def handle_info({:EXIT, pid, _reason}, state) do
    :ets.match_delete(:simple_registry, {:_, pid})
    {:noreply, state}
  end
end
