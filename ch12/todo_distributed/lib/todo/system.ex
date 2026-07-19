defmodule Todo.System do
  def start_link do
    Supervisor.start_link(
      [
        # Todo.Metrics,
        Todo.Database,
        Todo.Cache,
        Todo.Web
      ],
      strategy: :one_for_one
    )
  end
end

# OR

# defmodule Todo.System do
#   use Supervisor

#   def start_link do
#     Supervisor.start_link(__MODULE__, nil)
#   end

#   def init(_) do
#     Supervisor.init([Todo.Cache], strategy: :one_for_one)
#   end
# end
