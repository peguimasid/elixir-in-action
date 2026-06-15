defmodule Todo.DatabaseTest do
  use ExUnit.Case

  setup do
    {:ok, pid} = Todo.Database.start()

    on_exit(fn ->
      GenServer.stop(pid)
      File.rm_rf!("./persist")
    end)

    :ok
  end

  test "stores and retrieves data" do
    Todo.Database.store("test_key", %{name: "Alice", age: 30})
    result = Todo.Database.get("test_key")

    assert result == %{name: "Alice", age: 30}
  end

  test "returns nil for unknown key" do
    result = Todo.Database.get("nonexistent_key")
    assert result == nil
  end

  test "overwrites existing data" do
    Todo.Database.store("overwrite_key", "first")
    Todo.Database.store("overwrite_key", "second")

    # Give the async cast time to complete
    :timer.sleep(100)

    assert Todo.Database.get("overwrite_key") == "second"
  end

  test "different keys route to potentially different workers" do
    Todo.Database.store("key_a", :data_a)
    Todo.Database.store("key_b", :data_b)
    Todo.Database.store("key_c", :data_c)

    assert Todo.Database.get("key_a") == :data_a
    assert Todo.Database.get("key_b") == :data_b
    assert Todo.Database.get("key_c") == :data_c
  end
end

defmodule Todo.DatabaseWorkerTest do
  use ExUnit.Case

  @test_folder "./test_persist"

  setup do
    File.mkdir_p!(@test_folder)
    {:ok, worker} = Todo.DatabaseWorker.start(@test_folder)

    on_exit(fn ->
      File.rm_rf!(@test_folder)
    end)

    {:ok, worker: worker}
  end

  test "stores and retrieves a value", %{worker: worker} do
    Todo.DatabaseWorker.store(worker, "alice", %{entries: []})
    result = Todo.DatabaseWorker.get(worker, "alice")

    assert result == %{entries: []}
  end

  test "returns nil for a missing key", %{worker: worker} do
    result = Todo.DatabaseWorker.get(worker, "missing")
    assert result == nil
  end

  test "overwrites data for the same key", %{worker: worker} do
    Todo.DatabaseWorker.store(worker, "bob", "v1")
    # store is a cast, wait briefly before reading
    :timer.sleep(50)
    Todo.DatabaseWorker.store(worker, "bob", "v2")
    :timer.sleep(50)

    assert Todo.DatabaseWorker.get(worker, "bob") == "v2"
  end

  test "persists complex term structures", %{worker: worker} do
    data = %{date: ~D[2024-01-15], title: "Meeting", tags: [:work, :important]}
    Todo.DatabaseWorker.store(worker, "complex", data)
    :timer.sleep(50)

    assert Todo.DatabaseWorker.get(worker, "complex") == data
  end
end
