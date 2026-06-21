defmodule Todo.Database do
  use GenServer

  @db_folder "./persist"

  def start_link do
    GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  end

  def store(key, data) do
    key
    |> choose_worker()
    |> Todo.DatabaseWorker.store(key, data)
  end

  def get(key) do
    key
    |> choose_worker()
    |> Todo.DatabaseWorker.get(key)
  end

  defp choose_worker(key) do
    GenServer.call(__MODULE__, {:choose_worker, key})
  end

  @impl GenServer
  def init(_) do
    IO.puts("Starting database server.")
    File.mkdir_p!(@db_folder)
    {:ok, start_workers()}
  end

  @impl GenServer
  def handle_call({:choose_worker, key}, _, workers) do
    idx = :erlang.phash2(key, 3)
    pid = Map.get(workers, idx)

    {:reply, pid, workers}
  end

  defp start_workers() do
    for index <- 0..2, into: %{} do
      {:ok, pid} = Todo.DatabaseWorker.start_link(@db_folder)
      {index, pid}
    end
  end
end
