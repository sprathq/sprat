defmodule Sprat.Observer.Surfaces do
  @moduledoc """
  Maps Claude session pids to the cmux surface they run in (`00-spikes.md` §2),
  from `cmux top --all --processes --format tsv`.

  Rows are `cpu mem count type id parent name`. For `process` rows, `id` is the
  pid and `parent` is a `surface:N`, a parent pid, or some other ref (a
  workspace tag). The same pid can appear under several parents (a tag row and
  a surface row); any path that reaches a surface wins.
  """

  @app_bin "/Applications/cmux.app/Contents/Resources/bin/cmux"

  @doc "Parses the TSV into `%{pid => \"surface:N\"}`."
  @spec parse_cmux_top(String.t()) :: %{integer() => String.t()}
  def parse_cmux_top(tsv) when is_binary(tsv) do
    parents =
      tsv
      |> String.split("\n", trim: true)
      |> Enum.reduce(%{}, fn line, acc ->
        case String.split(line, "\t") do
          [_cpu, _mem, _count, "process", id, parent | _] ->
            case Integer.parse(id) do
              {pid, ""} -> Map.update(acc, pid, [parent], &[parent | &1])
              _ -> acc
            end

          _ ->
            acc
        end
      end)
      |> Map.new(fn {pid, ps} -> {pid, Enum.reverse(ps)} end)

    parents
    |> Map.keys()
    |> Enum.reduce(%{}, fn pid, acc ->
      case surface_of(pid, parents, MapSet.new()) do
        nil -> acc
        s -> Map.put(acc, pid, s)
      end
    end)
  end

  defp surface_of(pid, parents, seen) do
    if MapSet.member?(seen, pid) do
      nil
    else
      ps = Map.get(parents, pid, [])

      Enum.find(ps, &String.starts_with?(&1, "surface:")) ||
        Enum.find_value(ps, fn p ->
          case Integer.parse(p) do
            {ppid, ""} -> surface_of(ppid, parents, MapSet.put(seen, pid))
            _ -> nil
          end
        end)
    end
  end

  @doc """
  The workspace a surface is in, from `cmux top --all --format tsv` (rows
  `surface:N → pane:M → workspace:K`). Nil when unknown.
  """
  @spec workspace_of(String.t(), String.t()) :: String.t() | nil
  def workspace_of(tsv, surface) when is_binary(tsv) do
    parent =
      tsv
      |> String.split("\n", trim: true)
      |> Enum.reduce(%{}, fn line, acc ->
        case String.split(line, "\t") do
          [_cpu, _mem, _count, type, id, parent | _] when type in ["surface", "pane"] ->
            Map.put(acc, id, parent)

          _ ->
            acc
        end
      end)

    with "pane:" <> _ = pane <- Map.get(parent, surface),
         "workspace:" <> _ = ws <- Map.get(parent, pane) do
      ws
    else
      _ -> nil
    end
  end

  @doc """
  Brings a surface to the front and gives it keyboard focus: selects its
  workspace, then focuses the surface in it. `:ok`, or `{:error, reason}`.

  Options: `:bin`, `:runner` as in `scan/1`.
  """
  @spec focus(String.t(), keyword()) :: :ok | {:error, term()}
  def focus(surface, opts \\ []) do
    bin = Keyword.get_lazy(opts, :bin, &cmux_bin/0)
    runner = Keyword.get(opts, :runner, &default_runner/2)

    with bin when is_binary(bin) <- bin || {:error, :no_cmux},
         {tsv, 0} <- safe_run(runner, bin, ["top", "--all", "--format", "tsv"]),
         ws when is_binary(ws) <- workspace_of(tsv, surface) || {:error, :surface_not_found},
         {_, 0} <- safe_run(runner, bin, ["select-workspace", "--workspace", ws]),
         {_, 0} <- safe_run(runner, bin, ["focus-panel", "--panel", surface, "--workspace", ws]) do
      :ok
    else
      {:error, _} = e -> e
      {out, _code} -> {:error, String.trim(out)}
    end
  end

  @doc "The cmux binary: `CMUX_BIN`, the app bundle's, or `cmux` on PATH; nil if none."
  @spec cmux_bin() :: String.t() | nil
  def cmux_bin do
    case System.get_env("CMUX_BIN") do
      bin when is_binary(bin) and bin != "" -> bin
      _ -> if executable?(@app_bin), do: @app_bin, else: System.find_executable("cmux")
    end
  end

  defp executable?(path) do
    case File.stat(path) do
      {:ok, %File.Stat{type: :regular, mode: mode}} -> Bitwise.band(mode, 0o111) != 0
      _ -> false
    end
  end

  @doc """
  Runs `cmux top` and parses it: `{:ok, %{pid => surface}}`, or
  `{:error, :no_cmux | :denied | :failed}`.

  cmux only lets processes it started talk to its socket. `sprat serve`
  under launchd is not one of them, so on "Access denied" Sprat borrows the
  socket capability cmux handed one of its own processes (a live Claude
  session, from `:pids`) and retries once. The capability then stays in
  Sprat's environment, so delivery and `trigger-flash` use it too.

  Options: `:bin` (defaults to `cmux_bin/0`), `:runner` —
  `(bin, args) -> {output, exit_status}`, `:pids` (candidates to borrow
  from), `:env_of` — `pid -> environment text` (default `ps -E`).
  """
  @spec scan(keyword()) ::
          {:ok, %{integer() => String.t()}} | {:error, :no_cmux | :denied | :failed}
  def scan(opts \\ []) do
    bin = Keyword.get_lazy(opts, :bin, &cmux_bin/0)
    runner = Keyword.get(opts, :runner, &default_runner/2)
    args = ["top", "--all", "--processes", "--format", "tsv"]

    if is_binary(bin) do
      case safe_run(runner, bin, args) do
        {out, 0} ->
          {:ok, parse_cmux_top(out)}

        {out, _} ->
          if denied?(out) and borrow_access(opts) == :ok do
            case safe_run(runner, bin, args) do
              {out2, 0} -> {:ok, parse_cmux_top(out2)}
              {out2, _} -> {:error, if(denied?(out2), do: :denied, else: :failed)}
            end
          else
            {:error, if(denied?(out), do: :denied, else: :failed)}
          end
      end
    else
      {:error, :no_cmux}
    end
  end

  @doc "`scan/1` without the reason: `%{}` when cmux is absent or fails."
  @spec map(keyword()) :: %{integer() => String.t()}
  def map(opts \\ []) do
    case scan(opts) do
      {:ok, m} -> m
      _ -> %{}
    end
  end

  @doc """
  Copies `CMUX_SOCKET_CAPABILITY` (and `CMUX_SOCKET_PATH`) from the first of
  `opts[:pids]` that carries them into this VM's environment. `:ok` when one
  was found.
  """
  @spec borrow_access(keyword()) :: :ok | :error
  def borrow_access(opts) do
    env_of = Keyword.get(opts, :env_of, &env_of/1)

    opts
    |> Keyword.get(:pids, [])
    |> Enum.find_value(:error, fn pid ->
      env = env_of.(pid) || ""

      case last_var(env, "CMUX_SOCKET_CAPABILITY") do
        nil ->
          nil

        cap ->
          put_env = Keyword.get(opts, :put_env, &System.put_env/2)
          put_env.("CMUX_SOCKET_CAPABILITY", cap)
          if path = last_var(env, "CMUX_SOCKET_PATH"), do: put_env.("CMUX_SOCKET_PATH", path)
          :ok
      end
    end)
  end

  defp denied?(out), do: String.contains?(out, "Access denied")

  defp safe_run(runner, bin, args) do
    runner.(bin, args)
  rescue
    e -> {Exception.message(e), 1}
  end

  # `ps -E` appends the environment to the command line; the last
  # occurrence is the real variable.
  defp last_var(text, name) do
    case Regex.scan(~r/(?:^|\s)#{name}=(\S+)/, text) do
      [] -> nil
      matches -> matches |> List.last() |> List.last()
    end
  end

  defp env_of(pid) do
    case Sprat.Cmd.run("ps", ["-E", "-o", "command=", "-p", Integer.to_string(pid)],
           timeout: 5_000
         ) do
      {out, 0} -> out
      _ -> nil
    end
  end

  defp default_runner(bin, args), do: Sprat.Cmd.run(bin, args, timeout: 5_000)
end
