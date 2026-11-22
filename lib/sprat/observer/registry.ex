defmodule Sprat.Observer.Registry do
  @moduledoc """
  Reads Claude Code's session registry (spec §4.1): one
  `<config>/sessions/<pid>.json` per session process.

  `scan/2` is a single pass: read every file, then check every pid with one
  `ps` call. A pid that is not alive gives `live?: false, status: :ended`.
  Unparsable files are skipped.
  """

  alias Sprat.Observer.{ConfigDirs, Transcript}
  alias Sprat.Observer.Model.Session

  @doc """
  Scans the given config dirs.

  Options: `:alive_fun` — `([pid] -> MapSet.t(pid) | [pid])`, the pids alive
  among those given (defaults to one `ps -p … -o pid=` call); `:account_fun`
  — `([pid] -> %{pid => config_dir})`, the config dir each live pid really
  runs under (defaults to `ConfigDirs.of_pids/1`).

  Several accounts can share one `sessions/` folder through symlinks
  (`~/.claude-work/sessions -> ~/.claude/sessions`), so the folder a file was
  found in does not say whose session it is. A live session takes the
  account its process runs under; its transcript is still looked up where
  the file was found.
  """
  @spec scan([String.t()], keyword()) :: [Session.t()]
  def scan(config_dirs, opts \\ []) do
    alive_fun = Keyword.get(opts, :alive_fun, &alive_pids/1)

    sessions =
      for dir <- config_dirs,
          file <- dir |> Path.join("sessions/*.json") |> Path.wildcard() |> Enum.sort(),
          session = read_file(dir, file),
          session != nil,
          do: session

    pids = sessions |> Enum.map(& &1.pid) |> Enum.filter(&is_integer/1) |> Enum.uniq()
    alive = if pids == [], do: MapSet.new(), else: MapSet.new(alive_fun.(pids))

    live_pids = Enum.filter(pids, &MapSet.member?(alive, &1))
    accounts = if live_pids == [], do: %{}, else: account_fun(opts).(live_pids)

    Enum.map(sessions, fn s ->
      if MapSet.member?(alive, s.pid),
        do: attribute(%{s | live?: true}, Map.get(accounts, s.pid)),
        else: %{s | live?: false, status: :ended}
    end)
  end

  defp account_fun(opts), do: Keyword.get(opts, :account_fun, &ConfigDirs.of_pids/1)

  defp attribute(s, nil), do: s
  defp attribute(%{config_dir: dir} = s, dir), do: s

  defp attribute(s, account) do
    %{
      s
      | config_dir: account,
        transcript_path: s.transcript_path || Transcript.locate(s.config_dir, s.session_id)
    }
  end

  @doc "Parses one registry JSON document into a session (not yet liveness-checked)."
  @spec parse(String.t(), binary()) :: {:ok, Session.t()} | :error
  def parse(config_dir, json) do
    with {:ok, %{"sessionId" => sid} = m} when is_binary(sid) <- safe_decode(json) do
      {:ok,
       %Session{
         session_id: sid,
         config_dir: config_dir,
         pid: int(m["pid"]),
         status: status(m["status"]),
         status_since: ms(m["statusUpdatedAt"] || m["updatedAt"]),
         cwd: str(m["cwd"]),
         name: str(m["name"]),
         version: str(m["version"]),
         started_at: ms(m["startedAt"]),
         tmux: m["tmux"]
       }}
    else
      _ -> :error
    end
  end

  defp read_file(dir, file) do
    with {:ok, bin} <- File.read(file), {:ok, s} <- parse(dir, bin), do: s, else: (_ -> nil)
  end

  defp safe_decode(bin) do
    case JSON.decode(bin) do
      {:ok, m} when is_map(m) -> {:ok, m}
      _ -> :error
    end
  rescue
    _ -> :error
  end

  defp status("busy"), do: :busy
  defp status("idle"), do: :idle
  defp status("shell"), do: :shell
  defp status(_), do: :unknown

  defp int(n) when is_integer(n), do: n

  defp int(s) when is_binary(s) do
    case Integer.parse(s) do
      {n, ""} -> n
      _ -> nil
    end
  end

  defp int(_), do: nil

  defp str(s) when is_binary(s), do: s
  defp str(_), do: nil

  defp ms(n) when is_integer(n), do: DateTime.from_unix!(n, :millisecond)
  defp ms(_), do: nil

  # One `ps` call. If ps rejects an argument outright (a pid out of range
  # makes macOS ps print nothing else), check the pids one by one instead.
  defp alive_pids(pids) do
    case ps(pids) do
      {alive, true} -> alive
      {alive, false} when length(pids) == 1 -> alive
      {_, false} -> Enum.flat_map(pids, &(&1 |> List.wrap() |> ps() |> elem(0)))
    end
  end

  defp ps(pids) do
    {out, _status} =
      Sprat.Cmd.run("ps", ["-p", Enum.join(pids, ","), "-o", "pid="], timeout: 5_000)

    lines = String.split(out, "\n", trim: true)

    alive =
      Enum.flat_map(lines, fn l ->
        case Integer.parse(String.trim(l)) do
          {n, ""} -> [n]
          _ -> []
        end
      end)

    {alive, not Enum.any?(lines, &String.starts_with?(&1, "ps:"))}
  rescue
    _ -> {[], true}
  end
end
