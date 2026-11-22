defmodule Sprat.Session.Shell do
  @moduledoc """
  The interactive run loop for a real terminal session — what `sprat`,
  `sprat --continue` and `sprat --resume` actually start. Owns nothing
  itself: it starts the `Sprat.Session`, points a `Sprat.Session.Subscriber`
  at it, becomes the renderer's intent subscriber, and translates the
  handful of intents `Sprat.Terminal.Renderer`/`Sprat.Terminal.ZonedRenderer`
  forward (submit, permission result, mode change, exit) into calls on
  `Sprat.Session` and `Sprat.Session.Commands` — the same role `Sprat.Demo`
  plays for the demo flow, but wired to a real, persisted session instead
  of a scripted one.

  `opts[:mode]` (default `:zoned`) selects which renderer
  `Sprat.UISupervisor` starts — `:zoned` (the default UI,
  `docs/design/tui-zones.md`) or `:inline` (`--inline`, the old renderer).
  `Sprat.Session.Subscriber` needs no changes either way: its public API
  contract is just "a process with `commit/2`/`set_live/2`-shaped casts",
  which both renderers implement — see `ZonedRenderer`'s moduledoc.
  """

  alias Sprat.Terminal.Mode
  alias Sprat.Store.{ProjectHistory, Sessions}
  alias Sprat.Session
  alias Sprat.Session.{Commands, ExitSummary, Subscriber}
  alias Sprat.{SessionSupervisor, UISupervisor}

  @doc "Opens `session_id` (must already exist) in the interactive TUI. Blocks until the user exits."
  def run(session_id, opts \\ []) do
    unless Mode.tty?() do
      IO.puts(:stderr, "Sprat needs a real terminal (stdin and stdout). Try `sprat --plain`.")
      exit({:shutdown, 1})
    end

    renderer = ensure_ui_started(session_id, opts)
    loop_from(session_id, renderer, opts)
  end

  defp loop_from(session_id, renderer, opts) do
    {:ok, _session} = SessionSupervisor.open(session_id, Keyword.delete(opts, :mode))
    {:ok, sub} = Subscriber.start_link(session_id: session_id, renderer: renderer)
    renderer.subscribe(self())
    renderer.set_footer(%{mode: Session.snapshot(session_id).mode, cost: "$0.00", sources: 0})

    case loop(session_id) do
      {:switch_session, new_session_id} ->
        GenServer.stop(sub)
        loop_from(new_session_id, renderer, opts)

      :done ->
        stop_ui_and_print_summary(session_id)
    end
  end

  defp ensure_ui_started(session_id, opts) do
    mode = Keyword.get(opts, :mode, :zoned)
    renderer = UISupervisor.renderer_module(mode: mode)

    case Process.whereis(UISupervisor) do
      nil ->
        {:ok, _pid} =
          UISupervisor.start_link(
            mode: mode,
            commands: Commands.list(),
            history: history(session_id),
            session_id: session_id,
            project_path: project_path(session_id)
          )

      _pid ->
        :ok
    end

    renderer
  end

  # Alternate screen must be left cleanly before the exit summary is
  # printed — the design's mitigation for losing the terminal's own
  # scrollback ("On exit, print a short summary... into normal
  # scrollback"). `UISupervisor`'s child renderer restores cooked mode and
  # leaves the alternate screen in `terminate/2`, so stopping it here,
  # before `ExitSummary.print/1` runs, is what puts that summary on the
  # real, visible scrollback rather than the vanishing alternate screen.
  defp stop_ui_and_print_summary(session_id) do
    case Process.whereis(UISupervisor) do
      nil -> :ok
      pid -> Supervisor.stop(pid)
    end

    ExitSummary.print(session_id)
    :done
  end

  defp history(session_id) do
    case Sessions.get(session_id) do
      %{project_path: path} when is_binary(path) -> ProjectHistory.load(path)
      _ -> []
    end
  end

  defp project_path(session_id) do
    case Sessions.get(session_id) do
      %{project_path: path} -> path
      _ -> nil
    end
  end

  defp loop(session_id) do
    receive do
      {:sprat_intent, {:submit, text}} ->
        dispatch_submit(session_id, text)

      {:sprat_intent, {:permission_result, n}} ->
        case Session.answer_permission(session_id, n) do
          :ok -> :ok
          {:error, :no_prompt} -> Session.recovery_choice(session_id, n)
        end

        loop(session_id)

      {:sprat_intent, :permission_cancelled} ->
        case Session.cancel_permission(session_id) do
          :ok -> :ok
          {:error, :no_prompt} -> Session.recovery_choice(session_id, 2)
        end

        loop(session_id)

      {:sprat_intent, {:mode, mode}} ->
        Session.set_mode(session_id, mode)
        loop(session_id)

      {:sprat_intent, {:settings_edit, key}} ->
        Commands.edit_setting(session_id, Sprat.Store, key)
        loop(session_id)

      {:sprat_intent, :interrupt} ->
        Sprat.Mission.cancel(session_id)
        loop(session_id)

      {:sprat_intent, :exit} ->
        :done

      {:sprat_intent, :input_closed} ->
        :done

      {:sprat_intent, _other} ->
        loop(session_id)
    end
  end

  defp dispatch_submit(session_id, text) do
    case Commands.handle(session_id, Sprat.Store, text) do
      {:switch_session, new_id} -> {:switch_session, new_id}
      :ok -> loop(session_id)
    end
  end
end
