defmodule Sprat.Verify do
  @moduledoc """
  The opt-in Verify layer (spec-v4 §9 "Verify (opt-in)", §13 Phase D): the
  Stop decision from spec-v3 §6, scoped down to the project's own check
  commands.

  A project opts in by listing check commands in `.sprat/checks` (one per
  line, `#` comments). When a Claude Code session in that project tries to
  stop, `sprat hook stop` runs every check in the session's own checkout and
  `decide/2` either allows the stop or refuses it with a reason in the
  spec-v3 §13.9 shape: each failing check, its exit code, the first failing
  lines (at most 15 in all) and one next action.

  `decide/2` is pure. `run_checks/3` is the only part that runs anything;
  its runner is injectable for tests. The hook plumbing (stdin, state file,
  logging) is `Sprat.Verify.CLI`; installing the hook is `Sprat.Verify.Attach`.
  """

  @max_lines 15
  @default_check_timeout_ms 300_000
  # Below the hook's own 600 s timeout (`Sprat.Verify.Attach`), so Claude
  # Code never kills the hook half-way through and Sprat still answers.
  @default_budget_ms 540_000
  @tail_chars 8_000

  # Variables a release (or `mix`) sets for its own VM. A check such as
  # `mix test` started from inside the release must not inherit them, or it
  # would boot against the release's ERTS and libs instead of the project's.
  @release_env ~w(RELEASE_ROOT RELEASE_NAME RELEASE_VSN RELEASE_COMMAND RELEASE_NODE
                  RELEASE_COOKIE RELEASE_TMP RELEASE_SYS_CONFIG RELEASE_VM_ARGS
                  RELEASE_REMOTE_VM_ARGS RELEASE_DISTRIBUTION RELEASE_BOOT_SCRIPT
                  RELEASE_BOOT_SCRIPT_CLEAN RELEASE_MODE RELEASE_PROG BINDIR ROOTDIR
                  EMU PROGNAME ERL_LIBS ERL_CRASH_DUMP_SECONDS)

  @type result :: %{
          command: String.t(),
          exit: integer() | nil,
          status: :passed | :failed | :timed_out | :not_run | :error,
          tail: String.t()
        }

  @type ctx :: %{
          checks: [String.t()],
          results: [result()],
          blocks_so_far: non_neg_integer(),
          max_blocks: pos_integer(),
          changed_since_last_block?: boolean()
        }

  # ── checks file ─────────────────────────────────────────────────────────

  @doc "Path of a project's checks file."
  def checks_path(dir), do: Path.join([dir, ".sprat", "checks"])

  @doc "The check commands in `<dir>/.sprat/checks`; `[]` when there is no file."
  @spec load_checks(Path.t()) :: [String.t()]
  def load_checks(dir) do
    case File.read(checks_path(dir)) do
      {:ok, text} -> parse_checks(text)
      _ -> []
    end
  end

  @doc "One command per non-blank line; lines starting with `#` are comments."
  @spec parse_checks(String.t()) :: [String.t()]
  def parse_checks(text) do
    text
    |> String.split("\n")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == "" or String.starts_with?(&1, "#")))
  end

  # ── the decision ────────────────────────────────────────────────────────

  @doc """
  Why the stop is allowed before any check runs, or `nil` when the checks
  must run. Order (spec-v3 §6): no checks → Verify is off; a repeat stop on
  unchanged evidence → never block twice; the ceiling on blocked stops is
  spent → allow and escalate.
  """
  @spec allow_without_running(map(), map()) ::
          nil | :no_checks | :same_evidence | :max_blocks
  def allow_without_running(input, ctx) do
    cond do
      ctx.checks == [] -> :no_checks
      input["stop_hook_active"] == true and not ctx.changed_since_last_block? -> :same_evidence
      ctx.blocks_so_far >= ctx.max_blocks -> :max_blocks
      true -> nil
    end
  end

  @doc """
  The Stop decision: `:allow` or `{:block, reason}`.

  `input` is the hook's JSON (string keys). `ctx` carries the checks, their
  results, how many stops Sprat has already refused in a row, the ceiling,
  and whether the working tree changed since the last refusal.

  A check that could not start at all (`:error`, e.g. the command is not
  installed) is the owner's to fix in `.sprat/checks`, not the agent's, so it
  never causes a block on its own; it is reported in the reason and the log.
  """
  @spec decide(map(), ctx()) :: :allow | {:block, String.t()}
  def decide(input, ctx) do
    if allow_without_running(input, ctx) do
      :allow
    else
      failing = Enum.filter(ctx.results, &(&1.status in [:failed, :timed_out, :not_run]))

      case failing do
        [] -> :allow
        _ -> {:block, reason(ctx, failing)}
      end
    end
  end

  defp reason(ctx, failing) do
    total = length(ctx.results)
    n = length(failing)
    passed = Enum.filter(ctx.results, &(&1.status == :passed))
    broken = Enum.filter(ctx.results, &(&1.status == :error))
    per_check = max(1, div(@max_lines, n))

    {blocks, _left} =
      Enum.map_reduce(failing, @max_lines, fn r, left ->
        take = min(per_check, left)
        lines = failing_lines(r.tail, take)
        {failure_block(r, lines), left - length(lines)}
      end)

    header =
      "Sprat: not done yet — #{n} of #{total} #{plural(total, "check")} failed " <>
        "(blocked stop #{ctx.blocks_so_far + 1} of #{ctx.max_blocks})."

    next =
      case failing do
        [one] ->
          "Next: make `#{one.command}` pass — start with the first failure above — then stop again. Sprat re-runs the checks itself."

        [first | _] ->
          "Next: fix `#{first.command}` first — start with the first failure above — then stop again. Sprat re-runs every check itself."
      end

    passed_line =
      case passed do
        [] ->
          []

        ps ->
          [
            "Passed on this run: " <>
              Enum.map_join(ps, ", ", &"`#{&1.command}` (exit 0)") <>
              ". Do not re-run them to prove it; Sprat already did."
          ]
      end

    broken_line =
      case broken do
        [] ->
          []

        bs ->
          [
            "Could not run (the owner's to fix in .sprat/checks, not yours): " <>
              Enum.map_join(bs, ", ", &"`#{&1.command}`") <> "."
          ]
      end

    Enum.join([header, "" | blocks] ++ [next, "" | passed_line ++ broken_line], "\n")
    |> String.trim_trailing()
  end

  defp failure_block(r, lines) do
    status =
      case r.status do
        :failed -> "FAILED (exit #{r.exit})"
        :timed_out -> "TIMED OUT (#{String.trim(r.tail)})"
        :not_run -> "NOT RUN (#{String.trim(r.tail)})"
      end

    quoted = if r.status == :failed, do: Enum.map(lines, &("   " <> &1)), else: []
    Enum.join(["`#{r.command}`: #{status}" | quoted], "\n") <> "\n"
  end

  @fail_re ~r/(error|fail|failure|assert|expected|panic|exception|traceback|\*\* \(|✗|×|not ok)/i

  @doc false
  # The first lines of `output` that look like a failure, else its last lines.
  def failing_lines(output, max) do
    lines =
      output
      |> String.replace(~r/\e\[[0-9;?]*[A-Za-z]/, "")
      |> String.split("\n")
      |> Enum.map(&String.trim_trailing/1)
      |> Enum.reject(&(String.trim(&1) == ""))
      |> Enum.map(&truncate(&1, 200))

    case Enum.filter(lines, &Regex.match?(@fail_re, &1)) do
      [] -> Enum.take(lines, -max)
      hits -> Enum.take(hits, max)
    end
  end

  defp truncate(s, max),
    do: if(String.length(s) > max, do: String.slice(s, 0, max) <> "…", else: s)

  defp plural(1, word), do: word
  defp plural(_, word), do: word <> "s"

  # ── running checks ──────────────────────────────────────────────────────

  @doc """
  Runs each check in `dir` (the session's own checkout: Stop fires after the
  agent's turn, so nothing is editing it), one after another, without a
  shell (`OptionParser.split/1`, then the executable directly).

  Options: `:timeout_ms` per check (default 300 s), `:budget_ms` for all of
  them (default 540 s, below the hook's 600 s timeout; checks the budget
  cannot reach are `:not_run`), and `:runner` —
  `fn argv, dir, timeout_ms -> {output, exit_status | :timeout | {:error, why}} end`
  — for tests.
  """
  @spec run_checks(Path.t(), [String.t()], keyword()) :: [result()]
  def run_checks(dir, checks, opts \\ []) do
    timeout = Keyword.get(opts, :timeout_ms, @default_check_timeout_ms)
    budget = Keyword.get(opts, :budget_ms, @default_budget_ms)
    runner = Keyword.get(opts, :runner, &run_port/3)
    started = System.monotonic_time(:millisecond)

    Enum.map(checks, fn command ->
      left = budget - (System.monotonic_time(:millisecond) - started)

      cond do
        left <= 1_000 ->
          %{command: command, exit: nil, status: :not_run, tail: "the hook's time budget ran out"}

        true ->
          run_one(command, dir, min(timeout, left), runner)
      end
    end)
  end

  defp run_one(command, dir, timeout, runner) do
    case safe_split(command) do
      {:ok, [_ | _] = argv} ->
        case runner.(argv, dir, timeout) do
          {out, 0} ->
            %{command: command, exit: 0, status: :passed, tail: tail(out)}

          {out, code} when is_integer(code) ->
            %{command: command, exit: code, status: :failed, tail: tail(out)}

          {_out, :timeout} ->
            %{
              command: command,
              exit: nil,
              status: :timed_out,
              tail: "killed after #{div(timeout, 1000)}s"
            }

          {_out, {:error, why}} ->
            %{command: command, exit: nil, status: :error, tail: why}
        end

      _ ->
        %{command: command, exit: nil, status: :error, tail: "could not parse the command"}
    end
  end

  defp safe_split(command) do
    {:ok, OptionParser.split(command)}
  rescue
    _ -> :error
  end

  defp tail(out) do
    len = String.length(out)
    if len > @tail_chars, do: String.slice(out, len - @tail_chars, @tail_chars), else: out
  end

  defp run_port([bin | args], dir, timeout) do
    case executable(bin, dir) do
      nil ->
        {"", {:error, "command not found: #{bin}"}}

      exe ->
        port =
          Port.open({:spawn_executable, String.to_charlist(exe)}, [
            :binary,
            :exit_status,
            :stderr_to_stdout,
            :hide,
            args: Enum.map(args, &String.to_charlist/1),
            cd: String.to_charlist(dir),
            env: Enum.map(@release_env, &{String.to_charlist(&1), false})
          ])

        os_pid =
          case Port.info(port, :os_pid) do
            {:os_pid, pid} -> pid
            _ -> nil
          end

        deadline = System.monotonic_time(:millisecond) + timeout
        collect(port, os_pid, deadline, [])
    end
  end

  defp executable(bin, dir) do
    if String.contains?(bin, "/") do
      path = Path.expand(bin, dir)
      if File.regular?(path), do: path
    else
      System.find_executable(bin)
    end
  end

  defp collect(port, os_pid, deadline, acc) do
    left = deadline - System.monotonic_time(:millisecond)

    if left <= 0 do
      Sprat.Agent.Tools.Shell.kill_tree(os_pid)

      try do
        Port.close(port)
      catch
        :error, _ -> :ok
      end

      {IO.iodata_to_binary(Enum.reverse(acc)), :timeout}
    else
      receive do
        {^port, {:data, data}} -> collect(port, os_pid, deadline, [data | acc])
        {^port, {:exit_status, code}} -> {IO.iodata_to_binary(Enum.reverse(acc)), code}
      after
        min(left, 500) -> collect(port, os_pid, deadline, acc)
      end
    end
  end

  # ── evidence fingerprint ────────────────────────────────────────────────

  @doc """
  A hash of the working tree's state: HEAD, the diff against HEAD and the
  untracked files (name and content; size and mtime above 1 MB). Two stops with the same fingerprint
  are the same evidence. `nil` outside a git checkout.
  """
  @spec fingerprint(Path.t()) :: String.t() | nil
  def fingerprint(dir) do
    git = fn args -> System.cmd("git", ["-C", dir | args], stderr_to_stdout: true) end

    with {head, 0} <- git.(["rev-parse", "--verify", "-q", "HEAD"]) |> ok_or_empty(),
         {diff, 0} <- git.(["diff", "HEAD", "--binary"]) |> ok_or_empty(),
         {untracked, 0} <- git.(["ls-files", "--others", "--exclude-standard", "-z"]) do
      stats =
        untracked
        |> String.split(<<0>>, trim: true)
        |> Enum.map(fn f ->
          path = Path.join(dir, f)

          case File.stat(path) do
            {:ok, %{size: size}} when size <= 1_000_000 ->
              "#{f}:#{Base.encode16(:crypto.hash(:sha256, File.read!(path)))}"

            {:ok, s} ->
              "#{f}:#{s.size}:#{inspect(s.mtime)}"

            _ ->
              f
          end
        end)

      :crypto.hash(:sha256, [head, 0, diff, 0, Enum.intersperse(stats, "\n")])
      |> Base.encode16(case: :lower)
    else
      _ -> nil
    end
  rescue
    _ -> nil
  end

  # A repo with no commits yet: HEAD and `diff HEAD` fail, which is still a
  # git checkout — hash what exists.
  defp ok_or_empty({out, 0}), do: {out, 0}
  defp ok_or_empty({_out, 1}), do: {"", 0}

  defp ok_or_empty({out, 128}),
    do: if(out =~ "ambiguous argument 'HEAD'", do: {"", 0}, else: {out, 128})

  defp ok_or_empty(other), do: other
end
