defmodule LazyFileStream do
  @moduledoc """
  Documentation for `LazyFileStream`.
  """

  @doc """
  Returns all lines from the file at `path` that are longer than 80 characters.
  Trailing newlines are trimmed before the length check.
  """
  def large_lines!(path) do
    File.stream!(path)
    |> Stream.map(&String.trim_trailing(&1, "\n"))
    |> Enum.filter(&(String.length(&1) > 80))
  end

  def lines_lengths!(path) do
    path
    |> File.stream!()
    |> Stream.map(&String.trim_trailing(&1, "\n"))
    |> Enum.map(&String.length/1)
  end
end
