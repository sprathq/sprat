defmodule Sprat.Store.BlobTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  import Bitwise

  alias Sprat.Store.Blob

  setup do
    root = Path.join(System.tmp_dir!(), "sprat-blob-test-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(root) end)
    {:ok, root: root}
  end

  describe "put/3 and get/2" do
    test "round-trips bytes", %{root: root} do
      {:ok, hash} = Blob.put("hello world", [], root)
      assert {:ok, "hello world"} = Blob.get(hash, root)
    end

    test "content-addresses: identical bytes hash to the same blob", %{root: root} do
      {:ok, h1} = Blob.put("same content", [], root)
      {:ok, h2} = Blob.put("same content", [], root)
      assert h1 == h2
    end

    test "different bytes hash differently", %{root: root} do
      {:ok, h1} = Blob.put("a", [], root)
      {:ok, h2} = Blob.put("b", [], root)
      refute h1 == h2
    end

    test "is stored under blobs/<prefix>/<hash> and 0600", %{root: root} do
      {:ok, hash} = Blob.put("perm check", [], root)
      <<prefix::binary-size(2), _::binary>> = hash
      path = Path.join([root, prefix, hash])
      assert File.exists?(path)
      assert (File.stat!(path).mode &&& 0o777) == 0o600
    end

    test "scrubs secrets before writing", %{root: root} do
      {:ok, hash} = Blob.put("token is sk-ant-secret123", ["sk-ant-secret123"], root)
      {:ok, bytes} = Blob.get(hash, root)
      refute String.contains?(bytes, "sk-ant-secret123")
    end

    test "get/2 on a missing hash returns :not_found", %{root: root} do
      assert {:error, :not_found} = Blob.get(String.duplicate("0", 64), root)
    end
  end

  describe "exists?/2" do
    test "true after put, false for an unknown hash", %{root: root} do
      {:ok, hash} = Blob.put("x", [], root)
      assert Blob.exists?(hash, root)
      refute Blob.exists?(String.duplicate("f", 64), root)
    end
  end

  describe "gc_orphans/2" do
    test "deletes blobs not in the referenced set, keeps the rest", %{root: root} do
      {:ok, kept} = Blob.put("keep me", [], root)
      {:ok, orphan} = Blob.put("delete me", [], root)

      deleted = Blob.gc_orphans([kept], root)

      assert deleted == 1
      assert Blob.exists?(kept, root)
      refute Blob.exists?(orphan, root)
    end

    test "deletes nothing when every blob is referenced", %{root: root} do
      {:ok, hash} = Blob.put("keep me", [], root)
      assert Blob.gc_orphans([hash], root) == 0
      assert Blob.exists?(hash, root)
    end
  end

  property "any binary round-trips exactly through put/get" do
    check all(bytes <- StreamData.binary(max_length: 500)) do
      root = Path.join(System.tmp_dir!(), "sprat-blob-prop-#{System.unique_integer([:positive])}")

      try do
        {:ok, hash} = Blob.put(bytes, [], root)
        assert {:ok, ^bytes} = Blob.get(hash, root)
      after
        File.rm_rf(root)
      end
    end
  end
end
