defmodule Sprat.Observer.ConfigDirsTest do
  use ExUnit.Case, async: true

  alias Sprat.Observer.ConfigDirs

  @moduletag :tmp_dir

  test "~/.claude plus ~/.claude-* dirs with sessions/ or projects/", %{tmp_dir: home} do
    File.mkdir_p!(Path.join(home, ".claude/sessions"))
    File.mkdir_p!(Path.join(home, ".claude-work/projects"))
    File.mkdir_p!(Path.join(home, ".claude-alt/sessions"))
    File.mkdir_p!(Path.join(home, ".claude-flow"))
    File.write!(Path.join(home, ".claude-msg.json"), "{}")

    assert ConfigDirs.list(home: home, env: nil, processes: [], memory: nil) == [
             Path.join(home, ".claude"),
             Path.join(home, ".claude-alt"),
             Path.join(home, ".claude-work")
           ]
  end

  test "a dir whose sessions/ symlinks into another is dropped", %{tmp_dir: home} do
    File.mkdir_p!(Path.join(home, ".claude/sessions"))
    File.mkdir_p!(Path.join(home, ".claude/projects"))
    File.mkdir_p!(Path.join(home, ".claude-alias"))
    File.ln_s!(Path.join(home, ".claude/sessions"), Path.join(home, ".claude-alias/sessions"))
    File.ln_s!(Path.join(home, ".claude/projects"), Path.join(home, ".claude-alias/projects"))

    assert ConfigDirs.list(home: home, env: nil, processes: [], memory: nil) == [
             Path.join(home, ".claude")
           ]

    # ...but it is still its own login, with its own usage limit.
    assert ConfigDirs.accounts(home: home, env: nil, processes: [], memory: nil) == [
             Path.join(home, ".claude"),
             Path.join(home, ".claude-alias")
           ]
  end

  test "SPRAT_CLAUDE_DIRS overrides discovery", %{tmp_dir: home} do
    File.mkdir_p!(Path.join(home, ".claude/sessions"))
    a = Path.join(home, "a")
    b = Path.join(home, "b")
    File.mkdir_p!(a)
    File.mkdir_p!(b)

    assert ConfigDirs.list(
             home: home,
             processes: [],
             memory: nil,
             env: "#{a}:#{b}::#{Path.join(home, "missing")}"
           ) == [a, b]

    assert ConfigDirs.list(home: home, processes: [], memory: nil, env: "") == [
             Path.join(home, ".claude")
           ]
  end

  test "no dirs at all", %{tmp_dir: home} do
    assert ConfigDirs.list(home: home, env: nil, processes: [], memory: nil) == []
  end

  test "a config dir a running process uses is found wherever it lives", %{tmp_dir: home} do
    File.mkdir_p!(Path.join(home, ".claude/sessions"))
    elsewhere = Path.join(home, "work/claude-config")
    File.mkdir_p!(Path.join(elsewhere, "projects"))
    not_claude = Path.join(home, "empty")
    File.mkdir_p!(not_claude)

    assert ConfigDirs.list(
             home: home,
             env: nil,
             processes: [elsewhere, not_claude, Path.join(home, "missing")],
             memory: nil
           ) == [Path.join(home, ".claude"), elsewhere]
  end

  test "dirs found from processes are remembered after they exit", %{tmp_dir: home} do
    File.mkdir_p!(Path.join(home, ".claude/sessions"))
    elsewhere = Path.join(home, "work/claude-config")
    File.mkdir_p!(Path.join(elsewhere, "sessions"))
    memory = Path.join(home, "data/claude-dirs")

    assert ConfigDirs.list(home: home, env: nil, processes: [elsewhere], memory: memory) ==
             [Path.join(home, ".claude"), elsewhere]

    assert ConfigDirs.list(home: home, env: nil, processes: [], memory: memory) ==
             [Path.join(home, ".claude"), elsewhere]
  end
end
