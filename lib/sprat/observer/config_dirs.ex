defmodule Sprat.Observer.ConfigDirs do
  @moduledoc """
  The Claude config directories on this machine (spec §4.1), from three
  sources:

    * `~/.claude` plus every `~/.claude-*` directory that has a `sessions/`
      or `projects/` subdir;
    * the `CLAUDE_CONFIG_DIR` of every running process (an account kept
      anywhere, e.g. `CLAUDE_CONFIG_DIR=~/work/claude claude`);
    * every directory found that way before, remembered in
      `<data>/v4/claude-dirs` so an account stays known after its last
      session exits.

  `SPRAT_CLAUDE_DIRS` (colon-separated) replaces the discovery entirely.

  Two directories whose `sessions/` or `projects/` resolve to the same place
  (one symlinked into the other) are the same account; only the first is kept,
  so a session is never seen twice.
  """

  @doc """
  Lists config dirs, absolute paths, `~/.claude` first.

  Options: `:home` (defaults to the user's home), `:env` (the
  `SPRAT_CLAUDE_DIRS` value; defaults to the real environment variable),
  `:processes` (the `CLAUDE_CONFIG_DIR` values of running processes;
  defaults to one `ps` call), `:memory` (the file remembering dirs found
  before, or nil for none; defaults to `<data>/v4/claude-dirs`).
  """
  @spec list(keyword()) :: [String.t()]
  def list(opts \\ []) do
    home = Keyword.get_lazy(opts, :home, &System.user_home!/0)
    env = Keyword.get_lazy(opts, :env, fn -> System.get_env("SPRAT_CLAUDE_DIRS") end)

    case override(env) do
      nil -> discover(home, opts)
      dirs -> dirs
    end
  end

  @doc """
  Every account dir, including ones `list/1` folds together because they
  share `sessions/` or `projects/` through a symlink: those are still
  separate logins (separate usage limits), so choosing an account to run on
  needs them all. Same options as `list/1`.
  """
  @spec accounts(keyword()) :: [String.t()]
  def accounts(opts \\ []) do
    home = Keyword.get_lazy(opts, :home, &System.user_home!/0)
    env = Keyword.get_lazy(opts, :env, fn -> System.get_env("SPRAT_CLAUDE_DIRS") end)

    case override(env) do
      nil -> candidates(home, opts)
      dirs -> dirs
    end
  end

  @doc """
  The Claude login a config dir uses now: `oauthAccount.accountUuid` from
  its `.claude.json` (for `~/.claude`, the one in the home dir, where Claude
  keeps it when `CLAUDE_CONFIG_DIR` is unset). Nil when unknown. One config
  dir can change login (`/login`); two can share one.
  """
  @spec login(String.t(), keyword()) :: String.t() | nil
  def login(dir, opts \\ []) do
    home = Keyword.get_lazy(opts, :home, &System.user_home!/0)

    file =
      if Path.expand(dir) == Path.join(home, ".claude"),
        do: Path.join(home, ".claude.json"),
        else: Path.join(dir, ".claude.json")

    with {:ok, bin} <- File.read(file),
         {:ok, %{"oauthAccount" => %{"accountUuid" => uuid}}} when is_binary(uuid) <-
           JSON.decode(bin) do
      uuid
    else
      _ -> nil
    end
  end

  @doc """
  The config dir each given pid runs under: its `CLAUDE_CONFIG_DIR`, or
  `~/.claude` when it has none. Pids that are gone or unreadable are left out.
  """
  @spec of_pids([integer()], keyword()) :: %{integer() => String.t()}
  def of_pids(pids, opts \\ [])
  def of_pids([], _opts), do: %{}

  def of_pids(pids, opts) do
    home = Keyword.get_lazy(opts, :home, &System.user_home!/0)
    default = Path.join(home, ".claude")

    ps(["-p", Enum.join(pids, ","), "-o", "pid=,command="])
    |> Enum.flat_map(fn line ->
      case Integer.parse(String.trim_leading(line)) do
        {pid, rest} -> [{pid, config_var(rest) || default}]
        :error -> []
      end
    end)
    |> Map.new()
  end

  @doc "The distinct `CLAUDE_CONFIG_DIR` values of every running process."
  @spec from_processes() :: [String.t()]
  def from_processes do
    ps(["-ax", "-o", "command="])
    |> Enum.map(&config_var/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  # `ps -E` appends each process's environment to its command line. The
  # environment comes last, so the last occurrence is the real variable.
  defp config_var(line) do
    case Regex.scan(~r/(?:^|\s)CLAUDE_CONFIG_DIR=(\S+)/, line) do
      [] -> nil
      matches -> matches |> List.last() |> List.last() |> Path.expand()
    end
  end

  defp ps(args) do
    case Sprat.Cmd.run("ps", ["-E" | args], timeout: 5_000) do
      {out, _} ->
        out |> String.split("\n", trim: true) |> Enum.reject(&String.starts_with?(&1, "ps:"))
    end
  rescue
    _ -> []
  end

  defp override(nil), do: nil

  defp override(env) do
    case env
         |> String.split(":", trim: true)
         |> Enum.map(&String.trim/1)
         |> Enum.reject(&(&1 == "")) do
      [] -> nil
      dirs -> dirs |> Enum.map(&Path.expand/1) |> Enum.filter(&File.dir?/1) |> Enum.uniq()
    end
  end

  defp discover(home, opts), do: dedupe(candidates(home, opts))

  defp candidates(home, opts) do
    main = Path.join(home, ".claude")
    memory = Keyword.get_lazy(opts, :memory, &default_memory/0)
    running = Keyword.get_lazy(opts, :processes, &from_processes/0)

    others =
      home
      |> Path.join(".claude-*")
      |> Path.wildcard(match_dot: true)
      |> Enum.filter(&File.dir?/1)
      |> Enum.filter(&account_dir?/1)
      |> Enum.sort()

    remembered = recall(memory)
    found = Enum.filter(Enum.uniq(running ++ remembered), &account_dir?/1)
    remember(memory, remembered, found)

    candidates = if File.dir?(main), do: [main | others], else: others
    Enum.uniq(candidates ++ Enum.sort(found -- candidates))
  end

  defp account_dir?(dir),
    do: File.dir?(Path.join(dir, "sessions")) or File.dir?(Path.join(dir, "projects"))

  defp default_memory, do: Path.join([Sprat.Store.Paths.data_dir(), "v4", "claude-dirs"])

  defp recall(nil), do: []

  defp recall(path) do
    case File.read(path) do
      {:ok, text} -> String.split(text, "\n", trim: true)
      _ -> []
    end
  end

  defp remember(nil, _before, _found), do: :ok

  defp remember(path, before, found) do
    all = Enum.sort(Enum.uniq(before ++ found))

    if all != Enum.sort(before) do
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, Enum.join(all, "\n") <> "\n")
    end

    :ok
  rescue
    _ -> :ok
  end

  defp dedupe(dirs) do
    {kept, _seen} =
      Enum.reduce(dirs, {[], MapSet.new()}, fn dir, {kept, seen} ->
        keys = identity(dir)

        if Enum.any?(keys, &MapSet.member?(seen, &1)) do
          {kept, seen}
        else
          {[dir | kept], Enum.reduce(keys, seen, &MapSet.put(&2, &1))}
        end
      end)

    Enum.reverse(kept)
  end

  # The resolved locations of a dir's sessions/ and projects/ subdirs.
  defp identity(dir) do
    for sub <- ["sessions", "projects"], path = Path.join(dir, sub), File.dir?(path) do
      resolve_link(path)
    end
  end

  defp resolve_link(path, depth \\ 0)
  defp resolve_link(path, depth) when depth > 8, do: path

  defp resolve_link(path, depth) do
    case :file.read_link(String.to_charlist(path)) do
      {:ok, target} -> resolve_link(Path.expand(to_string(target), Path.dirname(path)), depth + 1)
      {:error, _} -> path
    end
  end
end
