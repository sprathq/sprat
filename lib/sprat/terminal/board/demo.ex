defmodule Sprat.Terminal.Board.Demo do
  @moduledoc """
  Runs `Sprat.Terminal.BoardApp` against `Sprat.Terminal.Board.Fixture`
  (`mix sprat.board_demo`). Commands do nothing real, but reply the way
  the engine does: most show as a transient message, `f` / `x` take the
  ticket off the rail, `b` shows a brief, `e` on a project opens a scratch
  roadmap in `$EDITOR`, and the session view gets the fixture transcript.
  """

  alias Sprat.Terminal.BoardApp
  alias Sprat.Terminal.Board.Fixture

  @brief """
  brief · mon 23 nov · 9 projects · 4 items done yesterday · 6 nudges, 5 resolved

  cupful: C 3/9; cafe-networks-4b waiting on you 18m (network_id column)
  liftlog-ios: B 5/10; signing cert missing, sprat moved the agent to B.5; you: import the cert
  liftlog: A 7/10, merch checkout done yesterday, on course
  dreamboard: stalled 2 days at 2.3 (onboarding copy); resume prompt ready
  fieldnotes: done 9 days ago; archive or add a roadmap

  net: 2 decisions for you, 1 resume, 5 moving
  """

  def run(opts \\ []) do
    {:ok, gone} = Agent.start_link(fn -> MapSet.new() end)
    offset = local_offset()

    snapshot_fun = fn ->
      removed = Agent.get(gone, & &1)
      snap = Fixture.snapshot(DateTime.utc_now())

      %{snap | tickets: Enum.reject(snap.tickets, &MapSet.member?(removed, &1.id))}
      |> Map.put(:utc_offset, offset)
      |> Map.delete(:session_lines)
    end

    command_fun = fn command ->
      case command do
        {:fire, id, _text} ->
          Agent.update(gone, &MapSet.put(&1, id))
          {:ok, {:message, "demo: fired #{id}"}}

        {:dismiss, id, reason} ->
          Agent.update(gone, &MapSet.put(&1, id))
          {:ok, {:message, "demo: dismissed #{id} #{inspect(reason)}"}}

        {:brief, _} ->
          {:ok, {:brief, String.trim(@brief)}}

        {:session_lines, sid} ->
          {:ok,
           {:session_lines, Map.get(Fixture.snapshot(DateTime.utc_now()).session_lines, sid, [])}}

        {:edit_roadmap, root} ->
          path = Path.join(System.tmp_dir!(), "sprat-demo-roadmap.md")

          File.write!(
            path,
            "# Roadmap: #{Path.basename(root)}\n\n## C · Cafe networks  [active]\n"
          )

          {:ok, {:edit, path}}

        other ->
          {:ok, {:message, "demo: " <> inspect(other, limit: 4, printable_limit: 60)}}
      end
    end

    BoardApp.run(Keyword.merge([snapshot_fun: snapshot_fun, command_fun: command_fun], opts))
  end

  defp local_offset do
    utc = :calendar.universal_time()
    local = :calendar.universal_time_to_local_time(utc)
    :calendar.datetime_to_gregorian_seconds(local) - :calendar.datetime_to_gregorian_seconds(utc)
  end
end
