defmodule Sprat.CLI.PlainShell do
  @moduledoc """
  `sprat --plain` (docs/spec-v1.md §10 "Degraded and accessible output"):
  no live-region redraws, no spinner, line-oriented output; prompts become
  numbered line prompts read once via `IO.gets/1`, not redrawn in place.
  Talks to the same `Sprat.Session`/`Sprat.Session.PubSub` boundary as the
  raw-mode `Sprat.Session.Shell`, just rendered through
  `Sprat.Terminal.Plain` instead of `Sprat.Terminal.Renderer`.
  """

  alias Sprat.Terminal.Plain
  alias Sprat.Session
  alias Sprat.Session.{Commands, PubSub, Render}
  alias Sprat.SessionSupervisor

  @width 80

  # `--plain`'s whole point (spec §10 "Degraded and accessible output") is
  # deterministic, pipeable text — `Sprat.Terminal.Transcript`'s formatters
  # (reused here via `Sprat.Session.Render`) only skip ANSI styling when
  # `Sprat.Terminal.Glyphs.color?/1` sees `color: false`, and otherwise
  # default to "on unless NO_COLOR is set" — the raw-mode default, wrong
  # for this mode. Without this, `--plain` output redirected to a file or
  # piped to another program carried escape codes regardless of NO_COLOR.
  @render_opts [color: false]

  def run(session_id) do
    # `--plain`'s whole point is deterministic, pipeable output (§10) — a
    # bell or OS notification firing into that stream would be exactly
    # the noise it exists to avoid, so this session never notifies.
    {:ok, _session} = SessionSupervisor.open(session_id, notify?: false)
    {:ok, _owner} = PubSub.subscribe(session_id)
    replay(session_id)
    loop(session_id)
  end

  defp replay(session_id) do
    snapshot = Session.snapshot(session_id)
    snapshot.blocks |> Render.batch_to_lines(@width, @render_opts) |> Enum.each(&IO.puts/1)
    show_permission(snapshot.live.permission)
  end

  defp loop(session_id) do
    permission = Session.snapshot(session_id).live.permission
    prompt = if permission, do: "Enter a number: ", else: "> "

    case IO.gets(prompt) do
      :eof -> :ok
      {:error, _} -> :ok
      line -> handle_line(session_id, String.trim(line), permission)
    end
  end

  defp handle_line(session_id, text, permission) when not is_nil(permission) do
    case Integer.parse(text) do
      {n, _} when n in [1, 2, 3] ->
        :ok = Session.recovery_choice(session_id, n - 1)
        drain(session_id)
        loop(session_id)

      _ ->
        IO.puts("Please enter 1, 2, or 3.")
        loop(session_id)
    end
  end

  defp handle_line(session_id, text, nil) do
    case Commands.handle(session_id, Sprat.Store, text) do
      {:switch_session, new_id} -> run(new_id)
      :ok -> drain(session_id)
    end

    loop(session_id)
  end

  defp drain(session_id) do
    receive do
      {:sprat_session, ^session_id, {:block_added, block}} ->
        block |> Render.to_lines(@width, @render_opts) |> Enum.each(&IO.puts/1)
        drain(session_id)

      {:sprat_session, ^session_id, {:live_updated, %{permission: permission}}} ->
        show_permission(permission)
        drain(session_id)

      {:sprat_session, ^session_id, _other} ->
        drain(session_id)
    after
      0 -> :ok
    end
  end

  defp show_permission(nil), do: :ok

  defp show_permission(permission),
    do: permission |> Plain.prompt_lines() |> Enum.each(&IO.puts/1)
end
