defmodule Sprat.NotifyTest do
  use ExUnit.Case, async: false

  alias Sprat.Notify

  setup do
    project_dir =
      Path.join(System.tmp_dir!(), "sprat-notify-project-#{System.unique_integer([:positive])}")

    File.mkdir_p!(project_dir)
    on_exit(fn -> File.rm_rf(project_dir) end)
    {:ok, project: project_dir}
  end

  defp capture_notifier do
    parent = self()
    fn title, message -> send(parent, {:notified, title, message}) end
  end

  describe "pause/2" do
    test "rings the bell and calls the notifier when tty and enabled", %{project: project} do
      {:ok, io_pid} = StringIO.open("")

      Notify.pause(project,
        tty_check: fn -> true end,
        notifier: capture_notifier(),
        io_device: io_pid
      )

      assert_receive {:notified, "Sprat needs you", "waiting for your input"}
      {_input, output} = StringIO.contents(io_pid)
      assert output == "\a"
    end

    test "does nothing when notify?: false (plain mode)", %{project: project} do
      Notify.pause(project,
        notify?: false,
        tty_check: fn -> true end,
        notifier: capture_notifier()
      )

      refute_receive {:notified, _, _}, 50
    end

    test "does nothing when not attached to a real tty", %{project: project} do
      Notify.pause(project, tty_check: fn -> false end, notifier: capture_notifier())
      refute_receive {:notified, _, _}, 50
    end

    test "bell is suppressed by notify_bell = false, desktop notification still fires", %{
      project: project
    } do
      :ok = Sprat.Config.put_notify_bell(project, false)
      {:ok, io_pid} = StringIO.open("")

      Notify.pause(project,
        tty_check: fn -> true end,
        notifier: capture_notifier(),
        io_device: io_pid
      )

      assert_receive {:notified, _, _}
      assert StringIO.contents(io_pid) == {"", ""}
    end

    test "desktop notification is suppressed by notify_desktop = false, bell still rings", %{
      project: project
    } do
      :ok = Sprat.Config.put_notify_desktop(project, false)
      {:ok, io_pid} = StringIO.open("")

      Notify.pause(project,
        tty_check: fn -> true end,
        notifier: capture_notifier(),
        io_device: io_pid
      )

      refute_receive {:notified, _, _}, 50
      {_input, output} = StringIO.contents(io_pid)
      assert output == "\a"
    end
  end

  describe "finished/3" do
    test "delivered mission message", %{project: project} do
      Notify.finished(project, :completed,
        tty_check: fn -> true end,
        notifier: capture_notifier()
      )

      assert_receive {:notified, "Sprat", "mission delivered"}
    end

    test "failed mission message", %{project: project} do
      Notify.finished(project, :failed, tty_check: fn -> true end, notifier: capture_notifier())
      assert_receive {:notified, "Sprat", "mission failed"}
    end
  end

  test "never raises when the OS mechanism is absent — falls through to the default notifier with no crash",
       %{project: project} do
    # No `:notifier` opt: exercises the real `default_notifier/2`, which
    # only ever shells out if osascript/notify-send is actually on PATH.
    {:ok, io_pid} = StringIO.open("")
    assert :ok = Notify.pause(project, tty_check: fn -> true end, io_device: io_pid)
  end
end
