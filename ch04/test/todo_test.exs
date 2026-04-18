Code.require_file("../todo.ex", __DIR__)

ExUnit.start()

defmodule TodoListTest do
  use ExUnit.Case

  describe "new/0" do
    test "returns an empty TodoList struct" do
      assert %TodoList{entries: %{}, next_id: 1} = TodoList.new()
    end
  end

  describe "new/1" do
    test "builds a TodoList from a list of entries" do
      entries = [
        %{date: ~D[2018-01-01], title: "Dinner"},
        %{date: ~D[2018-01-02], title: "Dentist"}
      ]

      list = TodoList.new(entries)

      assert [%{date: ~D[2018-01-01], title: "Dinner", id: 1}] =
               TodoList.entries(list, ~D[2018-01-01])

      assert [%{date: ~D[2018-01-02], title: "Dentist", id: 2}] =
               TodoList.entries(list, ~D[2018-01-02])
    end

    test "returns an empty TodoList when given an empty list" do
      assert %TodoList{entries: %{}, next_id: 1} = TodoList.new([])
    end
  end

  describe "add_entry/2" do
    test "adds a single entry with an auto-assigned id" do
      list = TodoList.new() |> TodoList.add_entry(%{date: ~D[2018-01-01], title: "Dinner"})

      assert [%{date: ~D[2018-01-01], title: "Dinner", id: 1}] =
               TodoList.entries(list, ~D[2018-01-01])
    end

    test "increments id for each new entry" do
      list =
        TodoList.new()
        |> TodoList.add_entry(%{date: ~D[2018-01-01], title: "Dinner"})
        |> TodoList.add_entry(%{date: ~D[2018-01-02], title: "Dentist"})

      assert [%{id: 1}] = TodoList.entries(list, ~D[2018-01-01])
      assert [%{id: 2}] = TodoList.entries(list, ~D[2018-01-02])
    end

    test "supports multiple entries on the same date" do
      list =
        TodoList.new()
        |> TodoList.add_entry(%{date: ~D[2018-01-02], title: "Dentist"})
        |> TodoList.add_entry(%{date: ~D[2018-01-02], title: "Meeting"})

      titles =
        TodoList.entries(list, ~D[2018-01-02])
        |> Enum.map(& &1.title)
        |> Enum.sort()

      assert titles == ["Dentist", "Meeting"]
    end
  end

  describe "entries/2" do
    test "returns an empty list when no entries match the date" do
      list = TodoList.new() |> TodoList.add_entry(%{date: ~D[2018-01-01], title: "Dinner"})

      assert [] == TodoList.entries(list, ~D[2018-12-31])
    end
  end

  describe "update_entry/3" do
    test "updates an existing entry" do
      list =
        TodoList.new()
        |> TodoList.add_entry(%{date: ~D[2018-01-01], title: "Dinner"})

      updated = TodoList.update_entry(list, 1, fn entry -> %{entry | title: "Lunch"} end)

      assert [%{id: 1, title: "Lunch", date: ~D[2018-01-01]}] =
               TodoList.entries(updated, ~D[2018-01-01])
    end

    test "returns the list unchanged when entry_id does not exist" do
      list =
        TodoList.new()
        |> TodoList.add_entry(%{date: ~D[2018-01-01], title: "Dinner"})

      updated = TodoList.update_entry(list, 999, fn entry -> %{entry | title: "Ghost"} end)

      assert list == updated
    end
  end

  describe "delete_entry/2" do
    test "removes an existing entry" do
      list =
        TodoList.new()
        |> TodoList.add_entry(%{date: ~D[2018-01-01], title: "Dinner"})

      updated = TodoList.delete_entry(list, 1)

      assert [] == TodoList.entries(updated, ~D[2018-01-01])
    end

    test "returns the list unchanged when entry_id does not exist" do
      list =
        TodoList.new()
        |> TodoList.add_entry(%{date: ~D[2018-01-01], title: "Dinner"})

      updated = TodoList.delete_entry(list, 999)

      assert list == updated
    end
  end
end

defmodule TodoList.CsvImporterTest do
  use ExUnit.Case

  @csv_path Path.expand("../todos.csv", __DIR__)

  describe "import/1" do
    test "returns a TodoList struct" do
      assert %TodoList{} = TodoList.CsvImporter.import(@csv_path)
    end

    test "imports the correct number of entries" do
      list = TodoList.CsvImporter.import(@csv_path)
      assert map_size(list.entries) == 3
    end

    test "assigns sequential ids starting from 1" do
      list = TodoList.CsvImporter.import(@csv_path)
      ids = list.entries |> Map.keys() |> Enum.sort()
      assert ids == [1, 2, 3]
    end

    test "parses dates correctly" do
      list = TodoList.CsvImporter.import(@csv_path)
      dates = list.entries |> Map.values() |> Enum.map(& &1.date) |> Enum.uniq() |> Enum.sort()
      assert dates == [~D[2018-12-19], ~D[2018-12-20]]
    end

    test "parses titles correctly" do
      list = TodoList.CsvImporter.import(@csv_path)
      titles = list.entries |> Map.values() |> Enum.map(& &1.title) |> Enum.sort()
      assert titles == ["Dentist", "Movies", "Shopping"]
    end

    test "entries on the same date are both present" do
      list = TodoList.CsvImporter.import(@csv_path)
      dec_19 = TodoList.entries(list, ~D[2018-12-19])
      titles = dec_19 |> Enum.map(& &1.title) |> Enum.sort()
      assert titles == ["Dentist", "Movies"]
    end
  end
end
