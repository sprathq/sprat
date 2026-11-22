defmodule Sprat.Verify.Attach do
  @moduledoc """
  `sprat attach [path]` and `sprat detach [path]` (spec-v4 §9 "Verify
  (opt-in)"): install or remove the Stop hook in the project's
  `.claude/settings.json` — never the user-level file, never silently.

  Attach shows the exact JSON it will merge and asks first (`--yes` skips
  the question). The merge keeps every other key and hook, keeps key order,
  and is idempotent: a second attach changes nothing. It also writes
  `.sprat/checks` (a commented template plus a detected default) when the
  project has none. Detach removes exactly Sprat's hook and nothing else;
  `.sprat/checks` stays, since the PM's `run_check` reads it too.

  JSON objects are handled as `{:obj, [{key, value}]}` so the owner's
  settings keep their key order when written back.
  """

  # What identifies Sprat's hook in a settings file, wherever the release
  # lives: detach and re-attach match on this, not on the full path.
  @marker ~s|Sprat.Verify.CLI.main(["stop"])|
  @hook_timeout 600
  @source_root Path.expand("../../..", __DIR__)

  # ── the hook command ────────────────────────────────────────────────────

  @doc """
  The absolute command Claude Code runs on Stop: the release's `sprat_rt
  eval` when running from a release (`RELEASE_ROOT`), else `mix run` in this
  source checkout.
  """
  def hook_command do
    case System.get_env("RELEASE_ROOT") do
      root when is_binary(root) and root != "" ->
        "#{sh_quote(Path.join([root, "bin", "sprat_rt"]))} eval #{sh_quote(@marker)}"

      _ ->
        mix = System.find_executable("mix") || "mix"

        "cd #{sh_quote(@source_root)} && MIX_ENV=dev #{sh_quote(mix)} run --no-start --no-compile -e #{sh_quote(@marker)}"
    end
  end

  defp sh_quote(s), do: "'" <> String.replace(s, "'", ~S('"'"')) <> "'"

  @doc "The Stop entry Sprat merges, as an ordered JSON object."
  def hook_entry(command) do
    {:obj,
     [
       {"hooks",
        [
          {:obj,
           [
             {"type", "command"},
             {"command", command},
             {"timeout", @hook_timeout},
             {"statusMessage", "Sprat: running the project's checks"}
           ]}
        ]}
     ]}
  end

  # ── merge / unmerge (pure) ──────────────────────────────────────────────

  @doc "Settings with Sprat's Stop hook in place (replacing an older Sprat hook)."
  def merge({:obj, _} = settings, command) do
    hooks = get(settings, "hooks", {:obj, []})
    stop = hooks |> get("Stop", []) |> List.wrap()

    stop =
      if Enum.any?(stop, &ours?/1) do
        Enum.map(stop, fn entry ->
          if ours?(entry), do: replace_our_hook(entry, command), else: entry
        end)
      else
        stop ++ [hook_entry(command)]
      end

    put(settings, "hooks", put(hooks, "Stop", stop))
  end

  @doc "Settings without Sprat's Stop hook; everything else untouched."
  def unmerge({:obj, _} = settings) do
    case get(settings, "hooks", nil) do
      {:obj, _} = hooks ->
        stop =
          hooks
          |> get("Stop", [])
          |> List.wrap()
          |> Enum.flat_map(fn entry ->
            if ours?(entry) do
              case Enum.reject(get(entry, "hooks", []), &our_hook?/1) do
                [] -> []
                rest -> [put(entry, "hooks", rest)]
              end
            else
              [entry]
            end
          end)

        hooks = if stop == [], do: delete(hooks, "Stop"), else: put(hooks, "Stop", stop)

        case hooks do
          {:obj, []} -> delete(settings, "hooks")
          _ -> put(settings, "hooks", hooks)
        end

      _ ->
        settings
    end
  end

  defp ours?({:obj, _} = entry),
    do: entry |> get("hooks", []) |> List.wrap() |> Enum.any?(&our_hook?/1)

  defp ours?(_), do: false

  defp our_hook?({:obj, _} = h),
    do: is_binary(get(h, "command", nil)) and String.contains?(get(h, "command", ""), @marker)

  defp our_hook?(_), do: false

  defp replace_our_hook(entry, command) do
    hooks =
      Enum.map(get(entry, "hooks", []), fn h ->
        if our_hook?(h), do: put(h, "command", command), else: h
      end)

    put(entry, "hooks", hooks)
  end

  defp get({:obj, kvs}, key, default) do
    case List.keyfind(kvs, key, 0) do
      {_, v} -> v
      nil -> default
    end
  end

  defp put({:obj, kvs}, key, value) do
    if List.keymember?(kvs, key, 0),
      do: {:obj, List.keyreplace(kvs, key, 0, {key, value})},
      else: {:obj, kvs ++ [{key, value}]}
  end

  defp delete({:obj, kvs}, key), do: {:obj, List.keydelete(kvs, key, 0)}

  # ── JSON with key order ─────────────────────────────────────────────────

  @doc "Decodes JSON keeping object key order (`{:obj, kvs}`)."
  def decode(text) do
    case JSON.decode(text, [],
           object_push: fn k, v, acc -> [{k, v} | acc] end,
           object_finish: fn acc, old -> {{:obj, Enum.reverse(acc)}, old} end
         ) do
      {value, _acc, rest} ->
        if String.trim(rest) == "", do: {:ok, value}, else: {:error, :trailing}

      {:error, _} = e ->
        e
    end
  rescue
    _ -> {:error, :invalid}
  end

  @doc "Encodes `{:obj, kvs}` trees as indented JSON (2 spaces), with a final newline."
  def encode(value), do: IO.iodata_to_binary([enc(value, 0), "\n"])

  defp enc({:obj, []}, _), do: "{}"

  defp enc({:obj, kvs}, d) do
    pad = String.duplicate("  ", d + 1)

    inner =
      Enum.map_intersperse(kvs, ",\n", fn {k, v} ->
        [pad, JSON.encode!(k), ": ", enc(v, d + 1)]
      end)

    ["{\n", inner, "\n", String.duplicate("  ", d), "}"]
  end

  defp enc([], _), do: "[]"

  defp enc(list, d) when is_list(list) do
    pad = String.duplicate("  ", d + 1)
    inner = Enum.map_intersperse(list, ",\n", &[pad, enc(&1, d + 1)])
    ["[\n", inner, "\n", String.duplicate("  ", d), "]"]
  end

  defp enc(nil, _), do: "null"
  defp enc(v, _), do: JSON.encode!(v)

  # ── default checks ──────────────────────────────────────────────────────

  @doc "The test command this project most likely uses, or nil."
  def detect_default(dir) do
    has = &File.exists?(Path.join(dir, &1))

    cond do
      has.("mix.exs") -> "mix test"
      npm_test?(dir) -> "npm test"
      has.("pubspec.yaml") -> "flutter test"
      has.("Cargo.toml") -> "cargo test"
      has.("go.mod") -> "go test ./..."
      pytest?(dir) -> "pytest"
      true -> nil
    end
  end

  defp npm_test?(dir) do
    with {:ok, text} <- File.read(Path.join(dir, "package.json")),
         {:ok, %{"scripts" => %{"test" => test}}} when is_binary(test) <- JSON.decode(text) do
      not String.contains?(test, "no test specified")
    else
      _ -> false
    end
  end

  defp pytest?(dir) do
    File.exists?(Path.join(dir, "pytest.ini")) or File.exists?(Path.join(dir, "conftest.py")) or
      file_has?(Path.join(dir, "pyproject.toml"), "[tool.pytest") or
      file_has?(Path.join(dir, "setup.cfg"), "[tool:pytest]") or
      file_has?(Path.join(dir, "tox.ini"), "[pytest]")
  end

  defp file_has?(path, needle) do
    case File.read(path) do
      {:ok, text} -> String.contains?(text, needle)
      _ -> false
    end
  end

  @doc "The `.sprat/checks` Sprat writes when a project has none."
  def checks_template(default) do
    """
    # Sprat Verify: the checks Sprat runs when a Claude Code session here tries to stop.
    # One command per line, run in the session's checkout without a shell
    # (no pipes, &&, redirects or env assignments). Lines starting with # are comments.
    # If any check fails, Sprat refuses the stop and tells Claude which check failed,
    # its exit code and the first failing lines. At most 4 refusals in a row, then it
    # lets the session stop and puts it on your board.
    # The PM's run_check may also run these commands.
    # Remove every command line to switch Verify off without detaching.
    """ <>
      case default do
        nil -> "# No test command detected. Add one, e.g.:\n# mix test\n"
        cmd -> cmd <> "\n"
      end
  end

  # ── commands ────────────────────────────────────────────────────────────

  @doc """
  `sprat attach [path] [--yes]`. Options: `:yes` (skip the question),
  `:gets` (`fn prompt -> line end`, default `IO.gets/1`), `:puts`, `:command`
  (the hook command, default `hook_command/0`). Returns `:attached`,
  `:unchanged`, `:aborted` or `{:error, why}`.
  """
  def attach(path, opts \\ []) do
    puts = Keyword.get(opts, :puts, &IO.puts/1)
    gets = Keyword.get(opts, :gets, &IO.gets/1)
    dir = Path.expand(path)
    settings_path = Path.join([dir, ".claude", "settings.json"])
    command = Keyword.get_lazy(opts, :command, fn -> hook_command() end)
    checks_path = Sprat.Verify.checks_path(dir)

    with true <- File.dir?(dir) || {:error, "No such directory: #{dir}"},
         {:ok, current} <- read_settings(settings_path) do
      merged = merge(current, command)
      settings_change? = merged != current

      checks_text =
        if File.exists?(checks_path), do: nil, else: checks_template(detect_default(dir))

      cond do
        not settings_change? and checks_text == nil ->
          puts.(
            "Already attached: #{settings_path} has Sprat's Stop hook and #{checks_path} exists."
          )

          :unchanged

        true ->
          if settings_change? do
            puts.("Sprat will merge this Stop hook into #{settings_path}:\n")
            puts.(encode({:obj, [{"hooks", {:obj, [{"Stop", [hook_entry(command)]}]}}]}))

            puts.(
              "Everything else in that file stays as it is. `sprat detach` removes exactly this.\n"
            )
          end

          if checks_text do
            puts.("And create #{checks_path}:\n")
            puts.(checks_text)
          end

          if Keyword.get(opts, :yes, false) or yes?(gets.("Attach? [y/N] ")) do
            if settings_change? do
              File.mkdir_p!(Path.dirname(settings_path))
              File.write!(settings_path, encode(merged))
            end

            if checks_text do
              File.mkdir_p!(Path.dirname(checks_path))
              File.write!(checks_path, checks_text)
            end

            puts.(
              "Attached. Verify runs on the next Stop in a session started (or resumed) here; " <>
                "edit #{checks_path} to change the checks."
            )

            :attached
          else
            puts.("Nothing written.")
            :aborted
          end
      end
    else
      {:error, why} ->
        puts.("Not attached: #{why}")
        {:error, why}
    end
  end

  @doc "`sprat detach [path]`: removes Sprat's Stop hook. Returns `:detached`, `:unchanged` or `{:error, why}`."
  def detach(path, opts \\ []) do
    puts = Keyword.get(opts, :puts, &IO.puts/1)
    dir = Path.expand(path)
    settings_path = Path.join([dir, ".claude", "settings.json"])

    case read_settings(settings_path) do
      {:ok, current} ->
        case unmerge(current) do
          ^current ->
            puts.("Not attached: #{settings_path} has no Sprat Stop hook.")
            :unchanged

          updated ->
            File.write!(settings_path, encode(updated))

            puts.(
              "Detached: removed Sprat's Stop hook from #{settings_path}. " <>
                "#{Sprat.Verify.checks_path(dir)} is left in place."
            )

            :detached
        end

      {:error, why} ->
        puts.("Not detached: #{why}")
        {:error, why}
    end
  end

  defp read_settings(path) do
    case File.read(path) do
      {:ok, text} ->
        case decode(text) do
          {:ok, {:obj, _} = obj} ->
            {:ok, obj}

          _ ->
            {:error,
             "#{path} is not a JSON object; fix it by hand first, Sprat will not overwrite it"}
        end

      {:error, :enoent} ->
        {:ok, {:obj, []}}

      {:error, why} ->
        {:error, "cannot read #{path}: #{:file.format_error(why)}"}
    end
  end

  defp yes?(line) when is_binary(line),
    do: String.trim(line) |> String.downcase() |> Kernel.in(["y", "yes"])

  defp yes?(_), do: false
end
