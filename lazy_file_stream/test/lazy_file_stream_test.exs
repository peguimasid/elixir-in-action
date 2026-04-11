defmodule LazyFileStreamTest do
  use ExUnit.Case
  doctest LazyFileStream

  test "greets the world" do
    assert LazyFileStream.hello() == :world
  end
end
