Code.require_file("../todo.ex", __DIR__)

ExUnit.start()

defmodule TodoListTest do
  use ExUnit.Case

  describe "new/0" do
    test "returns an empty TodoList struct" do
      assert %TodoList{entries: %{}, next_id: 1} = TodoList.new()
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
