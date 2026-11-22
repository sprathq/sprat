defmodule Sprat.CLI.PlainShellTest do
  use Sprat.StoreCase, async: true

  alias Sprat.CLI.PlainShell
  alias Sprat.{Session, SessionSupervisor}
  alias Sprat.Store.Sessions

  # Seam test: `Sprat.Terminal.Transcript`'s formatters have always skipped
  # ANSI correctly when told to (`Glyphs.color?/1`), and were unit-tested
  # that way — but `--plain`'s whole point (spec §10 "Degraded and
  # accessible output") is that its output never carries escape codes,
  # and until `Sprat.CLI.PlainShell` started passing `color: false`
  # through to `Sprat.Session.Render`, it relied on `Glyphs.color?/1`'s
  # default ("on unless NO_COLOR is set"), which is wrong for this mode.
  # This drives the real `PlainShell.run/1` entry point end to end and
  # fails again if that `color: false` opt is dropped from either call
  # site, even though the formatters themselves stay correct on their own.
  test "replaying a transcript with NO_COLOR unset never emits ANSI escapes", %{store: store} do
    System.delete_env("NO_COLOR")

    {:ok, session} = Sessions.create(store, %{project_path: "/tmp/plain-shell-test"})
    {:ok, pid} = SessionSupervisor.open(session.id, store: store)

    :ok =
      Session.add_block(pid, %{
        kind: :agent_message,
        role: "researcher",
        markdown: "**bold** finding"
      })

    output =
      ExUnit.CaptureIO.capture_io("", fn ->
        PlainShell.run(session.id)
      end)

    refute output =~ "\e["
    assert output =~ "bold"
  end
end
