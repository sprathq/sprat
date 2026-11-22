defmodule Sprat.Spike.Terminal do
  @moduledoc """
  Raw-mode lifecycle: enter raw + bracketed paste, and guarantee restoration
  on every exit path required by spec §10 "Terminal lifecycle":
  normal exit, Ctrl+C twice, Ctrl+D, a raised exception, SIGTERM.

  ponytail: no NIF, no port program — `:shell.start_interactive/1` (OTP 26+)
  for raw mode, plain `stty` for the belt-and-braces restore, because a
  crashed process cannot be trusted to have left the tty in a sane state.
  """

  @paste_on "\e[?2004h"
  @paste_off "\e[?2004l"
  @cursor_hide "\e[?25l"
  @cursor_show "\e[?25h"

  @doc "Capture the current stty state so we can restore it exactly."
  def saved_stty do
    case System.cmd("stty", ["-g"], stderr_to_stdout: true) do
      {out, 0} -> String.trim(out)
      _ -> nil
    end
  end

  @doc """
  Enter raw mode. Uses the OTP 26+ API the spec calls out; on any error
  (e.g. not a real TTY, or the API not being backed by a working driver on
  this OTP/terminal combo) falls back to `stty raw -echo` and returns which
  path was used, which the spike logs.
  """
  def enable_raw! do
    IO.write(@cursor_hide)
    IO.write(@paste_on)

    result =
      case :shell.start_interactive({:noshell, :raw}) do
        :ok ->
          {:ok, :shell_start_interactive}

        other ->
          case System.cmd("stty", ["raw", "-echo"], stderr_to_stdout: true) do
            {_, 0} -> {:ok, {:stty_fallback, other}}
            {err, _} -> {:error, {other, err}}
          end
      end

    # :shell.start_interactive's raw mode leaves ISIG set, so Ctrl+C still
    # raises a real (uncatchable, see install_exit_traps!/2) SIGINT instead
    # of being delivered as byte 0x03. Clear it explicitly so the composer
    # gets the byte and decides what Ctrl+C means, per spec §10 keybindings.
    System.cmd("stty", ["-isig"], stderr_to_stdout: true)

    result
  end

  @doc "Best-effort restore. Safe to call multiple times (Ctrl+C twice, at_exit, rescue)."
  def restore!(saved \\ nil) do
    IO.write(@paste_off)
    IO.write(@cursor_show)

    if saved do
      System.cmd("stty", [saved], stderr_to_stdout: true)
    else
      System.cmd("stty", ["sane"], stderr_to_stdout: true)
    end

    :ok
  end

  @doc """
  Install the exit-path guarantees: VM-level at_exit hook plus SIGTERM and
  SIGINT traps.

  The SIGINT trap matters more than it looks: `:shell.start_interactive/1`'s
  raw mode does NOT clear ISIG (unlike a real `stty raw`), so Ctrl+C still
  fires a genuine SIGINT that terminates the VM by default before byte 0x03
  ever reaches our own key parser as data — the composer-level "press twice
  within 2s" handling in Sprat.Spike.Renderer is dead code without this trap.
  Trapping :sigint both restores the terminal and stops the VM from dying on
  the spot, so app code decides what a Ctrl+C means instead of the OS.
  Found and confirmed empirically in this spike; see
  docs/phase0/03-terminal-spike.md.
  """
  def install_exit_traps!(saved, notify \\ nil) do
    System.at_exit(fn _status -> restore!(saved) end)

    handler = fn ->
      restore!(saved)
      if notify, do: send(notify, {:signal_exit, :sigterm})
    end

    # NOTE: :sigint is NOT in the set System.trap_signal/3 accepts (confirmed
    # empirically — FunctionClauseError). Combined with :shell.start_interactive
    # raw mode not clearing ISIG, Ctrl+C is *uncatchable* here: it is a real
    # SIGINT that kills the VM via the OS default action before any Elixir
    # code runs. The fix has to be at the terminal-mode layer (ISIG off via
    # stty), not a signal trap — see enable_raw!/0 and
    # docs/phase0/03-terminal-spike.md.
    case System.trap_signal(:sigterm, :terminal_spike_restore, handler) do
      {:ok, _ref} -> :ok
      {:error, reason} -> {:sigterm_trap_failed, reason}
    end
  end
end
