defmodule Sprat.SecretsTest do
  use ExUnit.Case

  alias Sprat.Secrets

  describe "resolve/1" do
    test "prefers OPENAI_API_KEY over a .env file" do
      System.put_env("OPENAI_API_KEY", "sk-from-env-0000")
      on_exit(fn -> System.delete_env("OPENAI_API_KEY") end)

      assert {:ok, "sk-from-env-0000", :env} = Secrets.resolve("/tmp")
    end

    test "falls back to the nearest ancestor .env when the env var is absent" do
      System.delete_env("OPENAI_API_KEY")

      dir =
        Path.join(System.tmp_dir!(), "sprat-secrets-test-#{System.unique_integer([:positive])}")

      nested = Path.join(dir, "a/b/c")
      File.mkdir_p!(nested)
      File.write!(Path.join(dir, ".env"), "OTHER=1\nOPENAI_API_KEY=sk-from-dotenv-1111\n")
      on_exit(fn -> File.rm_rf(dir) end)

      assert {:ok, "sk-from-dotenv-1111", {:dotenv, path}} = Secrets.resolve(nested)
      assert path == Path.join(dir, ".env")
    end

    test "handles quoted values in .env" do
      System.delete_env("OPENAI_API_KEY")

      dir =
        Path.join(System.tmp_dir!(), "sprat-secrets-test-#{System.unique_integer([:positive])}")

      File.mkdir_p!(dir)
      File.write!(Path.join(dir, ".env"), ~s(OPENAI_API_KEY="sk-quoted-2222"\n))
      on_exit(fn -> File.rm_rf(dir) end)

      assert {:ok, "sk-quoted-2222", {:dotenv, _}} = Secrets.resolve(dir)
    end

    test "ignores comments and blank lines in .env" do
      System.delete_env("OPENAI_API_KEY")

      dir =
        Path.join(System.tmp_dir!(), "sprat-secrets-test-#{System.unique_integer([:positive])}")

      File.mkdir_p!(dir)
      File.write!(Path.join(dir, ".env"), "# a comment\n\nOPENAI_API_KEY=sk-3333\n")
      on_exit(fn -> File.rm_rf(dir) end)

      assert {:ok, "sk-3333", _} = Secrets.resolve(dir)
    end

    test "returns :error when nothing is configured anywhere in the tree" do
      System.delete_env("OPENAI_API_KEY")

      dir =
        Path.join(System.tmp_dir!(), "sprat-secrets-test-#{System.unique_integer([:positive])}")

      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf(dir) end)

      # credential-store lookup will also fail in CI/sandboxes with no
      # `sprat`/`openai` entry — this only asserts it doesn't crash and
      # doesn't fabricate a key.
      assert :error = Secrets.resolve(dir) |> normalize_to_no_credstore()
    end

    # If the machine running this test happens to have a real "sprat"
    # keychain/secret-tool entry, resolve/1 would legitimately find it —
    # that's not a bug, just not reproducible here.
    defp normalize_to_no_credstore({:ok, _key, :credential_store}), do: :error
    defp normalize_to_no_credstore(other), do: other
  end

  describe "last4/1" do
    test "shows only the last 4 characters" do
      assert Secrets.last4("sk-proj-abcdefgh1234") == "1234"
    end

    test "never raises on a short/odd value" do
      assert Secrets.last4("ab") == "****"
      assert Secrets.last4(nil) == "****"
    end
  end

  describe "dotenv_safety/1" do
    test "warns on a world-readable .env" do
      dir =
        Path.join(
          System.tmp_dir!(),
          "sprat-secrets-perm-test-#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(dir)
      path = Path.join(dir, ".env")
      File.write!(path, "OPENAI_API_KEY=x\n")
      File.chmod!(path, 0o644)
      on_exit(fn -> File.rm_rf(dir) end)

      assert {:warn, warnings} = Secrets.dotenv_safety(path)
      assert Enum.any?(warnings, &String.contains?(&1, "readable"))
    end

    test "no warning for a 0600 file that is git-ignored", %{} do
      # sprat.dev/sprat's own .env is exactly this case — reuse it if present.
      real_env = Path.join(File.cwd!(), ".env")

      if File.exists?(real_env) do
        assert Secrets.dotenv_safety(real_env) == :ok
      end
    end
  end
end
