defmodule LazyFileStreamTest do
  use ExUnit.Case

  @fixture_path "test/fixtures/sample.txt"

  setup_all do
    File.mkdir_p!("test/fixtures")

    short_line = "short line"
    exact_line = String.duplicate("a", 80)
    long_line = String.duplicate("b", 81)
    very_long_line = String.duplicate("c", 120)

    File.write!(@fixture_path, Enum.join([short_line, exact_line, long_line, very_long_line], "\n"))

    on_exit(fn -> File.rm!(@fixture_path) end)
  end

  test "returns only lines longer than 80 characters" do
    result = LazyFileStream.large_lines!(@fixture_path)
    assert length(result) == 2
  end

  test "does not include lines with exactly 80 characters" do
    result = LazyFileStream.large_lines!(@fixture_path)
    refute Enum.any?(result, &(String.length(&1) == 80))
  end

  test "returned lines have no trailing newline" do
    result = LazyFileStream.large_lines!(@fixture_path)
    assert Enum.all?(result, &(not String.ends_with?(&1, "\n")))
  end

  test "returns empty list when no lines exceed 80 characters" do
    path = "test/fixtures/all_short.txt"
    File.write!(path, "hello\nworld\n")
    assert LazyFileStream.large_lines!(path) == []
    File.rm!(path)
  end
end
