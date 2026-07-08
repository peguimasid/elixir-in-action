defmodule SimpleRegistry do
  use GenServer

  def start_link() do
    GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  end

  def register(key) do
    GenServer.call(__MODULE__, {:register, key})
  end

  def whereis(key) do
    GenServer.call(__MODULE__, {:whereis, key})
  end

  # Server calls

  @impl true
  def init(_) do
    Process.flag(:trap_exit, true)
    {:ok, %{}}
  end

  @impl true
  def handle_call({:register, key}, {caller_pid, _tag}, process_registry) do
    case Map.get(process_registry, key) do
      nil ->
        Process.link(caller_pid)
        {:reply, :ok, Map.put(process_registry, key, caller_pid)}

      _ ->
        {:reply, :error, process_registry}
    end
  end

  @impl true
  def handle_call({:whereis, key}, _from, process_registry) do
    {:reply, Map.get(process_registry, key), process_registry}
  end

  @impl true
  def handle_info({:EXIT, pid, _reason}, process_registry) do
    IO.puts("Process exited: #{inspect(pid)}")
    new_registry = deregister_pid(process_registry, pid)
    {:noreply, new_registry}
  end

  defp deregister_pid(process_registry, pid) do
    process_registry
    |> Enum.reject(fn {_key, value} -> value == pid end)
    |> Enum.into(%{})
  end
end
