defmodule KeyValueTest do
  use ExUnit.Case
  doctest KeyValue

  test "greets the world" do
    assert KeyValue.hello() == :world
  end
end
