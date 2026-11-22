defmodule Sprat.Store.PathsTest do
  # Mutates process-global SPRAT_DATA_DIR / :sprat, :data_dir state.
  use ExUnit.Case, async: false

  alias Sprat.Store.Paths

  # Both overrides outrank the platform default and both are process-global:
  # config/test.exs sets :data_dir for every test, and a sibling test may
  # leave SPRAT_DATA_DIR behind. A test here that wants the real resolution
  # must start from neither, or it silently asserts against an override —
  # which is how this module passed and failed at random.
  setup do
    previous_env = System.get_env("SPRAT_DATA_DIR")
    previous_app = Application.get_env(:sprat, :data_dir)
    System.delete_env("SPRAT_DATA_DIR")
    Application.delete_env(:sprat, :data_dir)

    on_exit(fn ->
      System.delete_env("SPRAT_DATA_DIR")
      Application.delete_env(:sprat, :data_dir)
      if previous_env, do: System.put_env("SPRAT_DATA_DIR", previous_env)
      if previous_app, do: Application.put_env(:sprat, :data_dir, previous_app)
    end)

    :ok
  end

  describe "resolve/1" do
    test "a :dev resolution never lands on the production path, for any platform" do
      # The coordinator's explicit requirement: a dev build must be
      # structurally unable to resolve to the same directory the shipped
      # production release uses. Proven directly against the pure
      # resolution logic (no Mix.env() mocking needed) with nothing else
      # configured, so both arms compute their real platform default.
      # SPRAT_DATA_DIR is process-global and outranks everything, so a
      # concurrent test that set it would make both arms equal and this
      # assertion meaningless. Clear it for the duration.
      {dev_dir, _reason} = Paths.resolve(:dev)
      {prod_dir, _reason} = Paths.resolve(:prod)

      assert dev_dir != prod_dir
      # and not merely "different" but genuinely separate, not a path
      # that happens to collide after normalization or a parent of it
      refute String.starts_with?(prod_dir, dev_dir)
      assert String.starts_with?(dev_dir, prod_dir)
      assert Path.basename(dev_dir) == "dev"
    end

    test ":dev reports why" do
      assert {_dir, reason} = Paths.resolve(:dev)
      assert reason =~ "dev build"
    end

    test ":prod resolves to the raw platform dir and reports 'production'" do
      assert {_dir, "production"} = Paths.resolve(:prod)
    end

    test ":test never resolves to the production path even with no config override" do
      {test_dir, reason} = Paths.resolve(:test)
      {prod_dir, _} = Paths.resolve(:prod)

      assert test_dir != prod_dir
      assert reason =~ "test"
    end

    test "SPRAT_DATA_DIR overrides everything, for every env" do
      System.put_env("SPRAT_DATA_DIR", "/tmp/sprat-override-test")
      Application.put_env(:sprat, :data_dir, "/tmp/should-be-ignored")

      for env <- [:dev, :test, :prod] do
        assert Paths.resolve(env) == {"/tmp/sprat-override-test", "SPRAT_DATA_DIR override"}
      end
    end

    test "the :sprat, :data_dir application config overrides the env default, but not SPRAT_DATA_DIR" do
      Application.put_env(:sprat, :data_dir, "/tmp/sprat-config-test")

      assert Paths.resolve(:dev) == {"/tmp/sprat-config-test", "config override"}
      assert Paths.resolve(:prod) == {"/tmp/sprat-config-test", "config override"}

      System.put_env("SPRAT_DATA_DIR", "/tmp/sprat-env-wins")
      assert Paths.resolve(:dev) == {"/tmp/sprat-env-wins", "SPRAT_DATA_DIR override"}
    end
  end

  describe "data_dir_with_reason/0" do
    test "reflects the current process env under the compiled-in (:test) env" do
      Application.put_env(:sprat, :data_dir, "/tmp/sprat-paths-test-dir")
      assert Paths.data_dir_with_reason() == {"/tmp/sprat-paths-test-dir", "config override"}
    end
  end
end
