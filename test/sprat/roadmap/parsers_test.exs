defmodule Sprat.Roadmap.ParsersTest do
  use ExUnit.Case, async: true

  alias Sprat.Roadmap.Parser.{Pause, Plan, Spec}

  @fixtures Path.expand("../../fixtures/v4/roadmap", __DIR__)
  defp fixture(name), do: File.read!(Path.join(@fixtures, name))

  describe "Plan, task plans" do
    setup do
      %{result: Plan.parse(fixture("plan_tasks.md"), source: "docs/plans/x.md")}
    end

    test "the file is one phase and each task one item, not one per step", %{result: r} do
      assert r.mode == :tasks
      assert [phase] = r.phases
      assert phase.title == "Cafe Networks"
      assert phase.source == "docs/plans/x.md"

      assert Enum.map(phase.items, & &1.text) == [
               "Schema and migration",
               "Loyalty.Networks context",
               "Deal resolution at member venues",
               "Full gate"
             ]
    end

    test "a task is done only when every step outside code fences is ticked", %{result: r} do
      [phase] = r.phases
      assert Enum.map(phase.items, & &1.state) == [:done, :todo, :todo, :todo]
    end

    test "items carry their source line and the commit messages the plan quotes", %{result: r} do
      [phase] = r.phases
      [t1, t2, t3, _] = phase.items
      assert t1.source_line == 11
      assert t1.hints == ["Add cafe network schemas: kind, memberships"]
      assert t2.hints == ["feat(networks): found, invite, approve"]
      assert t3.hints == ["Network card rules: one stamp per cafe per day"]
    end
  end

  describe "Plan, checkbox plans" do
    setup do
      %{result: Plan.parse(fixture("plan_checkbox.md"), source: "TODO.md")}
    end

    test "each heading with checkboxes is a phase; headings without are skipped", %{result: r} do
      assert r.mode == :checkbox
      assert Enum.map(r.phases, & &1.title) == ["Backend", "Website"]
    end

    test "nested checkboxes fold into their parent; * and numbered boxes count", %{result: r} do
      [backend, website] = r.phases

      assert Enum.map(backend.items, &{&1.text, &1.state}) == [
               {"Schema and migration", :done},
               {"Admin CRUD", :done},
               {"Shared points ledger", :todo},
               {"Cross-cafe redemption", :todo}
             ]

      assert Enum.map(website.items, &{&1.text, &1.state}) == [
               {"Landing page", :todo},
               {"Pricing page", :done}
             ]

      assert hd(backend.items).source_line == 7
    end
  end

  describe "Plan, status lists" do
    test "status headings over bullets, only when asked" do
      text = fixture("roadmap_status.md")
      assert %{mode: :none, phases: []} = Plan.parse(text, source: "ROADMAP.md")

      r = Plan.parse(text, source: "ROADMAP.md", status_lists: true)
      assert r.mode == :status

      assert Enum.map(r.phases, & &1.title) == [
               "Shipped",
               "Designed, not built",
               "Owed before launch"
             ]

      [shipped, designed, owed] = r.phases

      assert Enum.map(shipped.items, &{&1.text, &1.state}) == [
               {"Admin MCP server", :done},
               {"v1 core", :done}
             ]

      assert hd(shipped.items).hints == ["docs/superpowers/plans/2026-11-12-admin-mcp.md"]
      assert Enum.all?(designed.items, &(&1.state == :todo))
      assert Enum.map(owed.items, & &1.text) == ["Physical-device passes.", "Store listing"]
    end
  end

  describe "Pause" do
    test "the resume list, in order, with the first open item active" do
      r = Pause.parse(fixture("pause_resume.md"), source: "docs/PAUSE.md")
      assert r.title == "Paused 2026-09-13 12:46 BST · widgets (Acme)"
      assert r.written_on == ~D[2026-09-13]
      assert r.updated_on == ~D[2026-09-20]
      assert r.repo_state =~ "Branch `ingest`"

      assert Enum.map(r.items, &{&1.text, &1.state}) == [
               {"Ask the owner the open decision below", :active},
               {"Update the draft reply", :todo},
               {"If the prod backfill is approved: back up prod first, then run widgets:backfill APPLY=1.",
                :todo},
               {"Import the remaining 18 files", :blocked},
               {"Add the lint comment", :todo}
             ]

      blocked = Enum.at(r.items, 3)
      assert blocked.blocked_reason == "Blocked — see Deferred and blocked."
      assert hd(r.items).source_line == 14
      assert hd(r.items).source == "docs/PAUSE.md"
    end

    test "the handover shape: Continue, in order; State; done tags; nested bullets" do
      r = Pause.parse(fixture("pause_continue.md"), source: "docs/PAUSE.md")
      assert r.written_on == ~D[2026-11-09]
      assert r.repo_state =~ "app_ios"

      assert Enum.map(r.items, &{&1.text, &1.state}) == [
               {"Logo v2", :active},
               {"Make it the icon", :todo},
               {"Health build on the phone", :blocked},
               {"Barcode lookup", :done},
               {"Roadmap", :todo}
             ]

      assert Enum.at(r.items, 2).blocked_reason ==
               "Blocked on the user signing back into Xcode (Settings, Accounts, owner@example.com)."
    end

    test "no resume section: no items, no crash" do
      assert %{items: [], written_on: nil} = Pause.parse("just some notes\n")
    end
  end

  describe "Spec" do
    setup do
      %{phases: Spec.parse(fixture("spec_phases.md"), source: "docs/spec.md")}
    end

    test "bold phases inside the build sequence and Phase headings anywhere", %{phases: phases} do
      assert Enum.map(phases, &{&1.id, &1.title}) == [
               {"0", "spikes (days)"},
               {"A", "The board, read-only"},
               {"B", "Findings"},
               {"3", "Hardening"}
             ]
    end

    test "numbered items become items; a phase without them is one item", %{phases: phases} do
      [p0, pa, _pb, p3] = phases

      assert Enum.map(p0.items, & &1.text) == [
               "Transcript shapes: golden files from real transcripts; a parser that fails loudly.",
               "Peer delivery: can a message reach a live session."
             ]

      assert [%{text: "The board, read-only", state: :todo}] = pa.items
      assert Enum.map(p3.items, & &1.text) == ["Fuzz the parsers", "Load test"]

      assert Enum.all?(phases, fn p ->
               Enum.all?(p.items, &(&1.source == "docs/spec.md" and &1.source_line))
             end)
    end
  end
end
