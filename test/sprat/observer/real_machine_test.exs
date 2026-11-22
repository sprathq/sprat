defmodule Sprat.Observer.RealMachineTest do
  @moduledoc """
  Reads this machine's real Claude config dirs, read-only. Excluded by default;
  run with `mix test --only real_machine`.
  """
  use ExUnit.Case, async: false

  alias Sprat.Observer.{ConfigDirs, Projects, Registry, SessionState, Surfaces, Transcript}

  @moduletag :real_machine
  @moduletag timeout: :infinity

  test "scans sessions and parses their transcripts without crashing" do
    dirs = ConfigDirs.list()
    sessions = Registry.scan(dirs)
    live = Enum.filter(sessions, & &1.live?)
    surfaces = Surfaces.map()

    # Every session's transcript plus the 20 most recently written others.
    session_paths =
      sessions
      |> Enum.map(&Transcript.locate(&1.config_dir, &1.session_id))
      |> Enum.reject(&is_nil/1)

    recent =
      dirs
      |> Enum.flat_map(&Path.wildcard(Path.join(&1, "projects/*/*.jsonl")))
      |> Enum.sort_by(&File.stat!(&1, time: :posix).mtime, :desc)
      |> Enum.take(20)

    paths = Enum.uniq(session_paths ++ recent)

    {micros, results} =
      :timer.tc(fn ->
        Enum.map(paths, fn p ->
          {events, offset, _} = Transcript.read_from(p, 0, 1)
          state = SessionState.fold(events)
          {events, offset, state}
        end)
      end)

    events = Enum.flat_map(results, &elem(&1, 0))
    bytes = results |> Enum.map(&elem(&1, 1)) |> Enum.sum()
    by_kind = events |> Enum.frequencies_by(& &1.kind) |> Enum.sort()
    api = Enum.filter(events, &(&1.kind == :api_error))
    limits = Enum.filter(api, & &1.data.limit?)
    parsed = Enum.filter(limits, &is_map(&1.data.limit))
    limited_now = Enum.count(results, fn {_, _, s} -> s.usage_limit != nil end)
    asking = Enum.count(results, fn {_, _, s} -> s.asks_user? end)
    roots = live |> Enum.map(&Projects.resolve(&1.cwd).root) |> Enum.uniq()

    IO.puts("""

    config dirs:         #{inspect(dirs)}
    sessions found:      #{length(sessions)} (live #{length(live)}, with cmux surface #{Enum.count(live, &Map.has_key?(surfaces, &1.pid))})
    project roots (live): #{length(roots)}
    transcripts parsed:  #{length(paths)} (#{div(bytes, 1_048_576)} MB in #{div(micros, 1000)} ms)
    events by kind:      #{inspect(by_kind)}
    api errors:          #{length(api)}; usage limits #{length(limits)}, with reset parsed #{length(parsed)}
    states limited now:  #{limited_now}; asking the user: #{asking}
    unparsed limits:     #{limits |> Enum.reject(&is_map(&1.data.limit)) |> Enum.map(& &1.data.text) |> Enum.uniq() |> inspect()}
    """)

    assert is_list(sessions)
    assert Enum.all?(sessions, &(&1.status in [:busy, :idle, :shell, :ended, :unknown]))
  end
end
