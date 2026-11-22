defmodule Sprat.Terminal.Mode do
  @moduledoc """
  Raw-mode terminal lifecycle and headless/non-TTY detection.

  Ctrl+C is closed primarily via `stty raw -echo` against the controlling
  tty: POSIX defines `raw` as also clearing ISIG, so Ctrl+C arrives as byte
  0x03 like any other control character instead of the OS delivering a real,
  uncatchable SIGINT that kills the VM before any Elixir code runs (spike
  finding, `docs/phase0/03-terminal-spike.md`: `:shell.start_interactive`'s
  raw mode does *not* clear ISIG, and `:sigint` isn't even in
  `System.trap_signal/3`'s supported signal set — the fix has to be at the
  terminal-mode layer, not a signal trap). `stty raw -echo` is therefore the
  primary path here.

  `stty` never targets `/dev/tty`: against a real, freshly-booted release
  (`bin/sprat start`/`sprat`, not a stray leftover node — confirmed by
  first clearing every stale `_build/dev/rel/sprat/erts` process, since one
  left registered under the release's `-sname` silently answers `stty`'s
  probe with `/bin/sh: /dev/tty: Device not configured`, ENXIO, every
  time), `/dev/tty` fails to resolve to the controlling terminal for a
  `System.cmd/3`-spawned child even though this OS process demonstrably
  has one (`ps` shows a real tty column, and this VM's own `/dev/stdin`
  reads work) — a real, reproduced gap between "this process has a
  controlling tty" and "a shell this process spawns can open `/dev/tty`
  and land on the same one." `enable_raw!/0` used to fall back to
  `:shell.start_interactive({:noshell, :raw})` on that failure, which does
  *not* clear ISIG — so Ctrl+C was silently never delivered as byte 0x03
  at all (confirmed via a real tmux capture: `isig` stayed on, and neither
  a plain control chord like Ctrl+U nor Ctrl+C had any effect), regardless
  of the `+Bi`/`-Bd`/menu question `rel/vm.args.eex` separately fixes.

  Fixed by never asking `stty` to resolve a tty path at all: `stty(/2)`
  spawns with the Erlang port option `:nouse_stdio`, which skips Erlang's
  own stdio piping entirely and lets the child inherit this OS process's
  *actual* fds 0/1/2 directly — the same fds this VM's own raw
  `/dev/stdin` reader already proves are the real pty. `stty` with no
  device argument acts on its own stdin, so this reaches the right
  terminal unconditionally, on every launch path (`start`, `eval`, `mix
  run`, `iex`) — the launch-path-dependent fallback is no longer needed.

  Guarantees terminal restoration (show cursor, disable bracketed paste,
  restore the saved stty settings) on every exit path: normal exit, a
  renderer crash, SIGTERM, and VM halt.
  """

  @paste_on "\e[?2004h"
  @paste_off "\e[?2004l"
  @cursor_hide "\e[?25l"
  @cursor_show "\e[?25h"

  @doc """
  True when stdout is a real TTY — the only condition under which the UI
  supervisor should start (see `Sprat.UISupervisor`). Uses `:io.columns/0`
  and `:io.rows/0` directly (no subprocess): they run in-process against
  this VM's own stdio, so they're accurate regardless of the tty-forwarding
  quirks documented above for spawned ports.
  """
  def tty? do
    match?({:ok, _}, :io.columns()) and match?({:ok, _}, :io.rows())
  end

  @doc "Capture the current stty state so it can be restored exactly."
  def saved_stty do
    case stty(["-g"]) do
      {out, 0} -> String.trim(out)
      _ -> nil
    end
  end

  @doc """
  Enter raw mode: hide the cursor, enable bracketed paste, and put the
  controlling tty into `stty raw -echo` (ISIG cleared, so Ctrl+C is
  delivered as byte 0x03). Falls back to `:shell.start_interactive` on the
  rare case `stty` itself can't run at all (see moduledoc — reaching the
  right tty is no longer the failure mode `stty/1` has). Returns
  `{:ok, saved_stty_state}` either way; the caller doesn't need to know
  which path was used.
  """
  def enable_raw! do
    saved = saved_stty()
    IO.write(@cursor_hide)
    IO.write(@paste_on)

    case stty(["raw", "-echo"]) do
      {_, 0} -> {:ok, saved}
      _ -> :shell.start_interactive({:noshell, :raw})
    end

    {:ok, saved}
  end

  @doc "Best-effort restore. Safe to call multiple times (Ctrl+C twice, at_exit, rescue)."
  def restore!(saved \\ nil) do
    IO.write(@paste_off)
    IO.write(@cursor_show)

    if saved do
      stty([saved])
    else
      stty(["sane"])
    end

    restore_default_logger!()

    :ok
  end

  @doc """
  Removes OTP's default `:logger` handler for as long as the zoned/inline
  UI owns the screen. `Sprat.LogHandler`'s moduledoc used to claim this
  codebase never has a second stdout writer, but the default handler
  (installed by OTP itself, `config/*.exs` never touches it) keeps writing
  formatted log events and crash reports straight to stdout/group-leader
  regardless — landing on the same alternate-screen the renderer's own
  cursor-move+write sequences target, interleaved at whatever point a log
  event happens to fire mid-repaint. Confirmed by a real tmux repro: a
  crashed supervised task's crash report appeared as raw text over the
  zoned UI before this fix (`test/tty/verify.sh`'s "no crash text visible"
  check). `Sprat.LogHandler` stays installed throughout — it's a second,
  separate sink, not the default console handler — so `Sprat.LogBuffer`
  and the Debug overlay's Logs tab still get every event.

  The captured handler config is stashed in application env (not returned)
  so `restore!/1` can put it back from any process — the renderer that
  calls `restore!/1` in `terminate/2` on a crash is never the process that
  called this.
  """
  def silence_default_logger! do
    case :logger.get_handler_config(:default) do
      {:ok, config} ->
        Application.put_env(:sprat, :silenced_default_logger, config)
        :logger.remove_handler(:default)
        :ok

      {:error, _} ->
        :ok
    end
  end

  @doc "Re-installs the default `:logger` handler removed by `silence_default_logger!/0`, if any. Idempotent — safe with nothing silenced, or called more than once."
  def restore_default_logger! do
    case Application.get_env(:sprat, :silenced_default_logger) do
      nil ->
        :ok

      config ->
        Application.delete_env(:sprat, :silenced_default_logger)

        case :logger.add_handler(:default, Map.get(config, :module, :logger_std_h), config) do
          :ok -> :ok
          {:error, {:already_exist, :default}} -> :ok
          _other -> :ok
        end
    end
  end

  @doc """
  Runs `stty args` against the controlling terminal (same inherited-fd
  path as `enable_raw!/0`). Returns the exit status. Used by
  `Sprat.Terminal.BoardApp` to set `min 0 time 1` so its input reader can
  poll and stop cleanly before handing the terminal to `$EDITOR`.
  """
  def stty!(args) when is_list(args) do
    {_out, status} = stty(args)
    status
  end

  # `:nouse_stdio` is the whole fix (see moduledoc): it tells the Erlang
  # port not to set up its usual stdio pipes at all, so the spawned shell
  # inherits this OS process's real fds 0/1/2 directly — the same fds
  # `Sprat.Terminal.Input`'s raw `/dev/stdin` reader already proves are
  # the real pty, on every launch path. `stty` with no device argument
  # acts on its own stdin, which is now guaranteed to be the right one.
  #
  # `-g`'s output has to be captured, but a `:nouse_stdio` port has no
  # message channel to read it back from (stdout goes straight to the
  # real terminal) — routed to a temp file instead, read back afterward,
  # while stdin (what `stty -g` actually introspects) stays inherited.
  defp stty(args) do
    quoted = Enum.map_join(args, " ", &shell_quote/1)

    if "-g" in args do
      path = Path.join(System.tmp_dir!(), "sprat_stty_#{System.unique_integer([:positive])}")

      try do
        {_, status} = run_inherited("stty #{quoted} > #{shell_quote(path)} 2>&1")

        out =
          case File.read(path) do
            {:ok, content} -> content
            {:error, _} -> ""
          end

        {out, status}
      after
        File.rm(path)
      end
    else
      run_inherited("stty #{quoted} >/dev/null 2>&1")
    end
  end

  defp run_inherited(cmd) do
    port =
      Port.open({:spawn_executable, System.find_executable("sh")}, [
        :nouse_stdio,
        :exit_status,
        args: ["-c", cmd]
      ])

    receive do
      {^port, {:exit_status, status}} -> {"", status}
    after
      2_000 -> {"stty timed out", 1}
    end
  end

  defp shell_quote(arg), do: "'#{String.replace(arg, "'", "'\\''")}'"

  @doc """
  Install the exit-path guarantees: a VM-level `at_exit` hook plus a SIGTERM
  trap. Restoration on a raised exception in the caller is the caller's
  responsibility via `try/after` around its own work — see
  `Sprat.Terminal.Renderer`'s `terminate/2`.
  """
  def install_exit_traps!(saved) do
    System.at_exit(fn _status -> restore!(saved) end)

    case System.trap_signal(:sigterm, :sprat_terminal_restore, fn -> restore!(saved) end) do
      {:ok, _ref} -> :ok
      {:error, reason} -> {:sigterm_trap_failed, reason}
    end
  end
end
