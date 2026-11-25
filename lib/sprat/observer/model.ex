defmodule Sprat.Observer.Model do
  @moduledoc """
  Shared data types for V4, the observer/PM (`docs/spec-v4.md`).

  Every V4 module — registry, transcripts, roadmap, detector, PM, nudges, the
  Pass TUI — speaks in these structs. They are plain data: no processes, no
  I/O. Times are `DateTime` in UTC unless a field says otherwise.
  """

  defmodule Account do
    @moduledoc """
    One Claude config directory (`~/.claude`, `~/.claude-work`, …). Usage
    limits are per account (spec §7.1).
    """
    @enforce_keys [:config_dir]
    defstruct config_dir: nil,
              # nil, or the instant the account's usage limit resets
              limited_until: nil,
              # :five_hour | :session | :weekly | nil
              limit_kind: nil,
              # the raw limit message, for display
              limit_text: nil,
              # session ids to continue after the reset, in resume order (spec §7.1)
              resume_queue: [],
              # the Claude login (account uuid) the dir had when the limit
              # hit; `/login` to another account lifts the limit for the dir
              login: nil,
              # when the limit hit (its message's time)
              limited_at: nil

    @type t :: %__MODULE__{
            config_dir: String.t(),
            limited_until: DateTime.t() | nil,
            limit_kind: :five_hour | :session | :weekly | nil,
            limit_text: String.t() | nil,
            resume_queue: [String.t()],
            login: String.t() | nil,
            limited_at: DateTime.t() | nil
          }
  end

  defmodule Session do
    @moduledoc """
    One Claude Code session: a live process from `<config>/sessions/<pid>.json`
    and/or a transcript under `<config>/projects/<slug>/<session_id>.jsonl`.
    """
    @enforce_keys [:session_id, :config_dir]
    defstruct session_id: nil,
              config_dir: nil,
              pid: nil,
              # true when the pid is alive and the registry file exists
              live?: false,
              # :busy | :idle | :shell | :ended | :unknown
              status: :unknown,
              status_since: nil,
              cwd: nil,
              # repository root this session belongs to (worktrees resolve to the main repo)
              project_root: nil,
              branch: nil,
              worktree?: false,
              name: nil,
              title: nil,
              version: nil,
              transcript_path: nil,
              # cmux surface ref ("surface:239") or tmux pane, when known
              surface: nil,
              tmux: nil,
              started_at: nil,
              last_activity_at: nil,
              # true when the session's worktree has uncommitted changes; nil when unknown
              dirty?: nil

    @type status :: :busy | :idle | :shell | :ended | :unknown
    @type t :: %__MODULE__{}
  end

  defmodule Event do
    @moduledoc """
    One parsed transcript record that Sprat cares about (spec §4.2). `line` is
    the 1-based line number in the transcript file, used as evidence id
    (`"transcript:<session_id>:<line>"`).
    """
    @enforce_keys [:kind, :line]
    defstruct kind: nil,
              line: nil,
              at: nil,
              # :user_text — the owner's (or Sprat's) prompt text
              # :assistant_text — assistant prose
              # :tool_use — %{id, name, input}
              # :tool_result — %{tool_use_id, is_error, text}
              # :api_error — %{status, text, limit?}
              # :title — ai-title
              # :cost — %{total_usd}
              # :pr — %{number, url}
              # :compact
              data: %{},
              branch: nil,
              sidechain?: false

    @type kind ::
            :user_text
            | :assistant_text
            | :tool_use
            | :tool_result
            | :api_error
            | :title
            | :cost
            | :pr
            | :compact
    @type t :: %__MODULE__{kind: kind(), line: pos_integer()}
  end

  defmodule SessionState do
    @moduledoc """
    The pure fold of a session's events (spec §6 `Sprat.Observer.SessionState`):
    what the detector rules read.
    """
    defstruct session_id: nil,
              last_user_text: nil,
              last_user_at: nil,
              last_assistant_text: nil,
              last_assistant_at: nil,
              # the last event of any kind
              last_event_at: nil,
              # tool_use ids with no tool_result yet: %{id => %Event{}}
              pending_tool_uses: %{},
              # last N tool results: [%{line, at, name, command, is_error, signature, text}] newest first
              recent_results: [],
              # last N file edits: [%{line, at, path}] newest first
              recent_edits: [],
              # last N api errors, newest first
              api_errors: [],
              # the newest usage-limit event, if the session's last assistant record is one
              usage_limit: nil,
              # The newest usage limit a background agent failed on (its
              # task-notification); the main thread may still be running.
              agent_limit: nil,
              # true when the last test-like command failed
              last_test_failed?: nil,
              last_commit_at: nil,
              title: nil,
              cost_usd: nil,
              # true when the newest assistant turn ends with a question to the user
              asks_user?: false,
              pending_question: nil,
              # transcript line of the newest assistant text (evidence for W1/P3/P4)
              last_assistant_line: nil,
              # transcript line of the newest event of any kind
              last_event_line: nil,
              # lines of the last N (10) assistant records, newest first; W3's window
              recent_assistant_lines: [],
              # the main thread's newest action, as `Sprat.Engine.Beats` names
              # it: `{at, kind, label}` (edited a file, ran a command, wrote…)
              last_action: nil

    @type t :: %__MODULE__{}
  end

  defmodule Item do
    @moduledoc "One roadmap item."
    @enforce_keys [:id, :text]
    defstruct id: nil,
              text: nil,
              # :done | :active | :todo | :blocked
              state: :todo,
              blocked_reason: nil,
              branch: nil,
              source: nil,
              # 1-based line in the source file
              source_line: nil,
              # true when the owner edited this line in .sprat/roadmap.md
              owner_edited?: false,
              # strings that tie the item to its evidence: commit messages the
              # source plan quotes for it, and doc paths it links (not rendered)
              hints: []

    @type state :: :done | :active | :todo | :blocked
    @type t :: %__MODULE__{}
  end

  defmodule Phase do
    @moduledoc "One roadmap phase."
    @enforce_keys [:id, :title]
    defstruct id: nil, title: nil, source: nil, items: []

    @type t :: %__MODULE__{
            id: String.t(),
            title: String.t(),
            items: [Sprat.Observer.Model.Item.t()]
          }
  end

  defmodule Roadmap do
    @moduledoc """
    A project's roadmap (spec §5): phases of items, from its sources,
    normalised into `.sprat/roadmap.md`.
    """
    defstruct project_root: nil,
              # the name in `# Roadmap: <name>` (defaults to the root's basename)
              name: nil,
              goal: nil,
              due: nil,
              phases: [],
              # [path] the roadmap was built from
              sources: [],
              # true once `.sprat/roadmap.md` exists (written or confirmed by the owner)
              confirmed?: false,
              # true when any part came from model inference rather than a parser
              inferred?: false,
              # disagreements between sources, shown as suggestions (spec §15.3)
              notes: [],
              # the PAUSE.md handover when one exists:
              # %{path, written_on, updated_on, title, repo_state}
              pause: nil

    @type t :: %__MODULE__{}
  end

  defmodule Position do
    @moduledoc "Where a project stands on its roadmap (spec §5.3)."
    defstruct phase_id: nil,
              phase_title: nil,
              item_id: nil,
              item_text: nil,
              done: 0,
              total: 0,
              last_progress_at: nil,
              # :tick | :commit | :pr | :done | nil
              last_progress_kind: nil,
              # items done per active day over 14 days
              velocity: nil,
              all_done?: false

    @type t :: %__MODULE__{}
  end

  defmodule Project do
    @moduledoc "A repository and everything Sprat knows about it."
    @enforce_keys [:root]
    defstruct root: nil,
              name: nil,
              config_dirs: [],
              roadmap: nil,
              position: nil,
              sessions: [],
              # :watch | :propose | :act | :act_resume
              autonomy: :propose,
              first_seen_at: nil,
              archived?: false,
              # mtime of docs/PAUSE.md, nil when there is none (P2)
              pause_md_at: nil

    @type autonomy :: :watch | :propose | :act | :act_resume
    @type t :: %__MODULE__{}
  end

  defmodule Finding do
    @moduledoc """
    A detector rule matched (spec §7). `id` is stable for the same rule, session
    and evidence set, so re-detection updates instead of duplicating.
    """
    @enforce_keys [:id, :rule, :project_root]
    defstruct id: nil,
              # "W1" | "W2" | "W3" | "Q1" | "L1" | "L2" | "L3" | "P1" | "P2" | "P3" | "P4"
              rule: nil,
              # :needs_you | :stuck | :stalled | :scheduled
              kind: nil,
              project_root: nil,
              session_id: nil,
              summary: nil,
              # ["transcript:<sid>:<line>", "commit:<sha>", "file:<path>"]
              evidence: [],
              first_seen_at: nil,
              last_seen_at: nil,
              # :open | :pm_running | :acted | :resolved | :dismissed | :escalated | :snoozed
              state: :open,
              # extra rule data, e.g. %{reset_at: dt} for Q1, %{signature: s, count: 4} for L1
              data: %{}

    @type t :: %__MODULE__{}
  end

  defmodule Decision do
    @moduledoc "A PM run's structured decision (spec §8.3)."
    @enforce_keys [:action]
    defstruct action: nil,
              obstacle: nil,
              tried: [],
              message: nil,
              owner_note: nil,
              # roadmap item ids the PM found already done, with evidence (a
              # commit or a passing run_check); applied as revertible ticks
              done_items: [],
              blocked_item: nil,
              blocked_reason: nil,
              next_item: nil,
              answer_source: nil,
              confidence: :medium,
              evidence_used: [],
              owner_needed?: false

    @type action :: :unblock | :answer | :reassign | :resume | :wait | :escalate
    @type t :: %__MODULE__{}
  end

  defmodule Ticket do
    @moduledoc """
    What the Pass TUI shows on the rail (spec §10.3): a finding with its owner
    (`:yours` or `:sprat`) and its latest PM decision / delivery.
    """
    @enforce_keys [:id, :owner, :project_root]
    defstruct id: nil,
              # :yours | :sprat
              owner: :sprat,
              project_root: nil,
              project_name: nil,
              session_id: nil,
              session_name: nil,
              finding: nil,
              decision: nil,
              # one-to-three line obstacle / what sprat is doing
              headline: nil,
              # what sprat did meanwhile (for yours tickets)
              meanwhile: nil,
              # the ready action label, e.g. "f fire answer", "⏎ details"
              action_label: nil,
              # a message awaiting `f` (propose mode, suggested answers)
              proposal: nil,
              since: nil,
              pm_running?: false,
              # when the running PM investigation started (for its elapsed time)
              pm_started_at: nil,
              # [%{at, text, revertible_id}]
              did: [],
              # the PM run behind the ticket, for its opened view:
              # %{cost_usd, turns, confidence} (any key may be absent)
              pm_run: nil

    @type t :: %__MODULE__{}
  end

  defmodule Served do
    @moduledoc "One line of 'served today' (spec §10.3)."
    @enforce_keys [:at, :project_name, :text]
    defstruct at: nil, project_name: nil, text: nil, by: :sprat, ref: nil
    @type t :: %__MODULE__{}
  end
end
