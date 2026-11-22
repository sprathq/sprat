defmodule SpratSpike.DbTest do
  use ExUnit.Case, async: false

  alias SpratSpike.Db

  test "smoke_test/0 creates, inserts inside a transaction, and reads back" do
    assert {:ok, %{row: [id, note], sqlite_version: version}} = Db.smoke_test()
    assert is_integer(id)
    assert is_binary(note)
    assert is_binary(version)
  end
end
