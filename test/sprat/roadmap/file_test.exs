defmodule Sprat.Roadmap.FileTest do
  use ExUnit.Case, async: true

  alias Sprat.Observer.Model.{Item, Phase, Roadmap}
  alias Sprat.Roadmap.File, as: RFile

  @fixture Path.expand("../../fixtures/v4/roadmap/sprat_roadmap.md", __DIR__)

  test "parses the §5.2 format" do
    rm = RFile.parse(File.read!(@fixture))
    assert rm.name == "cupful"
    assert rm.goal == "Cafe networks share one loyalty balance across venues"
    assert rm.due == ~D[2026-12-15]
    assert rm.confirmed?

    [c, d] = rm.phases

    assert {c.id, c.title, c.source} ==
             {"C", "Cafe networks", "docs/superpowers/plans/2026-11-14-cafe-networks.md"}

    assert Enum.map(c.items, & &1.id) == ~w(C.1 C.2 C.3 C.4 C.5 C.6)
    assert Enum.map(c.items, & &1.state) == [:done, :done, :done, :todo, :todo, :todo]
    assert Enum.at(c.items, 3).branch == "cafe-networks"
    assert Enum.at(c.items, 3).text == "shared points ledger"

    assert [
             %Item{id: "D.1", branch: "tv-venue-leaderboard"},
             %Item{id: "D.2", state: :blocked} = blocked
           ] = d.items

    assert blocked.blocked_reason == "needs the TV vendor's API key"
    refute Enum.any?(c.items ++ d.items, & &1.owner_edited?)
  end

  test "render ∘ parse is the identity on the fixture" do
    text = File.read!(@fixture)
    assert RFile.render(RFile.parse(text)) == text
  end

  test "owner_edited? is computed from the sidecar's hashes" do
    text = File.read!(@fixture)
    rm = RFile.parse(text)
    state = RFile.state(rm, ~U[2026-11-20 10:00:00Z])
    known = RFile.known_hashes(JSON.encode!(state))

    edited =
      String.replace(
        text,
        "- [ ] cross-cafe redemption",
        "- [ ] cross-cafe redemption (owner's words)"
      )

    rm2 = RFile.parse(edited, known)
    flags = for p <- rm2.phases, it <- p.items, do: {it.id, it.owner_edited?}
    assert {"C.5", true} in flags
    assert Enum.count(flags, &elem(&1, 1)) == 1

    # an owner-added line has no hash either
    added =
      String.replace(text, "- [ ] network analytics", "- [ ] network analytics\n- [ ] a new idea")

    assert Enum.any?(
             RFile.parse(added, known).phases |> hd() |> Map.get(:items),
             &(&1.text == "a new idea" and &1.owner_edited?)
           )
  end

  test "owner-edited lines are left out of the sidecar, so they stay the owner's" do
    rm = %Roadmap{
      name: "x",
      phases: [
        %Phase{
          id: "A",
          title: "T",
          items: [
            %Item{id: "A.1", text: "mine", owner_edited?: true},
            %Item{id: "A.2", text: "sprat's"}
          ]
        }
      ]
    }

    assert %{"lines" => lines} = RFile.state(rm, ~U[2026-11-20 10:00:00Z])
    assert Map.keys(lines) == ["A.2"]
  end

  test "a heading without an id gets a letter; [active] is computed on render" do
    rm =
      RFile.parse(
        "# Roadmap: p\n\n## Just a title\n\n- [x] one\n- [ ] two\n\n## Next\n\n- [ ] three\n"
      )

    assert Enum.map(rm.phases, & &1.id) == ["A", "B"]
    out = RFile.render(rm)
    assert out =~ "## A · Just a title  [active]"
    assert out =~ "## B · Next\n"
  end
end
