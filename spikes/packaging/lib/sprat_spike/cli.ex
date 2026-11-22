defmodule SpratSpike.CLI do
  @moduledoc """
  Minimal CLI dispatch, proving argv reaches the packaged binary (Phase 0
  packaging spike, docs/spec-v1.md §14 item 4).
  """

  alias SpratSpike.Db
  alias SpratSpike.HttpCheck
  alias SpratSpike.Paths
  alias SpratSpike.RawMode

  @version "0.1.0"

  @doc "Runs the command for `argv`, returns an exit code."
  def main(argv)

  def main(["--version"]) do
    puts("sprat-spike #{@version}")
    0
  end

  def main(["doctor"]) do
    puts("sprat-spike doctor")
    puts("  otp:      #{:erlang.system_info(:otp_release)}")
    puts("  elixir:   #{System.version()}")
    puts("  data dir: #{Paths.data_dir()}")

    case Db.smoke_test() do
      {:ok, %{sqlite_version: v}} -> puts("  sqlite:   #{v} (ok)")
      {:error, reason} -> puts("  sqlite:   error - #{inspect(reason)}")
    end

    0
  end

  def main(["smoke"]) do
    puts("running risky-parts smoke test…")
    run_db_check()
    run_http_check()
    run_raw_mode_check()
    0
  end

  def main([]) do
    puts("sprat-spike (packaging spike) — no command given. Try --version, doctor, or smoke.")
    0
  end

  def main(other) do
    puts("unknown args: #{inspect(other)}")
    1
  end

  defp run_db_check do
    case Db.smoke_test() do
      {:ok, %{path: path, row: row, sqlite_version: v}} ->
        puts("  db:   ok · sqlite #{v} · #{path} · row #{inspect(row)}")

      {:error, reason} ->
        puts("  db:   FAILED · #{inspect(reason)}")
    end
  end

  defp run_http_check do
    case HttpCheck.smoke_test() do
      {:ok, status} -> puts("  http: ok · status #{status}")
      {:error, reason} -> puts("  http: FAILED · #{inspect(reason)}")
    end
  end

  defp run_raw_mode_check do
    puts("  raw:  press any key…")

    case RawMode.smoke_test() do
      {:ok, bytes} -> puts("  raw:  ok · bytes #{inspect(bytes)}")
      {:error, reason} -> puts("  raw:  FAILED · #{inspect(reason)}")
    end
  end

  defp puts(line) do
    IO.puts(line)
  end
end
