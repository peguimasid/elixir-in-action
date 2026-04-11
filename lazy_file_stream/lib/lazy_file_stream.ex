defmodule LazyFileStream do
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

  def longest_line_length!(path) do
    path
    |> lines_lengths!()
    |> Enum.max()
  end

  def longest_line!(path) do
    path
    |> File.stream!()
    |> Stream.map(&String.trim_trailing(&1, "\n"))
    |> Enum.max_by(&String.length/1)
  end
end
