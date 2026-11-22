defmodule Sprat.Roadmap.PositionProgressTest do
  use ExUnit.Case, async: true

  alias Sprat.Observer.Model.{Item, Phase, Roadmap}
  alias Sprat.Roadmap, as: RM
  alias Sprat.Roadmap.{Position, Progress}

  @now ~U[2026-11-23 12:00:00Z]

  defp rm(states_by_phase) do
    phases =
      for {{pid, states}, _} <- Enum.with_index(states_by_phase) do
        items =
          for {{text, state}, n} <- Enum.with_index(states, 1),
              do: %Item{id: "#{pid}.#{n}", text: text, state: state}

        %Phase{id: pid, title: "Phase #{pid}", items: items}
      end

    %Roadmap{phases: phases}
  end

  describe "Position.compute/3" do
    test "first phase with an undone item, its first open item, done/total" do
      r = rm([{"A", [{"a1", :done}]}, {"B", [{"b1", :done}, {"b2", :blocked}, {"b3", :todo}]}])
      p = Position.compute(r, [], @now)
      assert {p.phase_id, p.item_id, p.done, p.total, p.all_done?} == {"B", "B.3", 1, 3, false}
      assert p.last_progress_at == nil
      assert p.velocity == 0.0
    end

    test "a phase whose open items are all blocked points at the first blocked one" do
      p = Position.compute(rm([{"A", [{"a1", :done}, {"a2", :blocked}]}]), [], @now)
      assert {p.phase_id, p.item_id} == {"A", "A.2"}
    end

    test "all done" do
      p = Position.compute(rm([{"A", [{"a1", :done}, {"a2", :done}]}]), [], @now)
      assert p.all_done?
      assert {p.phase_id, p.done, p.total} == {nil, 2, 2}
    end

    test "last progress and velocity over 14 days of active days" do
      events = [
        %{kind: :tick, at: ~U[2026-11-22 10:00:00Z], item_id: "A.1"},
        %{kind: :tick, at: ~U[2026-11-22 11:00:00Z], item_id: "A.2"},
        %{kind: :commit, at: ~U[2026-11-20 09:00:00Z], item_id: nil},
        %{kind: :done, at: ~U[2026-11-20 10:00:00Z], item_id: "A.3"},
        # outside the window
        %{kind: :tick, at: ~U[2026-10-01 10:00:00Z], item_id: "A.4"},
        %{kind: :commit, at: ~U[2026-11-23 08:00:00Z], item_id: nil}
      ]

      p = Position.compute(rm([{"A", [{"a1", :todo}]}]), events, @now)
      assert p.last_progress_at == ~U[2026-11-23 08:00:00Z]
      assert p.last_progress_kind == :commit
      # 3 items done over 3 active days (20th, 22nd, 23rd)
      assert p.velocity == 1.0
    end
  end

  describe "Progress" do
    setup do
      r =
        rm([
          {"C",
           [
             {"schema + migration", :done},
             {"shared points ledger", :todo},
             {"network analytics", :todo}
           ]}
        ])

      r =
        update_in(r.phases, fn [p] ->
          [
            %{
              p
              | items:
                  p.items
                  |> List.update_at(1, &%{&1 | branch: "cafe-networks"})
                  |> List.update_at(
                    2,
                    &%{&1 | hints: ["Network analytics: stamps given vs rewards served"]}
                  )
            }
          ]
        end)

      %{rm: r}
    end

    test "from_git binds by branch, then quoted commit message, then text", %{rm: r} do
      commits = [
        %{
          sha: "a1",
          at: ~U[2026-11-20 10:00:00Z],
          subject: "Ledger rows",
          branches: ["cafe-networks"]
        },
        %{
          sha: "b2",
          at: ~U[2026-11-20 11:00:00Z],
          subject: "Network analytics: stamps given vs rewards served"
        },
        %{
          sha: "c3",
          at: ~U[2026-11-20 12:00:00Z],
          subject: "Schema + migration for networks",
          branches: []
        },
        %{
          sha: "d4",
          at: ~U[2026-11-20 13:00:00Z],
          subject: "Unrelated typo fix",
          branches: ["main"]
        }
      ]

      assert Enum.map(Progress.from_git(commits, r), &{&1.ref, &1.item_id, &1.kind}) == [
               {"a1", "C.2", :commit},
               {"b2", "C.3", :commit},
               {"c3", "C.1", :commit},
               {"d4", nil, :commit}
             ]

      assert Progress.completed_by(commits, r) == ["C.3"]
    end

    test "diff_ticks reports items that went to done", %{rm: old} do
      new =
        update_in(old.phases, fn [p] ->
          [%{p | items: List.update_at(p.items, 1, &%{&1 | state: :done})}]
        end)

      assert Progress.diff_ticks(old, new, @now) == [
               %{kind: :tick, at: @now, item_id: "C.2", ref: "C.2"}
             ]

      assert Progress.diff_ticks(new, new, @now) == []
      assert Progress.diff_ticks(nil, new, @now) == []
    end
  end

  test "unblocked/1 lists the active phase's open items in order" do
    r =
      rm([
        {"A", [{"a", :done}]},
        {"B", [{"b1", :blocked}, {"b2", :todo}, {"b3", :active}, {"b4", :done}]}
      ])

    assert Enum.map(RM.unblocked(r), & &1.id) == ["B.2", "B.3"]
    assert RM.unblocked(rm([{"A", [{"a", :done}]}])) == []
  end
end
