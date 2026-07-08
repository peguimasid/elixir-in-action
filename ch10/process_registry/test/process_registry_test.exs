defmodule ProcessRegistryTest do
  use ExUnit.Case
  doctest ProcessRegistry

  test "greets the world" do
    assert ProcessRegistry.hello() == :world
  end
end
