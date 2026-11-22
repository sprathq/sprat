defmodule Sprat.Terminal.Board.Fixture do
  @moduledoc """
  Demo data for the Pass, matching the examples in `docs/spec-v4.md` §10:
  nine projects, two yours tickets, three sprat tickets, a day of served
  lines and one session's condensed transcript. Every time is relative to
  `now`, so the board reads the same whenever it is rendered.
  """

  alias Sprat.Observer.Model.{
    Account,
    Decision,
    Finding,
    Item,
    Phase,
    Position,
    Project,
    Roadmap,
    Served,
    Session,
    Ticket
  }

  @home "/Users/owner/Projects"
  @main "/Users/owner/.claude"
  @forge "/Users/owner/.claude-work"

  @doc "A full snapshot as `Sprat.Terminal.Board.View.put_snapshot/2` takes it."
  def snapshot(now \\ DateTime.utc_now()) do
    now = DateTime.truncate(now, :second)
    ago = fn minutes -> DateTime.add(now, -minutes * 60, :second) end

    %{
      now: now,
      utc_offset: 0,
      projects: projects(ago),
      tickets: tickets(ago),
      served: served(ago),
      header: %{
        pm_spend: Decimal.new("2.40"),
        fleet_cap: 15,
        limited_accounts: [
          %Account{
            config_dir: @forge,
            limited_until: DateTime.add(now, 68 * 60, :second),
            limit_kind: :five_hour,
            limit_text: "5-hour limit reached"
          }
        ]
      },
      settings: %{age_thresholds: %{"L1" => 10, "W1" => 15, "P2" => 60 * 24, default: 15}},
      session_lines: %{"cf-4b" => session_lines(ago)}
    }
  end

  defp root(name), do: Path.join(@home, name)

  defp session(id, name, status, ago, opts) do
    %Session{
      session_id: id,
      config_dir: Keyword.get(opts, :config_dir, @main),
      name: name,
      live?: status != :ended,
      status: status,
      status_since: ago.(Keyword.get(opts, :since, 5)),
      last_activity_at: ago.(Keyword.get(opts, :active, 2)),
      branch: Keyword.get(opts, :branch, name),
      title: Keyword.get(opts, :title),
      worktree?: true
    }
  end

  defp items(prefix, texts, done, active_state \\ :active) do
    texts
    |> Enum.with_index(1)
    |> Enum.map(fn {text, i} ->
      state =
        cond do
          i <= done -> :done
          i == done + 1 -> active_state
          true -> :todo
        end

      %Item{id: "#{prefix}.#{i}", text: text, state: state}
    end)
  end

  defp projects(ago) do
    [
      %Project{
        root: root("cupful"),
        name: "cupful",
        config_dirs: [@main],
        autonomy: :act,
        roadmap: %Roadmap{
          confirmed?: true,
          sources: ["plans/2026-11-14-cafe-networks.md", "docs/PAUSE.md", "git"],
          phases: [
            %Phase{id: "A", title: "Loyalty core", items: items("A", List.duplicate("x", 8), 8)},
            %Phase{id: "B", title: "Wallet passes", items: items("B", List.duplicate("x", 5), 5)},
            %Phase{
              id: "C",
              title: "Cafe networks",
              items:
                items(
                  "C",
                  [
                    "schema + migration",
                    "network admin CRUD",
                    "member join flow",
                    "shared points ledger",
                    "cross-cafe redemption",
                    "network analytics",
                    "network billing",
                    "invite links",
                    "docs"
                  ],
                  3
                )
                |> List.update_at(3, &%{&1 | branch: "cafe-networks-4b"})
            },
            %Phase{
              id: "D",
              title: "TV signage",
              items: items("D", List.duplicate("x", 6), 0, :todo)
            }
          ]
        },
        position: %Position{
          phase_id: "C",
          phase_title: "Cafe networks",
          item_id: "C.4",
          item_text: "shared points ledger",
          done: 3,
          total: 9,
          last_progress_at: ago.(50),
          velocity: 1.2
        },
        sessions: [
          session("cf-4b", "cafe-networks-4b", :idle, ago, since: 18, active: 18),
          session("bc-7d", "cafe-networks-7d", :busy, ago,
            title: "editing network_live.ex",
            active: 2
          ),
          session("bc-tv", "tv-venue-leaderboard", :busy, ago, title: "mix test", active: 1),
          session("bc-pm", "Lantern", :idle, ago, since: 142, active: 142)
        ]
      },
      %Project{
        root: root("liftlog-ios"),
        name: "liftlog-ios",
        config_dirs: [@main],
        autonomy: :act,
        roadmap: %Roadmap{confirmed?: true, sources: ["docs/plan.md"], phases: []},
        position: %Position{
          phase_id: "B",
          item_text: "onboarding screens (B.5)",
          done: 5,
          total: 10,
          last_progress_at: ago.(140)
        },
        sessions: [
          session("gi-77", "liftlog-ios-77", :busy, ago, title: "onboarding screens"),
          session("gi-12", "liftlog-ios-12", :idle, ago, since: 7, active: 7)
        ]
      },
      %Project{
        root: root("dreamboard"),
        name: "dreamboard",
        config_dirs: [@main],
        autonomy: :act,
        roadmap: %Roadmap{confirmed?: true, sources: ["docs/spec.md"], phases: []},
        position: %Position{
          phase_id: "2",
          item_text: "onboarding copy",
          done: 2,
          total: 8,
          last_progress_at: ago.(2 * 1440 + 30)
        },
        sessions: [session("id-1", "dreamboard", :idle, ago, since: 2 * 1440)]
      },
      %Project{
        root: root("liftlog"),
        name: "liftlog",
        config_dirs: [@main],
        autonomy: :act,
        roadmap: %Roadmap{confirmed?: true, sources: ["docs/roadmap.md"], phases: []},
        position: %Position{
          phase_id: "A",
          item_text: "merch checkout",
          done: 7,
          total: 10,
          last_progress_at: ago.(180)
        },
        sessions: [
          session("gb-1", "liftlog-merch", :busy, ago, since: 22),
          session("gb-2", "liftlog-admin", :busy, ago, active: 4)
        ]
      },
      %Project{
        root: root("forge"),
        name: "forge",
        config_dirs: [@main],
        autonomy: :watch,
        roadmap: %Roadmap{confirmed?: true, sources: ["docs/phases.md"], phases: []},
        position: %Position{
          phase_id: "3",
          item_text: "admin MCP tools",
          done: 2,
          total: 7,
          last_progress_at: ago.(300)
        },
        sessions: [session("mo-1", "forge", :busy, ago, since: 34, active: 7)]
      },
      %Project{
        root: root("homescout"),
        name: "homescout",
        config_dirs: [@main],
        autonomy: :propose,
        roadmap: %Roadmap{inferred?: true, sources: ["README.md"], phases: []},
        position: %Position{
          phase_id: "4",
          item_text: "search API",
          done: 4,
          total: 9,
          last_progress_at: ago.(1440 + 60)
        },
        sessions: [
          session("ap-1", "homescout", :idle, ago, since: 90, active: 90),
          session("ap-2", "homescout-search", :idle, ago, since: 200, active: 200)
        ]
      },
      %Project{
        root: root("tipjar"),
        name: "tipjar",
        config_dirs: [@forge],
        autonomy: :act,
        roadmap: %Roadmap{confirmed?: true, sources: ["docs/plan.md"], phases: []},
        position: %Position{
          phase_id: "1",
          item_text: "payouts",
          done: 4,
          total: 5,
          last_progress_at: ago.(400)
        },
        sessions: []
      },
      %Project{
        root: root("studio"),
        name: "studio",
        config_dirs: [@main],
        autonomy: :propose,
        roadmap: nil,
        position: nil,
        sessions: [session("em-1", "studio", :busy, ago, active: 3)]
      },
      %Project{
        root: root("fieldnotes"),
        name: "fieldnotes",
        config_dirs: [@main],
        autonomy: :act,
        roadmap: %Roadmap{confirmed?: true, sources: ["docs/plan.md"], phases: []},
        position: %Position{
          phase_id: "5",
          done: 6,
          total: 6,
          all_done?: true,
          last_progress_at: ago.(9 * 1440)
        },
        sessions: []
      }
    ]
  end

  defp finding(id, rule, kind, project, sid, summary, first_seen, opts \\ []) do
    %Finding{
      id: id,
      rule: rule,
      kind: kind,
      project_root: root(project),
      session_id: sid,
      summary: summary,
      first_seen_at: first_seen,
      last_seen_at: first_seen,
      state: Keyword.get(opts, :state, :open),
      data: Keyword.get(opts, :data, %{})
    }
  end

  defp tickets(ago) do
    [
      %Ticket{
        id: "t-cert",
        owner: :yours,
        project_root: root("liftlog-ios"),
        project_name: "liftlog-ios",
        session_id: "gi-77",
        session_name: "liftlog-ios-77",
        since: ago.(25),
        headline: "import the iOS Distribution cert to unblock B.7",
        meanwhile: "agent moved on to B.5",
        action_label: "⏎ details",
        finding:
          finding(
            "f-l1",
            "L1",
            :stuck,
            "liftlog-ios",
            "gi-77",
            "L1 error loop: 4× \"No signing certificate 'iOS Distribution' found\", 13:18–13:43, no file changed in between",
            ago.(25),
            state: :acted
          ),
        decision: %Decision{
          action: :reassign,
          owner_note:
            "Import the iOS Distribution certificate into the login keychain; B.7 (App Store archive) is blocked until then.",
          tried: [
            "fleet history: same error in liftlog-ios on 2 Oct; you fixed it by importing the cert",
            "web: no way to archive for the store without a distribution identity (developer.apple.com, 2 sources)"
          ],
          confidence: :high,
          owner_needed?: true
        },
        did: [
          %{at: ago.(18), text: "marked B.7 blocked in .sprat/roadmap.md", revertible_id: "w-b7"},
          %{
            at: ago.(18),
            text:
              "told the agent: stop retrying, switch Debug to automatic signing, move on to B.5 onboarding screens"
          },
          %{at: ago.(1), text: "follow-up: agent on B.5, 3 files changed. resolved"}
        ],
        pm_run: %{cost_usd: 0.31, turns: 11, confidence: :high}
      },
      %Ticket{
        id: "t-network",
        owner: :yours,
        project_root: root("cupful"),
        project_name: "cupful",
        session_id: "cf-4b",
        session_name: "cafe-networks-4b",
        since: ago.(18),
        headline: "asks: keep network_id?\nno recorded decision\nsprat suggests: keep",
        action_label: "f send answer  ⏎ edit",
        proposal:
          "Keep the old network_id column for now; drop it in a follow-up migration once the shared ledger has shipped.",
        finding:
          finding(
            "f-w1",
            "W1",
            :needs_you,
            "cupful",
            "cf-4b",
            "W1 question with no recorded answer: \"Should I keep the old network_id column or drop it in this migration?\"",
            ago.(18)
          ),
        decision: %Decision{
          action: :answer,
          tried: [
            "decisions: spec-v3 §5 covers storage, not this column",
            "memory: no earlier ruling on network_id"
          ],
          confidence: :medium
        },
        pm_run: %{cost_usd: 0.12, turns: 6, confidence: :medium}
      },
      %Ticket{
        id: "t-expo",
        owner: :sprat,
        project_root: root("dreamboard"),
        project_name: "dreamboard",
        session_id: "id-1",
        session_name: "dreamboard",
        since: ago.(4),
        headline: "researching Expo build error: web, fleet history",
        action_label: "⏎ watch",
        pm_running?: true,
        pm_started_at: ago.(3),
        finding:
          finding(
            "f-p2",
            "P2",
            :stalled,
            "dreamboard",
            "id-1",
            "P2 stalled 2 days at 2.3 (onboarding copy); last run ended on an Expo build error",
            ago.(4)
          )
      },
      %Ticket{
        id: "t-search",
        owner: :sprat,
        project_root: root("homescout"),
        project_name: "homescout",
        session_id: "ap-1",
        session_name: "homescout",
        since: ago.(9),
        headline: "following up: told the agent the search API key is in .env.local",
        action_label: "⏎ watch",
        finding:
          finding(
            "f-l3",
            "L3",
            :stuck,
            "homescout",
            "ap-1",
            "L3 the agent asked for SEARCH_API_KEY three times",
            ago.(9),
            state: :acted
          ),
        did: [
          %{
            at: ago.(8),
            text: "told the agent: the key is in .env.local (from homescout README)"
          }
        ]
      },
      %Ticket{
        id: "t-limit",
        owner: :sprat,
        project_root: root("tipjar"),
        project_name: "tipjar",
        since: ago.(40),
        headline: "usage limit; resumes payouts with the resume prompt when it resets",
        action_label: "⏎ details",
        finding:
          finding(
            "f-q1",
            "Q1",
            :scheduled,
            "tipjar",
            nil,
            "Q1 5-hour limit on ~/.claude-work",
            ago.(40)
          )
      }
    ]
  end

  defp served(ago) do
    [
      %Served{
        at: ago.(18),
        project_name: "liftlog-ios",
        text: "reassigned B.7 → B.5 (cert missing), yours: import cert"
      },
      %Served{
        at: ago.(52),
        project_name: "liftlog",
        text: "unblocked: Stripe test clock fix from tipjar, 2 Oct"
      },
      %Served{
        at: ago.(120),
        project_name: "cupful",
        text: "answered \"Postgres or SQLite?\" from spec-v3 §5"
      },
      %Served{
        at: ago.(180),
        project_name: "liftlog",
        text: "ticked A.7 merch cart (commit 4e1c)"
      },
      %Served{
        at: ago.(202),
        project_name: "dreamboard",
        text: "resumed 2.3 from PAUSE.md",
        by: :you
      },
      %Served{
        at: ago.(250),
        project_name: "forge",
        text: "commit \"Add admin tool registry\""
      },
      %Served{at: ago.(1450), project_name: "cupful", text: "pr #212 network admin"}
    ]
  end

  defp session_lines(ago) do
    [
      %{at: ago.(40), kind: :user, text: "continue C.4 shared points ledger from the plan"},
      %{at: ago.(39), kind: :assistant, text: "Reading the plan and the current schema."},
      %{at: ago.(38), kind: :tool, text: "Read plans/2026-11-14-cafe-networks.md"},
      %{at: ago.(36), kind: :tool, text: "Edit lib/cupful/networks/ledger.ex"},
      %{at: ago.(30), kind: :tool, text: "Bash mix test test/cupful/networks"},
      %{
        at: ago.(29),
        kind: :result,
        text: "2 failures: ledger_test.exs:41 expected network_id to be present",
        error?: true
      },
      %{at: ago.(25), kind: :tool, text: "Edit priv/repo/migrations/20261123_ledger.exs"},
      %{
        at: ago.(18),
        kind: :assistant,
        text:
          "Should I keep the old network_id column or drop it in this migration? Dropping it simplifies the ledger but breaks the v1 export."
      }
    ]
  end
end
