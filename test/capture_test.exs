# SPDX-License-Identifier: Apache-2.0

defmodule CaptureTest do
  use ExUnit.Case, async: true
  import Ecto.Adapters.SQL, only: [query!: 2]
  alias Carbonite.TestRepo
  alias Ecto.Adapters.SQL.Sandbox

  setup do
    :ok = Sandbox.checkout(TestRepo)
  end

  defp query!(statement), do: query!(TestRepo, statement)

  defp insert_transaction do
    query!("INSERT INTO carbonite_default.transactions (inserted_at) VALUES (NOW());")
  end

  defp insert_jack do
    query!("INSERT INTO rabbits (name, age) VALUES ('Jack', 99);")
  end

  defp select_changes do
    "SELECT * FROM carbonite_default.changes;"
    |> query!()
    |> postgrex_result_to_structs()
  end

  defp select_rabbits do
    "SELECT * FROM public.rabbits;"
    |> query!()
    |> postgrex_result_to_structs()
  end

  defp postgrex_result_to_structs(%Postgrex.Result{columns: columns, rows: rows}) do
    Enum.map(rows, fn row ->
      columns
      |> Enum.zip(row)
      |> Map.new()
    end)
  end

  describe "change capture trigger" do
    test "INSERTs on tables are tracked as changes" do
      TestRepo.transaction(fn ->
        insert_transaction()
        insert_jack()
      end)

      assert [
               %{
                 "id" => _,
                 "transaction_id" => _,
                 "table_prefix" => "public",
                 "table_name" => "rabbits",
                 "op" => "insert",
                 "old" => nil,
                 "new" => %{"id" => _, "name" => "Jack"}
               }
             ] = select_changes()
    end

    test "UPDATEs on tables are tracked as changes" do
      TestRepo.transaction(fn ->
        insert_transaction()
        insert_jack()
        query!("UPDATE rabbits SET name = 'Jane' WHERE name = 'Jack';")
      end)

      assert [
               %{
                 "op" => "insert",
                 "old" => nil,
                 "new" => %{"id" => _, "name" => "Jack"}
               },
               %{
                 "op" => "update",
                 "old" => %{"id" => _, "name" => "Jack"},
                 "new" => %{"id" => _, "name" => "Jane"}
               }
             ] = select_changes()
    end

    test "DELETEs on tables are tracked as changes" do
      TestRepo.transaction(fn ->
        insert_transaction()
        insert_jack()
        query!("DELETE FROM rabbits WHERE name = 'Jack';")
      end)

      assert [
               %{
                 "op" => "insert",
                 "old" => nil,
                 "new" => %{"id" => _, "name" => "Jack"}
               },
               %{
                 "op" => "delete",
                 "old" => %{"id" => _, "name" => "Jack"},
                 "new" => nil
               }
             ] = select_changes()
    end

    test "a friendly error is raised when transaction is not inserted or is inserted too late" do
      msg =
        "ERROR 23503 (foreign_key_violation) INSERT on table public.rabbits " <>
          "without prior INSERT into carbonite_default.transactions"

      assert_raise Postgrex.Error, msg, fn ->
        TestRepo.transaction(&insert_jack/0)
      end
    end
  end

  describe "excluded columns" do
    test "excluded columns do not appear in captured data" do
      TestRepo.transaction(fn ->
        insert_transaction()
        insert_jack()
      end)

      assert [%{"new" => new}] = select_changes()
      refute Map.has_key?(new, "age")
    end

    test "UPDATEs on only excluded fields are not tracked" do
      TestRepo.transaction(fn ->
        insert_transaction()
        insert_jack()
        query!("UPDATE rabbits SET age = 100 WHERE name = 'Jack';")
      end)

      assert [%{"age" => 100}] = select_rabbits()
      assert [%{"op" => "insert"}] = select_changes()
    end
  end
end