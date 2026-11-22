defmodule Sprat.Observer.Sessions do
  @moduledoc """
  Scans the Claude session registry every 2 seconds in its own process
  (`ps` for liveness and accounts, `git` for new project roots), keeps one
  `Sprat.Observer.SessionServer` per session, and publishes the sessions and
  live pids to `Sprat.Observer.Live` (`:sessions`). Says on the activity
  stream when a session starts or ends.
  """

  use GenServer
  require Logger

  alias Sprat.Observer.{Accounts, Cmux, ConfigDirs, Live, Registry, SessionScan, SessionServer}

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "The sessions last published (sid => session), or nil before the first scan."
  def latest, do: Live.get(:sessions, :sessions)

  @impl true
  def init(opts) do
    send(self(), :scan)
    {:ok, %{opts: opts, sessions: Live.get(:sessions, :sessions) || %{}, cache: %{}}}
  end

  @impl true
  def handle_info(:scan, state) do
    Process.send_after(self(), :scan, Keyword.get(state.opts, :sessions_ms, 2_000))

    dirs =
      Keyword.get_lazy(state.opts, :config_dirs, fn ->
        (Accounts.latest() || %{config_dirs: ConfigDirs.list()}).config_dirs
      end)

    surfaces =
      case Cmux.latest() do
        {surfaces, _status} -> surfaces
        nil -> %{}
      end

    registry = Keyword.get(state.opts, :registry_fun, &Registry.scan/1)

    {sessions, cache} =
      SessionScan.scan(registry.(dirs), state.sessions, state.cache, surfaces, state.opts)

    # cmux may have mapped a pid since the session was first seen.
    sessions =
      Map.new(sessions, fn {sid, s} ->
        {sid, %{s | surface: Map.get(surfaces, s.pid) || s.surface}}
      end)

    # New sessions get a process; a known one is told only what changed.
    Enum.each(sessions, fn {sid, s} ->
      was = Map.get(state.sessions, sid)

      changed? =
        is_nil(was) or was.transcript_path != s.transcript_path or was.live? != s.live? or
          not SessionServer.running?(sid)

      if s.transcript_path && changed?,
        do: SessionServer.ensure(sid, s.transcript_path, s.live?, state.opts)
    end)

    Live.put(:sessions, :sessions, sessions)

    Live.put(
      :sessions,
      :pids,
      for({_, %{live?: true, pid: pid}} <- sessions, is_integer(pid), do: pid)
    )

    announce(state.sessions, sessions)
    {:noreply, %{state | sessions: sessions, cache: cache}}
  rescue
    e ->
      Logger.error("sprat sessions: " <> Exception.format(:error, e, __STACKTRACE__))
      {:noreply, state}
  end

  # A session that went live or ended since the last scan (not on the first
  # scan, which would announce every session on the machine).
  defp announce(before, _now) when map_size(before) == 0, do: :ok

  defp announce(before, now) do
    for {sid, s} <- now do
      was = Map.get(before, sid)

      cond do
        s.live? and (is_nil(was) or not was.live?) ->
          Sprat.Activity.emit(:session,
            project_root: s.project_root,
            text:
              "session #{s.name || String.slice(sid, 0, 8)} started (#{Path.basename(s.config_dir || "")})",
            status: :info
          )

        (not s.live? and was) && was.live? ->
          Sprat.Activity.emit(:session,
            project_root: s.project_root,
            text: "session #{s.name || String.slice(sid, 0, 8)} ended",
            status: :info
          )

        true ->
          :ok
      end
    end

    :ok
  end
end
