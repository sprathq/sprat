defmodule Sprat.Activity do
  @moduledoc """
  Everything Sprat does, as it happens (spec-v5 §2, §5).

  Two ETS tables owned by this process, written directly by whichever
  process does the work (a job, the engine, `Sprat.Cmd`), so recording never
  waits on a mailbox:

    * the **stream**: events newest last, trimmed to `@kept`;
      `%{at, kind, type, project_root, text, status}`;
    * the **commands**: one row per outside program Sprat runs (`cmux top`,
      `git log`, `ps`, `claude`), with how often, how long and how it ended.
      Polling commands run every few seconds, so they are counted here and
      only slow or timed-out runs reach the stream.

  Subscribers (`subscribe/0`) get `{:activity, event}` for every event.
  Without the process (tests, one-shot CLI commands) every call is a no-op.
  """

  use GenServer

  @stream :sprat_activity
  @commands :sprat_commands
  @registry Sprat.Activity.Registry
  @kept 500
  @slow_ms 3_000

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Children for a supervisor: the subscriber registry, then the tables' owner."
  def child_specs do
    [
      Supervisor.child_spec({Registry, keys: :duplicate, name: @registry}, id: @registry),
      __MODULE__
    ]
  end

  @impl true
  def init(_opts) do
    :ets.new(@stream, [:ordered_set, :public, :named_table, read_concurrency: true])
    :ets.new(@commands, [:set, :public, :named_table, write_concurrency: true])
    {:ok, %{}}
  end

  # -- writing ------------------------------------------------------------------

  @doc """
  Records an event. `kind`: `:job`, `:pm`, `:delivery`, `:finding`, `:engine`,
  `:command`, `:event`. `attrs`: `:text` (required), `:type`,
  `:project_root`, `:status` (`:ok | :running | :failed | :info`), `:at`.
  """
  def emit(kind, attrs) do
    if :ets.whereis(@stream) != :undefined do
      event = %{
        at: attrs[:at] || DateTime.utc_now(),
        kind: kind,
        type: attrs[:type],
        project_root: attrs[:project_root],
        text: to_string(attrs[:text] || ""),
        status: attrs[:status] || :info
      }

      key = System.unique_integer([:monotonic, :positive])
      :ets.insert(@stream, {key, event})
      if rem(key, 50) == 0, do: trim()
      broadcast(event)
    end

    :ok
  rescue
    ArgumentError -> :ok
  end

  @doc "An outside program started: counts it as running. Returns a token for `command_done/3`."
  def command_started(bin, args) do
    key = command_key(bin, args)

    if :ets.whereis(@commands) != :undefined do
      ensure_command(key)
      :ets.update_counter(@commands, key, {2, 1})
    end

    {key, System.monotonic_time(:millisecond)}
  rescue
    ArgumentError -> {command_key(bin, args), System.monotonic_time(:millisecond)}
  end

  @doc "An outside program ended with `status` (an exit code or `:timeout`)."
  def command_done({key, started}, status, line \\ nil) do
    ms = System.monotonic_time(:millisecond) - started

    if :ets.whereis(@commands) != :undefined do
      ensure_command(key)
      [{^key, running, runs, total, max, _, _, _}] = :ets.lookup(@commands, key)

      :ets.insert(
        @commands,
        {key, max(running - 1, 0), runs + 1, total + ms, max(max, ms), ms, status,
         DateTime.utc_now()}
      )

      cond do
        status == :timeout ->
          emit(:command,
            text: "#{line || key} did not finish in time and was stopped",
            status: :failed
          )

        ms >= @slow_ms ->
          emit(:command, text: "#{line || key} took #{Float.round(ms / 1000, 1)}s", status: :info)

        true ->
          :ok
      end
    end

    :ok
  rescue
    _ -> :ok
  end

  # -- reading ------------------------------------------------------------------

  @doc "The last `n` events, newest first."
  def recent(n \\ 200) do
    if :ets.whereis(@stream) != :undefined do
      @stream |> last_n(:ets.last(@stream), n, []) |> Enum.reverse()
    else
      []
    end
  rescue
    ArgumentError -> []
  end

  @doc "Every outside program Sprat has run since it started, busiest first."
  def commands do
    if :ets.whereis(@commands) != :undefined do
      @commands
      |> :ets.tab2list()
      |> Enum.map(fn {name, running, runs, total, max, last, status, at} ->
        %{
          name: name,
          running: running,
          runs: runs,
          avg_ms: if(runs > 0, do: div(total, runs), else: 0),
          max_ms: max,
          last_ms: last,
          last_status: status,
          last_at: at
        }
      end)
      |> Enum.sort_by(&{-&1.running, -&1.runs})
    else
      []
    end
  rescue
    ArgumentError -> []
  end

  @doc "Subscribes the caller to `{:activity, event}` messages."
  def subscribe do
    Registry.register(@registry, :activity, nil)
  end

  # -- internals ----------------------------------------------------------------

  defp broadcast(event) do
    if Process.whereis(@registry) do
      Registry.dispatch(@registry, :activity, fn entries ->
        for {pid, _} <- entries, do: send(pid, {:activity, event})
      end)
    end
  end

  defp last_n(_tab, :"$end_of_table", _n, acc), do: acc
  defp last_n(_tab, _key, 0, acc), do: acc

  defp last_n(tab, key, n, acc) do
    case :ets.lookup(tab, key) do
      [{^key, event}] -> last_n(tab, :ets.prev(tab, key), n - 1, [event | acc])
      [] -> last_n(tab, :ets.prev(tab, key), n, acc)
    end
  end

  defp trim do
    over = :ets.info(@stream, :size) - @kept
    if over > 0, do: drop_first(over)
  end

  defp drop_first(0), do: :ok

  defp drop_first(n) do
    case :ets.first(@stream) do
      :"$end_of_table" ->
        :ok

      key ->
        :ets.delete(@stream, key)
        drop_first(n - 1)
    end
  end

  defp ensure_command(key),
    do: :ets.insert_new(@commands, {key, 0, 0, 0, 0, 0, nil, nil})

  # "cmux top", "git log", "ps", "claude": the program and its subcommand,
  # never the arguments (which can carry message text).
  defp command_key(bin, args) do
    name = Path.basename(to_string(bin))

    # `git -C <repo> log …`: the subcommand comes after the repo.
    args =
      case args do
        ["-C", _repo | rest] -> rest
        args -> args
      end

    case args do
      [sub | _] when is_binary(sub) ->
        if Regex.match?(~r/^[a-z][a-z-]{1,24}$/, sub), do: "#{name} #{sub}", else: name

      _ ->
        name
    end
  end
end
