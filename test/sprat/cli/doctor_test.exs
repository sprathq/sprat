defmodule Sprat.CLI.DoctorTest do
  # Mutates process-global :sprat, :data_dir / SPRAT_DATA_DIR state.
  use ExUnit.Case, async: false

  alias Sprat.CLI.Doctor

  setup do
    on_exit(fn ->
      System.delete_env("SPRAT_DATA_DIR")
      Application.delete_env(:sprat, :data_dir)
    end)

    :ok
  end

  describe "report/1" do
    test "prints the resolved data directory and why it was picked (config override)" do
      dir =
        Path.join(System.tmp_dir!(), "sprat-doctor-test-#{System.unique_integer([:positive])}")

      Application.put_env(:sprat, :data_dir, dir)

      db_path = Path.join(dir, "sprat.db")
      name = :"doctor_test_store_#{System.unique_integer([:positive])}"
      store = start_supervised!({Sprat.Store, name: name, db_path: db_path})

      lines = Doctor.report(store)
      data_dir_line = Enum.find(lines, &String.contains?(&1, dir))

      assert data_dir_line =~ "(config override)"
    end

    test "reports a SPRAT_DATA_DIR override even when a config override is also set" do
      config_dir =
        Path.join(System.tmp_dir!(), "sprat-doctor-config-#{System.unique_integer([:positive])}")

      override_dir =
        Path.join(
          System.tmp_dir!(),
          "sprat-doctor-override-#{System.unique_integer([:positive])}"
        )

      Application.put_env(:sprat, :data_dir, config_dir)
      System.put_env("SPRAT_DATA_DIR", override_dir)

      db_path = Path.join(override_dir, "sprat.db")
      name = :"doctor_test_store_#{System.unique_integer([:positive])}"
      store = start_supervised!({Sprat.Store, name: name, db_path: db_path})

      lines = Doctor.report(store)
      data_dir_line = Enum.find(lines, &String.contains?(&1, override_dir))

      assert data_dir_line =~ "(SPRAT_DATA_DIR override)"
      refute Enum.any?(lines, &String.contains?(&1, config_dir))
    end
  end

  # Seam test: Secrets.dotenv_safety/1 has been correct and unit-tested
  # since it was written ("used by `sprat doctor`" per its own @doc), but
  # nothing in the doctor report called it — an insecure `.env` never
  # surfaced anywhere a user would see it. This fails if that wiring is
  # removed, even though `dotenv_safety/1` itself stays correct in
  # isolation.
  describe "report/2 dotenv safety" do
    test "warns when the resolved key comes from a world-readable .env" do
      dir =
        Path.join(
          System.tmp_dir!(),
          "sprat-doctor-dotenv-test-#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(dir)
      env_path = Path.join(dir, ".env")
      File.write!(env_path, "OPENAI_API_KEY=sk-fake\n")
      File.chmod!(env_path, 0o644)
      on_exit(fn -> File.rm_rf(dir) end)

      db_path = Path.join(dir, "sprat.db")
      name = :"doctor_test_store_#{System.unique_integer([:positive])}"
      store = start_supervised!({Sprat.Store, name: name, db_path: db_path})

      lines = Doctor.report(store, dir)

      assert Enum.any?(lines, &(&1 =~ "warning:" and &1 =~ "readable"))
    end

    test "no warning when the key comes from an env var, not a .env file" do
      System.put_env("OPENAI_API_KEY", "sk-from-env")
      on_exit(fn -> System.delete_env("OPENAI_API_KEY") end)

      dir =
        Path.join(
          System.tmp_dir!(),
          "sprat-doctor-dotenv-envvar-test-#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf(dir) end)

      db_path = Path.join(dir, "sprat.db")
      name = :"doctor_test_store_#{System.unique_integer([:positive])}"
      store = start_supervised!({Sprat.Store, name: name, db_path: db_path})

      lines = Doctor.report(store, dir)

      refute Enum.any?(lines, &(&1 =~ "warning:"))
    end
  end
end
