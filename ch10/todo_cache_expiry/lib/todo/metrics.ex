defmodule Todo.Metrics do
  use Task

  def start_link(_arg) do
    Task.start_link(&loop/0)
  end

  def loop() do
    Process.sleep(:timer.seconds(10))
    IO.inspect(collect_metadata())
    loop()
  end

  def collect_metadata() do
    [
      memory_usage: :erlang.memory(:total),
      process_count: :erlang.system_info(:process_count)
    ]
  end
end
