defmodule Sprat.Observer.SurfacesTest do
  # async: false — one test sets CMUX_BIN.
  use ExUnit.Case, async: false

  alias Sprat.Observer.Surfaces

  @tsv File.read!(Path.expand("../../fixtures/v4/cmux/top.tsv", __DIR__))

  test "maps pids to surfaces through tag rows and parent chains" do
    map = Surfaces.parse_cmux_top(@tsv)

    assert map[48717] == "surface:239"
    assert map[52313] == "surface:239"
    assert map[23814] == "surface:239"
    # listed under a workspace tag and under a surface: the surface wins
    assert map[65792] == "surface:261"
    assert map[42844] == "surface:261"
    # only under a tag: no surface
    refute Map.has_key?(map, 60307)
    refute Map.has_key?(map, 60768)
    refute Map.has_key?(map, 85368)
  end

  test "garbage and cycles do not crash" do
    assert Surfaces.parse_cmux_top("") == %{}
    assert Surfaces.parse_cmux_top("a\tb\nnot a row") == %{}
    cyc = "0\t0\t1\tprocess\t1\t2\tx\n0\t0\t1\tprocess\t2\t1\ty\n"
    assert Surfaces.parse_cmux_top(cyc) == %{}
  end

  test "map runs cmux top and degrades to %{}" do
    runner = fn "cmux-bin", ["top", "--all", "--processes", "--format", "tsv"] -> {@tsv, 0} end
    assert %{48717 => "surface:239"} = Surfaces.map(bin: "cmux-bin", runner: runner)

    assert Surfaces.map(bin: "cmux-bin", runner: fn _, _ -> {"boom", 1} end) == %{}
    assert Surfaces.map(bin: "cmux-bin", runner: fn _, _ -> raise "enoent" end) == %{}
    assert Surfaces.map(bin: nil) == %{}
  end

  test "cmux_bin honours CMUX_BIN" do
    old = System.get_env("CMUX_BIN")
    System.put_env("CMUX_BIN", "/opt/custom/cmux")

    try do
      assert Surfaces.cmux_bin() == "/opt/custom/cmux"
    after
      if old, do: System.put_env("CMUX_BIN", old), else: System.delete_env("CMUX_BIN")
    end
  end

  describe "scan/1 and cmux's access control" do
    @denied {"Error: ERROR: Access denied - only processes started inside cmux can connect", 1}

    test "on access denied, borrows a cmux process's capability and retries" do
      parent = self()
      calls = :counters.new(1, [])

      runner = fn _bin, _args ->
        :counters.add(calls, 1, 1)
        if :counters.get(calls, 1) == 1, do: @denied, else: {@tsv, 0}
      end

      env_of = fn
        111 -> "claude --resume x HOME=/h"
        222 -> "claude CMUX_SOCKET_CAPABILITY=v1.tok CMUX_SOCKET_PATH=/s/cmux.sock"
      end

      put_env = fn k, v -> send(parent, {:put_env, k, v}) end

      assert {:ok, %{48717 => "surface:239"}} =
               Surfaces.scan(
                 bin: "cmux-bin",
                 runner: runner,
                 pids: [111, 222],
                 env_of: env_of,
                 put_env: put_env
               )

      assert_received {:put_env, "CMUX_SOCKET_CAPABILITY", "v1.tok"}
      assert_received {:put_env, "CMUX_SOCKET_PATH", "/s/cmux.sock"}
    end

    test "says why when it cannot get in" do
      runner = fn _, _ -> @denied end

      assert Surfaces.scan(bin: "c", runner: runner, pids: [1], env_of: fn _ -> "" end) ==
               {:error, :denied}

      assert Surfaces.scan(bin: "c", runner: fn _, _ -> {"socket gone", 1} end) ==
               {:error, :failed}

      assert Surfaces.scan(bin: nil) == {:error, :no_cmux}
    end
  end

  describe "focus/2" do
    @tree Enum.join(
            [
              "1.0\t1\t3\tworkspace\tworkspace:8\twindow:1\tstudio",
              "1.0\t1\t3\tpane\tpane:8\tworkspace:8\t",
              "1.0\t1\t3\tsurface\tsurface:191\tpane:8\tWellness",
              "0.3\t1\t1\tprocess\t24343\tsurface:191\t2.1.327"
            ],
            "\n"
          )

    test "workspace_of walks surface → pane → workspace" do
      assert Surfaces.workspace_of(@tree, "surface:191") == "workspace:8"
      assert Surfaces.workspace_of(@tree, "surface:999") == nil
      assert Surfaces.workspace_of("", "surface:191") == nil
    end

    test "selects the surface's workspace, then focuses the surface" do
      parent = self()

      runner = fn "c", args ->
        send(parent, {:ran, args})
        if hd(args) == "top", do: {@tree, 0}, else: {"OK", 0}
      end

      assert Surfaces.focus("surface:191", bin: "c", runner: runner) == :ok
      assert_received {:ran, ["top", "--all", "--format", "tsv"]}
      assert_received {:ran, ["select-workspace", "--workspace", "workspace:8"]}

      assert_received {:ran,
                       ["focus-panel", "--panel", "surface:191", "--workspace", "workspace:8"]}
    end

    test "says why it could not" do
      top = fn _, _ -> {@tree, 0} end
      assert Surfaces.focus("surface:999", bin: "c", runner: top) == {:error, :surface_not_found}
      assert Surfaces.focus("surface:191", bin: nil) == {:error, :no_cmux}

      fail = fn
        _, ["top" | _] -> {@tree, 0}
        _, _ -> {"Error: nope\n", 1}
      end

      assert Surfaces.focus("surface:191", bin: "c", runner: fail) == {:error, "Error: nope"}
    end
  end
end
