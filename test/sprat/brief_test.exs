defmodule Sprat.BriefTest do
  use ExUnit.Case, async: true

  alias Sprat.Brief
  alias Sprat.Observer.Model.{Finding, Position, Project, Served}

  @now ~U[2026-11-23 09:00:00Z]

  defp ago(min), do: DateTime.add(@now, -min * 60)

  defp fixture do
    projects = [
      %Project{
        root: "/p/cupful",
        name: "cupful",
        position: %Position{phase_id: "C", done: 3, total: 9}
      },
      %Project{
        root: "/p/liftlog-ios",
        name: "liftlog-ios",
        position: %Position{phase_id: "B", done: 5, total: 10}
      },
      %Project{
        root: "/p/liftlog",
        name: "liftlog",
        position: %Position{phase_id: "A", done: 7, total: 10}
      },
      %Project{
        root: "/p/dreamboard",
        name: "dreamboard",
        position: %Position{phase_id: "2", done: 2, total: 8}
      },
      %Project{
        root: "/p/fieldnotes",
        name: "fieldnotes",
        position: %Position{
          all_done?: true,
          done: 5,
          total: 5,
          last_progress_at: ago(9 * 24 * 60)
        }
      },
      %Project{root: "/p/old", name: "old", archived?: true}
    ]

    findings = [
      %Finding{
        id: "W1-1",
        rule: "W1",
        kind: :needs_you,
        project_root: "/p/cupful",
        session_id: "s-cafe",
        summary: "waiting on you: keep the old network_id column?",
        first_seen_at: ago(18)
      },
      %Finding{
        id: "L1-2",
        rule: "L1",
        kind: :stuck,
        state: :escalated,
        project_root: "/p/liftlog-ios",
        summary: "signing cert missing, sprat moved the agent to B.5; import the cert",
        first_seen_at: ago(40)
      },
      %Finding{
        id: "P1-3",
        rule: "P1",
        kind: :stalled,
        project_root: "/p/dreamboard",
        summary: "roadmap stalled 2 days at 2.3 onboarding copy",
        first_seen_at: ago(60)
      },
      %Finding{
        id: "L3-4",
        rule: "L3",
        kind: :stuck,
        state: :dismissed,
        project_root: "/p/liftlog",
        summary: "x"
      }
    ]

    served = [
      %Served{at: ago(15 * 60), project_name: "liftlog", text: "merch checkout done"}
    ]

    %{
      now: @now,
      projects: projects,
      findings: findings,
      served: served,
      pm_spend: 2.4,
      done_yesterday: 4,
      nudges: %{delivered: 6, resolved: 5},
      session_names: %{"s-cafe" => "cafe-networks-4b"}
    }
  end

  test "composes the spec's brief shape" do
    assert Brief.compose(fixture()) == """
           brief · mon 23 nov · 5 projects · 4 items done yesterday · 6 nudges, 5 resolved · pm $2.40

           cupful: C 3/9; you: cafe-networks-4b waiting on you: keep the old network_id column? (18m)
           liftlog-ios: B 5/10; you: signing cert missing, sprat moved the agent to B.5; import the cert
           dreamboard: 2 2/8; roadmap stalled 2 days at 2.3 onboarding copy
           liftlog: A 7/10; merch checkout done; on course
           fieldnotes: done 9 days ago

           net: 2 decisions for you, 1 stuck, 1 moving
           """
  end

  test "deterministic regardless of input order" do
    f = fixture()
    shuffled = %{f | projects: Enum.reverse(f.projects), findings: Enum.reverse(f.findings)}
    assert Brief.compose(f) == Brief.compose(shuffled)
  end

  test "leaves out header numbers the input does not hold" do
    out =
      Brief.compose(%{
        now: @now,
        projects: [%Project{root: "/x", name: "studio"}],
        findings: [],
        served: [],
        pm_spend: nil
      })

    assert out == """
           brief · mon 23 nov · 1 project

           studio: no roadmap yet

           net: nothing open
           """
  end
end
