defmodule Sprat.Roadmap.BuildTest do
  use ExUnit.Case, async: true

  alias Sprat.Observer.Model.{Item, Phase, Roadmap}
  alias Sprat.Roadmap, as: RM
  alias Sprat.Roadmap.{Position, Sources}
  alias Sprat.Roadmap.File, as: RFile

  @fixtures Path.expand("../../fixtures/v4/roadmap", __DIR__)
  @now ~U[2026-11-23 12:00:00Z]

  defp put(root, rel, content, mtime \\ {{2026, 11, 1}, {12, 0, 0}}) do
    path = Path.join(root, rel)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, content)
    File.touch!(path, mtime)
    path
  end

  defp fixture(name), do: File.read!(Path.join(@fixtures, name))

  defp plan(title, tasks) do
    body =
      Enum.map_join(Enum.with_index(tasks, 1), "\n", fn {{text, done?}, n} ->
        box = if done?, do: "[x]", else: "[ ]"

        "### Task #{n}: #{text}\n\n- #{box} **Step 1: Do it**\n- #{box} **Step 2: Commit** `#{text} landed`\n"
      end)

    "# #{title} Implementation Plan\n\n" <> body
  end

  @tag :tmp_dir
  test "Sources.discover follows §5.1's order; globs are overridable", %{tmp_dir: root} do
    put(root, "docs/spec-v2.md", "# s")
    put(root, "ROADMAP.md", "# r")
    put(root, "docs/superpowers/plans/2026-11-01-a.md", "# a", {{2026, 11, 1}, {0, 0, 0}})
    put(root, "docs/superpowers/plans/2026-11-05-b.md", "# b", {{2026, 11, 5}, {0, 0, 0}})
    put(root, "docs/PAUSE.md", "# p")
    put(root, ".sprat/roadmap.md", "# Roadmap: x")
    put(root, "notes/unrelated.md", "# n")

    assert Enum.map(Sources.discover(root), &{&1.kind, &1.path}) == [
             {:sprat, ".sprat/roadmap.md"},
             {:pause, "docs/PAUSE.md"},
             {:plan, "docs/superpowers/plans/2026-11-05-b.md"},
             {:plan, "docs/superpowers/plans/2026-11-01-a.md"},
             {:plan, "ROADMAP.md"},
             {:spec, "docs/spec-v2.md"}
           ]

    assert [%{kind: :plan, path: "notes/unrelated.md", mtime: %DateTime{}}] =
             Sources.discover(root, globs: [plan: "notes/*.md"])
  end

  @tag :tmp_dir
  test "a proposal: PAUSE.md first, open plans newest first, done plans collapsed as history", %{
    tmp_dir: root
  } do
    put(root, "docs/PAUSE.md", fixture("pause_resume.md"))

    put(
      root,
      "docs/superpowers/plans/2026-10-01-old.md",
      plan("Old Thing", [{"one", true}, {"two", true}])
    )

    put(
      root,
      "docs/superpowers/plans/2026-11-10-new.md",
      plan("New Thing", [{"alpha", true}, {"beta", false}])
    )

    put(root, "docs/superpowers/plans/2026-11-01-mid.md", plan("Mid Thing", [{"gamma", false}]))
    put(root, "docs/spec.md", fixture("spec_phases.md"), {{2026, 10, 15}, {0, 0, 0}})

    rm = RM.build(root, now: @now)

    assert %Roadmap{confirmed?: false, inferred?: false, name: name} = rm
    assert name == Path.basename(root)

    assert Enum.map(rm.phases, &{&1.id, &1.title}) == [
             {"C", "Old Thing"},
             {"D", "Resume (PAUSE.md)"},
             {"E", "New Thing"},
             {"F", "Mid Thing"},
             {"0", "spikes (days)"},
             {"A", "The board, read-only"},
             {"B", "Findings"},
             {"3", "Hardening"}
           ]

    assert [%Item{id: "C.1", text: "Old Thing", state: :done}] = hd(rm.phases).items

    pos = Position.compute(rm, [], @now)
    assert {pos.phase_id, pos.item_id} == {"D", "D.1"}
    assert pos.item_text == "Ask the owner the open decision below"

    assert rm.pause.written_on == ~D[2026-09-13]
    assert rm.pause.updated_on == ~D[2026-09-20]
    assert rm.pause.repo_state =~ "ingest"

    assert "PAUSE.md last updated 2026-09-20 (64 days ago)" in rm.notes

    assert Enum.any?(
             rm.notes,
             &(&1 =~ "PAUSE.md predates docs/superpowers/plans/2026-11-10-new.md")
           )

    assert Enum.any?(
             rm.notes,
             &(&1 =~ ~s(PAUSE.md puts the position at "Ask the owner) and
                 &1 =~ ~s(New Thing: "beta"))
           )

    assert "docs/PAUSE.md" in rm.sources
    assert "docs/spec.md" in rm.sources
  end

  @tag :tmp_dir
  test "only the most recent plans count", %{tmp_dir: root} do
    for d <- 1..8 do
      day = String.pad_leading("#{d}", 2, "0")
      put(root, "docs/plans/2026-11-#{day}-p#{d}.md", plan("P#{d}", [{"x#{d}", false}]))
    end

    rm = RM.build(root, now: @now)
    assert Enum.map(rm.phases, & &1.title) == ~w(P8 P7 P6 P5 P4 P3)
    assert "2 older plan file(s) not counted (only the 6 most recent are)" in rm.notes
    assert length(RM.build(root, max_plans: 2).phases) == 2
  end

  @tag :tmp_dir
  test "commits that match a plan's quoted message mark the task done", %{tmp_dir: root} do
    put(root, "docs/plans/2026-11-10-x.md", plan("X", [{"alpha", false}, {"beta", false}]))
    commits = [%{sha: "1", at: ~U[2026-11-11 10:00:00Z], subject: "Alpha landed", branches: []}]

    [phase] = RM.build(root, commits: commits).phases
    assert Enum.map(phase.items, & &1.state) == [:done, :todo]

    commits =
      commits ++
        [%{sha: "2", at: ~U[2026-11-12 10:00:00Z], subject: "beta landed.", branches: []}]

    assert [%Phase{items: [%Item{text: "X", state: :done}]}] =
             RM.build(root, commits: commits).phases
  end

  @tag :tmp_dir
  test "a ROADMAP.md shipped line that links a plan marks that plan done", %{tmp_dir: root} do
    put(root, "ROADMAP.md", fixture("roadmap_status.md"), {{2026, 11, 20}, {0, 0, 0}})

    put(
      root,
      "docs/superpowers/plans/2026-11-12-admin-mcp.md",
      plan("Admin MCP", [{"keys", false}])
    )

    rm = RM.build(root)
    assert [%Phase{title: "Admin MCP", items: [%Item{state: :done}]} | _] = rm.phases
    pos = Position.compute(rm, [], @now)
    assert {pos.phase_title, pos.item_text} == {"Designed, not built", "Social layer"}
  end

  @tag :tmp_dir
  test "unstructured docs go to infer_fun; the default infers nothing", %{tmp_dir: root} do
    put(root, "TODO.md", "We should build the export, then the import.\n")

    assert %Roadmap{phases: [], inferred?: false} = RM.build(root)

    infer = fn text ->
      assert text =~ "export"

      [
        %Phase{
          id: nil,
          title: "Data",
          items: [%Item{id: nil, text: "export"}, %Item{id: nil, text: "import"}]
        }
      ]
    end

    rm = RM.build(root, infer_fun: infer)
    assert rm.inferred?

    assert [%Phase{id: "A", source: "TODO.md", items: [%Item{id: "A.1", source: "TODO.md"}, _]}] =
             rm.phases
  end

  @tag :tmp_dir
  test "write, then re-sync: sources update Sprat's lines, owner edits win", %{tmp_dir: root} do
    src = "docs/plans/2026-11-10-x.md"
    put(root, src, plan("X", [{"alpha", false}, {"beta", false}, {"gamma", false}]))

    proposal = RM.build(root)
    assert :ok = RM.write(proposal, root)
    assert File.exists?(RFile.state_path(root))

    confirmed = RM.build(root)
    assert confirmed.confirmed?
    assert ".sprat/roadmap.md" in confirmed.sources

    assert Enum.map(hd(confirmed.phases).items, &{&1.text, &1.state, &1.owner_edited?}) ==
             [{"alpha", :todo, false}, {"beta", :todo, false}, {"gamma", :todo, false}]

    # the owner rewrites beta's line by hand
    file = File.read!(RFile.path(root))

    File.write!(
      RFile.path(root),
      String.replace(file, "- [ ] beta", "- [ ] beta, but only the API half")
    )

    # the source plan ticks alpha and renames gamma
    put(
      root,
      src,
      plan("X", [{"alpha", true}, {"beta (renamed in plan)", false}, {"gamma two", false}])
    )

    rm = RM.build(root)

    assert Enum.map(hd(rm.phases).items, &{&1.id, &1.text, &1.state, &1.owner_edited?}) == [
             {"A.1", "alpha", :done, false},
             {"A.2", "beta, but only the API half", :todo, true},
             {"A.3", "gamma two", :todo, false}
           ]
  end

  @tag :tmp_dir
  test "a confirmed roadmap notes what PAUSE.md says instead of adopting it", %{tmp_dir: root} do
    put(root, "docs/plans/2026-11-10-x.md", plan("X", [{"alpha", false}]))
    RM.write(RM.build(root), root)
    put(root, "docs/PAUSE.md", fixture("pause_continue.md"))

    rm = RM.build(root, now: @now)
    assert Enum.map(rm.phases, & &1.title) == ["X"]
    assert ~s(PAUSE.md says next: "Logo v2"; the roadmap's position is A.1 "alpha") in rm.notes
  end

  @tag :tmp_dir
  test "mark and revert", %{tmp_dir: root} do
    File.mkdir_p!(Path.join(root, ".sprat"))
    File.write!(RFile.path(root), fixture("sprat_roadmap.md"))

    assert {:ok, rec} = RM.mark(root, "C.4", :blocked, "needs the Stripe key", now: @now)

    assert rec == %{
             item_id: "C.4",
             from: :todo,
             to: :blocked,
             reason: "needs the Stripe key",
             from_reason: nil,
             at: @now
           }

    assert File.read!(RFile.path(root)) =~
             "- [ ] shared points ledger  <!-- branch: cafe-networks -->  <!-- blocked: needs the Stripe key -->"

    rm = RM.build(root)
    assert RM.find_item(rm, "C.4").state == :blocked
    assert Enum.map(RM.unblocked(rm), & &1.id) == ["C.5", "C.6"]

    assert {:ok, %{item_id: "C.4", from: :blocked, to: :todo}} = RM.revert(root, rec)
    assert RM.find_item(RM.build(root), "C.4").state == :todo
    assert {:error, {:changed, :todo}} = RM.revert(root, rec)

    assert {:ok, done} = RM.mark(root, "D.2", :done, nil)
    assert done.from_reason == "needs the TV vendor's API key"
    assert {:ok, _} = RM.revert(root, done)

    assert %Item{state: :blocked, blocked_reason: "needs the TV vendor's API key"} =
             RM.find_item(RM.build(root), "D.2")

    assert {:error, :not_found} = RM.mark(root, "Z.9", :done, nil)
  end

  @tag :tmp_dir
  test "mark keeps an owner-edited line the owner's", %{tmp_dir: root} do
    put(root, "docs/plans/2026-11-10-x.md", plan("X", [{"alpha", false}]))
    RM.write(RM.build(root), root)

    File.write!(
      RFile.path(root),
      String.replace(File.read!(RFile.path(root)), "- [ ] alpha", "- [ ] alpha, my way")
    )

    assert {:ok, _} = RM.mark(root, "A.1", :done, nil)
    item = RM.find_item(RM.build(root), "A.1")
    assert {item.text, item.state, item.owner_edited?} == {"alpha, my way", :done, true}
  end

  @tag :tmp_dir
  test "mark with no roadmap file writes the proposal first", %{tmp_dir: root} do
    put(root, "docs/plans/2026-11-10-x.md", plan("X", [{"alpha", false}, {"beta", false}]))

    assert {:ok, %{from: :todo, to: :blocked}} =
             RM.mark(root, "A.1", :blocked, "waiting on design")

    assert File.read!(RFile.path(root)) =~ "<!-- blocked: waiting on design -->"
    assert RM.build(root).confirmed?
  end

  @tag :tmp_dir
  test "an empty project builds an empty roadmap", %{tmp_dir: root} do
    rm = RM.build(root)
    assert %Roadmap{phases: [], sources: [], confirmed?: false, pause: nil, notes: []} = rm
    assert %{all_done?: false, phase_id: nil} = Position.compute(rm, [], @now)
  end
end
