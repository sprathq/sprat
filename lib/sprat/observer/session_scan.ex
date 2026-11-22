defmodule Sprat.Observer.SessionScan do
  @moduledoc """
  Turns what the session registry found into the sessions Sprat knows: one
  entry per session id (a `claude` and its `!` shell share one), its project
  root and branch, its transcript, the account it runs under, its cmux
  surface. Sessions that left the registry stay known, as ended.

  Pure over its inputs (and the `git` calls of project resolution, cached):
  the engine runs it inline, `Sprat.Observer.Sessions` on its own timer.
  """

  alias Sprat.Observer.{Projects, Transcript}

  @doc """
  `found`: what `Sprat.Observer.Registry.scan/1` returned. `prev`: the
  sessions known so far (sid => session). `cache`: the project-resolution
  cache. `surfaces`: pid => cmux surface. Returns `{sessions, cache}`.
  """
  def scan(found, prev, cache, surfaces, opts \\ []) do
    {sessions, cache} =
      Enum.reduce(dedupe(found), {%{}, cache}, fn s, {acc, cache} ->
        {res, cache} =
          if s.cwd,
            do: Projects.resolve_cached(cache, s.cwd, Keyword.take(opts, [:cmd])),
            else: {%{root: nil, branch: nil, worktree?: false}, cache}

        transcript = s.transcript_path || Transcript.locate(s.config_dir, s.session_id)

        # Once a session ends its pid can't say which account it ran under;
        # keep the one seen while it was live.
        before = Map.get(prev, s.session_id)
        account = if not s.live? and before, do: before.config_dir, else: s.config_dir

        s = %{
          s
          | config_dir: account,
            project_root: res.root,
            branch: res.branch || s.branch,
            worktree?: res.worktree?,
            transcript_path: transcript,
            surface: s.surface || Map.get(surfaces, s.pid),
            last_activity_at: s.last_activity_at || (before && before.last_activity_at)
        }

        {Map.put(acc, s.session_id, s), cache}
      end)

    gone =
      prev
      |> Enum.reject(fn {sid, _} -> Map.has_key?(sessions, sid) end)
      |> Map.new(fn {sid, s} -> {sid, %{s | live?: false, status: :ended}} end)

    {Map.merge(gone, sessions), cache}
  end

  # One session id can show up twice (a `claude` and its `!` shell). Prefer
  # the live, non-shell entry.
  defp dedupe(sessions) do
    sessions
    |> Enum.group_by(& &1.session_id)
    |> Enum.map(fn {_sid, list} ->
      Enum.max_by(
        list,
        fn s ->
          {s.live? && 1, s.status not in [:shell, :ended] && 1,
           s.status_since || ~U[1970-01-01 00:00:00Z]}
        end,
        fn a, b -> a >= b end
      )
    end)
  end
end
