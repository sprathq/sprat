defmodule Sprat.Verify.CLI do
  @moduledoc """
  `sprat hook stop`: the command Claude Code runs on every Stop in a project
  that ran `sprat attach` (spec-v4 §9 "Verify (opt-in)").

  It reads the hook's JSON from stdin, finds the project's `.sprat/checks`,
  runs them in the session's checkout, and prints
  `{"decision":"block","reason":…}` or nothing. On **any** error it prints
  nothing and returns normally, so the hook exits 0 and the stop goes
  through: a supervisor that breaks the session when it is down is worse
  than none (spec-v3 §6).

  It never starts the `:sprat` application. In a release it runs as
  `<release>/bin/sprat_rt eval 'Sprat.Verify.CLI.main(["stop"])'`; in dev as
  `mix run --no-start --no-compile -e …` (see `Sprat.Verify.Attach.hook_command/0`).

  State per session (`<data>/v4/verify/<session_id>.json`): how many stops
  Sprat refused in the current chain and the working-tree fingerprint of the
  last refusal. Every decision is appended to `<data>/v4/verify.log` and,
  when the observer store opens, logged as a `verify` event; a refusal also
  becomes a served-today line.
  """

  alias Sprat.Observer.Model.Served
  alias Sprat.Observer.{Projects, Store}
  alias Sprat.Verify

  @max_blocks 4

  @doc "Entry point: `main([\"stop\"])` reads stdin and prints the decision."
  def main(["stop"]) do
    # Nothing but the decision may reach Claude Code: no log lines, no
    # crash reports from a store that would not open.
    Logger.configure(level: :none)
    text = IO.read(:stdio, :eof)

    case stop(if(is_binary(text), do: text, else: ""), []) do
      nil -> :ok
      json -> IO.write(json)
    end

    :ok
  catch
    _, _ -> :ok
  end

  def main(_other), do: :ok

  @doc """
  The whole hook, minus stdin/stdout: returns the JSON to print, or `nil`.

  Options (tests): `:data_dir` (default Sprat's data dir), `:store_path`
  (default `Store.default_path/0`; `false` skips the store), `:runner`,
  `:timeout_ms`, `:budget_ms` (passed to `Sprat.Verify.run_checks/3`),
  `:now`.
  """
  @spec stop(String.t(), keyword()) :: String.t() | nil
  def stop(text, opts) do
    do_stop(JSON.decode!(text), opts)
  rescue
    _ -> nil
  catch
    _, _ -> nil
  end

  defp do_stop(%{} = input, opts) do
    cwd = input["cwd"] || File.cwd!()
    session_id = safe_id(input["session_id"])
    top = toplevel(cwd)
    root = Projects.resolve(cwd).root

    checks =
      case Verify.load_checks(top) do
        [] when root != top -> Verify.load_checks(root)
        found -> found
      end

    data_dir = Keyword.get_lazy(opts, :data_dir, &Sprat.Store.Paths.data_dir/0)
    state_path = Path.join([data_dir, "v4", "verify", session_id <> ".json"])
    state = read_state(state_path)
    stop_active? = input["stop_hook_active"] == true
    blocks_so_far = if stop_active?, do: state["blocks"] || 0, else: 0
    fp = if checks == [], do: nil, else: Verify.fingerprint(top)

    changed? =
      cond do
        blocks_so_far == 0 -> true
        fp == nil -> false
        true -> fp != state["fingerprint"]
      end

    ctx = %{
      checks: checks,
      results: [],
      blocks_so_far: blocks_so_far,
      max_blocks: @max_blocks,
      changed_since_last_block?: changed?
    }

    why = Verify.allow_without_running(input, ctx)

    results =
      if why,
        do: [],
        else:
          Verify.run_checks(top, checks, Keyword.take(opts, [:runner, :timeout_ms, :budget_ms]))

    ctx = %{ctx | results: results}
    decision = Verify.decide(input, ctx)
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)

    {why, new_state} =
      case {decision, why} do
        {{:block, _}, _} ->
          failing = for r <- results, r.status in [:failed, :timed_out, :not_run], do: r.command
          {:failed, %{"blocks" => blocks_so_far + 1, "fingerprint" => fp, "failing" => failing}}

        {:allow, nil} ->
          {:passed, %{"blocks" => 0}}

        {:allow, why} ->
          {why, Map.put(state, "blocks", blocks_so_far)}
      end

    entry = %{
      session_id: session_id,
      cwd: top,
      project_root: root,
      decision: if(match?({:block, _}, decision), do: "block", else: "allow"),
      why: why,
      blocks: new_state["blocks"],
      checks: Enum.map(results, &%{command: &1.command, exit: &1.exit, status: &1.status})
    }

    if checks != [] do
      write_state(state_path, Map.put(new_state, "at", DateTime.to_iso8601(now)))
    end

    log_line(data_dir, now, entry)

    if checks != [] do
      record(opts, now, root, entry, decision, state)
    end

    case decision do
      {:block, reason} -> JSON.encode!(%{"decision" => "block", "reason" => reason})
      :allow -> nil
    end
  end

  # ── helpers ─────────────────────────────────────────────────────────────

  defp safe_id(id) when is_binary(id) and id != "" do
    String.replace(id, ~r/[^A-Za-z0-9_.-]/, "_") |> String.slice(0, 128)
  end

  defp safe_id(_), do: "unknown"

  defp toplevel(cwd) do
    case System.cmd("git", ["-C", cwd, "rev-parse", "--show-toplevel"], stderr_to_stdout: true) do
      {out, 0} -> String.trim(out)
      _ -> cwd
    end
  end

  defp read_state(path) do
    with {:ok, text} <- File.read(path), {:ok, %{} = s} <- JSON.decode(text) do
      s
    else
      _ -> %{}
    end
  end

  defp write_state(path, state) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, JSON.encode!(state))
  end

  defp log_line(data_dir, now, e) do
    dir = Path.join(data_dir, "v4")
    File.mkdir_p!(dir)

    checks = Enum.map_join(e.checks, " ", &"[#{&1.command} → #{&1.exit || &1.status}]")

    line =
      "#{DateTime.to_iso8601(now)} #{e.decision} (#{e.why}) session=#{e.session_id} " <>
        "cwd=#{e.cwd} blocks=#{e.blocks} #{checks}\n"

    File.write!(Path.join(dir, "verify.log"), line, [:append])
  end

  # The observer store, opened without the daemon: a verify event for every
  # decision, a served-today line for a refusal or an escalation. Anything
  # that goes wrong here (locked, missing NIF, slow) is skipped silently.
  defp record(opts, now, root, entry, decision, old_state) do
    case Keyword.get_lazy(opts, :store_path, &Store.default_path/0) do
      false ->
        :ok

      path ->
        # Not linked: a crash or a hang in here must never take the hook down.
        {pid, mref} =
          spawn_monitor(fn ->
            {:ok, store} = GenServer.start(Store, path: path)

            try do
              {:ok, _} = Store.log_event(store, :verify, entry, now)

              case served_text(decision, entry, old_state) do
                nil ->
                  :ok

                text ->
                  served = %Served{
                    at: now,
                    project_name: Path.basename(root),
                    text: text,
                    by: :sprat
                  }

                  {:ok, _} = Store.record_served(store, served, root)
              end
            after
              GenServer.stop(store)
            end
          end)

        receive do
          {:DOWN, ^mref, :process, ^pid, _} -> :ok
        after
          3_000 -> Process.exit(pid, :kill)
        end
    end
  catch
    _, _ -> :ok
  end

  defp served_text({:block, _}, entry, _old) do
    failing =
      for c <- entry.checks, c.status in [:failed, :timed_out, :not_run], do: c.command

    "refused a stop: #{Enum.join(failing, ", ")} failed"
  end

  defp served_text(:allow, %{why: :max_blocks} = e, old) do
    still = Enum.join(old["failing"] || [], ", ")

    "stopped refusing after #{e.blocks} blocked stops" <>
      if(still != "", do: ": #{still} still failing, needs you", else: ", needs you")
  end

  defp served_text(_, _, _), do: nil
end
