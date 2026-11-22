defmodule Sprat.Engine.RuntimeWarningTest do
  use ExUnit.Case, async: true

  alias Sprat.Engine.Runtime

  @now ~U[2026-11-23 12:00:00Z]

  test "a fresh snapshot from a live daemon carries no warning" do
    snap = %{published_at: ~U[2026-11-23 11:59:58Z]}
    assert %{daemon_warning: nil} = Runtime.with_warning(snap, @now, fn -> true end)
  end

  test "a snapshot not republished for a while says so" do
    snap = %{published_at: ~U[2026-11-23 11:43:52Z]}
    assert %{daemon_warning: msg} = Runtime.with_warning(snap, @now, fn -> true end)
    assert msg =~ "has not updated since 11:43:52"
  end

  test "a dead daemon says so" do
    assert %{daemon_warning: msg} = Runtime.with_warning(%{}, @now, fn -> false end)
    assert msg =~ "not running"
  end
end
