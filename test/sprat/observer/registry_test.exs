defmodule Sprat.Observer.RegistryTest do
  use ExUnit.Case, async: true

  alias Sprat.Observer.Model.Session
  alias Sprat.Observer.Registry

  @dir Path.expand("../../fixtures/v4/registry", __DIR__)

  test "scans sessions, one liveness call, dead pids end" do
    parent = self()

    alive = fn pids ->
      send(parent, {:alive_called, Enum.sort(pids)})
      [1001, 1002]
    end

    sessions = Registry.scan([@dir], alive_fun: alive, account_fun: fn _ -> %{} end)

    assert_received {:alive_called, [1001, 1002, 1003]}
    refute_received {:alive_called, _}

    assert [%Session{} = a, b, c] = Enum.sort_by(sessions, & &1.pid)

    assert a.session_id == "11111111-1111-4111-8111-111111111111"
    assert a.config_dir == @dir
    assert a.live? and a.status == :idle
    assert a.name == "Lantern"
    assert a.cwd == "/tmp/sprat-fixture/alpha"
    assert a.version == "2.1.330"
    assert a.started_at == DateTime.from_unix!(1_795_107_174_116, :millisecond)
    assert a.status_since == DateTime.from_unix!(1_795_126_858_019, :millisecond)

    assert b.live? and b.status == :busy
    assert b.tmux == %{"session" => "work", "pane" => "%3"}

    refute c.live?
    assert c.status == :ended
  end

  test "a live session takes the account its process runs under" do
    other = "/Users/someone/.claude-work"

    sessions =
      Registry.scan([@dir],
        alive_fun: fn _ -> [1001, 1002] end,
        account_fun: fn pids ->
          assert Enum.sort(pids) == [1001, 1002]
          %{1001 => other, 1002 => @dir}
        end
      )

    [a, b, c] = Enum.sort_by(sessions, & &1.pid)
    assert a.config_dir == other
    assert b.config_dir == @dir
    assert c.config_dir == @dir
  end

  test "no sessions means no ps call" do
    assert Registry.scan(["/nonexistent"], alive_fun: fn _ -> flunk("called") end) == []
  end

  @tag :tmp_dir
  test "default liveness checks real pids with ps", %{tmp_dir: dir} do
    me = System.pid() |> String.to_integer()
    File.mkdir_p!(Path.join(dir, "sessions"))

    for {pid, sid} <- [{me, "alive"}, {99_999_999, "out-of-range"}, {99_998, "maybe-dead"}] do
      File.write!(
        Path.join(dir, "sessions/#{pid}.json"),
        JSON.encode!(%{pid: pid, sessionId: sid, status: "idle"})
      )
    end

    by_sid = dir |> List.wrap() |> Registry.scan() |> Map.new(&{&1.session_id, &1})
    assert %{live?: true, status: :idle} = by_sid["alive"]
    assert %{live?: false, status: :ended} = by_sid["out-of-range"]
  end

  test "parse rejects bad documents" do
    assert :error = Registry.parse("/x", "nope")
    assert :error = Registry.parse("/x", ~s({"pid": 1}))

    assert {:ok, %Session{status: :unknown}} =
             Registry.parse("/x", ~s({"sessionId": "s", "status": "weird"}))
  end
end
