defmodule Sprat.Observer.RoadmapCacheTest do
  use ExUnit.Case, async: true

  alias Sprat.Observer.RoadmapCache

  setup do
    root = Path.join(System.tmp_dir!(), "sprat-rc-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    File.write!(Path.join(root, "ROADMAP.md"), "# Roadmap\n\n## A. First\n\n- [ ] one\n")
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root}
  end

  test "reloads at most every ten minutes while the sources are unchanged", %{root: root} do
    t0 = ~U[2026-11-24 10:00:00Z]
    e1 = RoadmapCache.current(nil, root, t0)
    assert e1.at == t0

    # Within ten minutes: the same entry.
    assert RoadmapCache.current(e1, root, DateTime.add(t0, 300)) == e1

    # After ten minutes: reloaded, and the clock restarts (V4 kept the old
    # time, so every later tick reloaded from git again).
    later = DateTime.add(t0, 601)
    e2 = RoadmapCache.current(e1, root, later)
    assert e2.at == later
    assert RoadmapCache.current(e2, root, DateTime.add(later, 60)) == e2
  end

  test "a changed source reloads at once", %{root: root} do
    t0 = ~U[2026-11-24 10:00:00Z]
    e1 = RoadmapCache.current(nil, root, t0)

    File.write!(
      Path.join(root, "ROADMAP.md"),
      "# Roadmap\n\n## A. First\n\n- [x] one\n- [ ] two\n"
    )

    File.touch!(Path.join(root, "ROADMAP.md"), System.os_time(:second) + 5)
    e2 = RoadmapCache.current(e1, root, DateTime.add(t0, 10))
    assert e2.sig != e1.sig
    assert e2.at == DateTime.add(t0, 10)
  end
end
