defmodule Sprat.Notify do
  @moduledoc """
  Terminal bell (`\\a`) + best-effort OS desktop notification for the
  moments a mission needs the user to look at the terminal: paused for
  input (fetch approval, a Directions choice, stage-failure recovery —
  every one of them funnels through `Sprat.Session.await_permission/2`)
  and a mission reaching a terminal state. Missions run ten minutes and
  pause silently — the user walks away and comes back to find it waited
  most of that for an answer nobody heard it ask for.

  Fired only at those two moments, never per model turn.

  Config: `Sprat.Config`'s `notify_bell`/`notify_desktop` project
  settings, on by default (`/settings`, `sprat settings`, or edited
  directly). Suppressed whenever the caller passes `notify?: false`
  (`Sprat.CLI.PlainShell`'s `--plain` never does — deterministic, pipeable
  output is the whole point of that mode) or the process isn't attached
  to a real tty (`Sprat.Terminal.Mode.tty?/0`) — a bell with nobody there
  to hear it is just noise.

  The OS call is injectable (`opts[:notifier]`, or the `:sprat,
  :notifier` app env — a 2-arity `title, message -> :ok` fun) so tests
  never shell out to `osascript`/`notify-send`.
  """

  alias Sprat.Config
  alias Sprat.Terminal.Mode

  @doc "A mission paused and needs the user (fetch approval, Directions choice, stage-failure recovery)."
  def pause(project_path, opts \\ []),
    do: fire(project_path, "Sprat needs you", "waiting for your input", opts)

  @doc "A mission reached a terminal state (`:completed` or `:failed`)."
  def finished(project_path, status, opts \\ [])

  def finished(project_path, :completed, opts),
    do: fire(project_path, "Sprat", "mission delivered", opts)

  def finished(project_path, :failed, opts),
    do: fire(project_path, "Sprat", "mission failed", opts)

  defp fire(project_path, title, message, opts) do
    if Keyword.get(opts, :notify?, true) and tty?(opts) do
      if Config.notify_bell(project_path), do: ring_bell(opts)
      if Config.notify_desktop(project_path), do: desktop(title, message, opts)
    end

    :ok
  end

  defp tty?(opts), do: Keyword.get(opts, :tty_check, &Mode.tty?/0).()

  defp ring_bell(opts) do
    device = Keyword.get(opts, :io_device, :stdio)
    IO.write(device, "\a")
  end

  # Never raises and never blocks the caller: `System.find_executable/1`
  # first (so a missing osascript/notify-send is a plain no-op, not an
  # error), and the whole thing rescued besides — a notification is a
  # nicety, not a dependency the rest of a mission can fail on.
  defp desktop(title, message, opts) do
    notifier =
      Keyword.get(opts, :notifier) || Application.get_env(:sprat, :notifier) ||
        (&default_notifier/2)

    notifier.(title, message)
    :ok
  rescue
    _ -> :ok
  end

  defp default_notifier(title, message) do
    cond do
      System.find_executable("osascript") ->
        script = "display notification #{inspect(message)} with title #{inspect(title)}"
        System.cmd("osascript", ["-e", script], stderr_to_stdout: true)
        :ok

      System.find_executable("notify-send") ->
        System.cmd("notify-send", [title, message], stderr_to_stdout: true)
        :ok

      true ->
        :ok
    end
  rescue
    _ -> :ok
  end
end
