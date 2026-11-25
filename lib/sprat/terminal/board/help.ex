defmodule Sprat.Terminal.Board.Help do
  @moduledoc """
  What `?` explains: the screen the owner is on, not a list of every key.

  Each page says what the screen is for, what each part of it means (with
  the glyphs and colours drawn the way the screen draws them), and the keys,
  named by what they do. `Sprat.Terminal.Board` renders the page.

  A part's sample is a list of `{text, style}` segments (the board's style
  roles) or a symbol the renderer draws itself: `{:chip, role, label}`,
  `{:glyphs, states}`, `{:bar, done, total}`.
  """

  alias Sprat.Terminal.Board.View

  @type part :: {sample :: term(), text :: String.t()}
  @type page :: %{
          context: atom(),
          title: String.t(),
          about: [String.t()],
          parts: [{String.t(), [part()]}],
          keys: [{String.t(), String.t()}]
        }

  @doc "The help page for where the view is."
  @spec page(View.t()) :: page()
  def page(%View{} = view) do
    case context(view) do
      :ticket -> ticket()
      :brief -> brief()
      :project -> project()
      :session -> session()
      :activity -> activity()
      :processes -> processes()
      :board -> board()
    end
  end

  @doc "Which screen the help is about."
  def context(%View{opened_ticket: id}) when not is_nil(id), do: :ticket
  def context(%View{overlay: {:brief, _}}), do: :brief
  def context(%View{screen: {:project, _}}), do: :project
  def context(%View{screen: {:session, _}}), do: :session
  def context(%View{screen: {:activity, _}}), do: :activity
  def context(%View{screen: {:processes, _}}), do: :processes
  def context(_view), do: :board

  # -- the board ------------------------------------------------------------------

  defp board do
    %{
      context: :board,
      title: "THE BOARD",
      about: [
        "Sprat watches every Claude Code session on this machine, knows where each " <>
          "project stands on its roadmap, and gets stalled agents moving again by " <>
          "itself. Only what genuinely needs you (a password, money, a decision " <>
          "nobody wrote down) comes to you.",
        "This board is where you check in. What needs attention hangs at the top " <>
          "(the rail); every project runs below (the line). You don't have to watch " <>
          "it: Sprat sends a notification when something needs you."
      ],
      parts: [
        {"AT THE TOP",
         [
           {[{"SPRAT ", :bright}, {"><>", :text}],
            "The fish swims while Sprat works, turns to face you (<•<) when something " <>
              "needs you, and keeps still when all is quiet."},
           {[{"●6 ✓2 ⏸1", :quiet}],
            "Every live Claude session at a glance: how many are working, how many " <>
              "just finished a turn, how many need you or are stuck."},
           {[{"pm $1.32/15", :quiet}],
            "What Sprat's own investigations cost today, and the daily cap."},
           {[{"NOW", :quiet}],
            "What Sprat is doing this moment and for how long: investigating a " <>
              "stalled agent, moving a session to another account, sending your " <>
              "message. ✓ finished, ✗ failed, with the reason underneath. Shown only " <>
              "while something runs or just ended."}
         ]},
        {"ON THE RAIL: tickets",
         [
           {[{"yours", :you}],
            "Something only you can do. The ticket says what, and what Sprat already " <>
              "did meanwhile."},
           {[{"sprat", :quiet}],
            "Something Sprat noticed and is handling (investigating, waiting for a " <>
              "usage limit to reset). Shown so you can watch, or step in."},
           {[
              {:chip, :quiet, "9M"},
              {" ", :text},
              {:chip, :you, "40M"},
              {" ", :text},
              {:chip, :stuck, "2H"}
            ],
            "How long the ticket has waited: grey while fresh, amber once it has " <>
              "waited longer than it should, red when it's stuck or a message Sprat " <>
              "sent didn't help. Yours come first, oldest on the left."}
         ]},
        {"THE LINE: every project, worst first",
         [
           {[{"C 3/9 ", :text}, {:bar, 3, 9}],
            "Where it stands on its roadmap: the current phase, items done of that " <>
              "phase's total, and the same as a bar."},
           {[{"working on", :quiet}],
            "The roadmap item its agents are on. \"limited\" means the account it " <>
              "runs on hit a Claude usage limit."},
           {[{:glyphs, [:busy, :finished, :idle, :waiting, :stuck, :ended]}],
            "One mark per Claude session: ● working, ✓ finished its turn in the last " <>
              "half hour (its next prompt is someone's move), ◌ idle, ⏸ waiting on " <>
              "you, ⚠ stuck, · ended."},
           {[{"sprat is", :quiet}],
            "What Sprat is doing for the project: watching (all fine), investigating, " <>
              "waiting on you, resumes 17:00 (paused by a usage limit), other account " <>
              "free, failed: …"},
           {[{"autonomy", :quiet}],
            "How much Sprat may do by itself. watch: only notices. propose: drafts " <>
              "messages for you to send. act: sends unblocking messages itself. " <>
              "act+resume: also restarts stopped sessions. A changes it."},
           {[{"moved", :quiet}], "When the project last made progress on its roadmap."}
         ]},
        {"SERVED TODAY",
         [
           {[{"12:02", :quiet}], "What got done today: by Sprat, unless marked (you)."}
         ]}
      ],
      keys: [
        {"←→", "move along the rail (tickets)"},
        {"↑↓", "move down to the projects, then to what was served"},
        {"⏎", "open the selected ticket, project or served item"},
        {"f", "send the selected ticket's suggested message"},
        {"x", "dismiss the ticket, or mark one of yours done"},
        {"A", "change the selected project's autonomy"},
        {"r", "re-read the project's roadmap (or propose one)"},
        {"a", "activity: everything Sprat did, and what it runs"},
        {"space",
         "hold and speak, then let go: “open studio”, “talk to studio-67”, “activity”, “send it”, “help”, “back” (sprat voice setup first)"},
        {"b", "today's brief, one line per project"},
        {"/", "commands: /settings /brief /findings /nudges /add <path> /stats"},
        {"q", "quit (Sprat keeps watching in the background if `sprat serve` runs)"}
      ]
    }
  end

  # -- an opened ticket ----------------------------------------------------------

  defp ticket do
    %{
      context: :ticket,
      title: "A TICKET",
      about: [
        "One thing Sprat noticed, with the whole story: what it saw, what it found " <>
          "out, what it already did, and what is left for you, if anything.",
        "Nothing is sent to the agent until you press f, unless the project's " <>
          "autonomy lets Sprat act by itself."
      ],
      parts: [
        {"READING IT",
         [
           {[{:chip, :you, "25M"}, {" yours", :you}],
            "How long it has waited, and who it waits on: yours (only you can do it) " <>
              "or sprat (Sprat is on it)."},
           {[{"you", :quiet}], "What is left for you to do, if anything."},
           {[{"found", :quiet}],
            "What Sprat noticed, with the evidence: transcript lines and when they happened."},
           {[{"tried", :quiet}],
            "Where Sprat looked for an answer: your other projects, memory, the web."},
           {[{"did", :quiet}],
            "What Sprat already did, each with its time. A roadmap mark can be undone with u."},
           {[{"suggests", :quiet}],
            "A message Sprat drafted for the agent. f sends it; e lets you change it first."},
           {[{"pm run", :quiet}],
            "What the investigation cost, how many turns it took, how sure Sprat is."}
         ]}
      ],
      keys: [
        {"f", "send the suggested message to the agent"},
        {"e", "edit the message here first (E opens $EDITOR)"},
        {"c", "copy the message"},
        {"x", "dismiss the ticket, or mark it done (asks why)"},
        {"m", "mute this kind of ticket for this session"},
        {"u", "undo the roadmap mark Sprat made"},
        {"⏎", "open the session it is about"},
        {"←→", "previous / next ticket"},
        {"esc", "fold the ticket"}
      ]
    }
  end

  # -- a project -----------------------------------------------------------------

  defp project do
    %{
      context: :project,
      title: "A PROJECT",
      about: [
        "One project: where it stands on its roadmap, the Claude sessions working " <>
          "on it, and what Sprat did for it this week."
      ],
      parts: [
        {"READING IT",
         [
           {[{"C · 3/9 · 1.2 items/day", :quiet}],
            "Top right: the current phase, items done of its total, and how fast " <>
              "items have been getting done."},
           {[{"ON THE RAIL", :quiet}], "This project's tickets, if any."},
           {[{"✓ ▸ ○", :text}],
            "The roadmap: ✓ done, ▸ current, ○ not started. A session's name beside " <>
              "an item is the agent working on it."},
           {[{:glyphs, [:busy, :finished, :idle, :waiting]}],
            "Sessions: each Claude session in this project, what it's doing and how " <>
              "long it has worked on this turn. \"running for 9m: mix test\" is a command " <>
              "still going; \"quiet 6m\" means it has written nothing for six minutes " <>
              "with nothing running, so it may be hung. A session that isn't working " <>
              "says why (a usage limit, a question for you, a finished turn), what " <>
              "Sprat will do next, and what it last did. ⏎ on one opens it, and you " <>
              "can talk to it from there."},
           {[{"SERVED", :quiet}], "What got done here in the last seven days."},
           {[{"sources", :quiet}],
            "The files the roadmap was read from: plans, ROADMAP.md, the spec, git. " <>
              "Once written, .sprat/roadmap.md wins, and you can edit it."}
         ]}
      ],
      keys: [
        {"↑↓", "move between the tickets and sessions"},
        {"⏎", "open the selected ticket or session"},
        {"f", "send the selected ticket's suggested message"},
        {"x", "dismiss the selected ticket"},
        {"A", "change how much Sprat may do here by itself"},
        {"e", "edit the roadmap in $EDITOR"},
        {"w", "write .sprat/roadmap.md from what Sprat found"},
        {"r", "re-read the roadmap"},
        {"a", "this project's activity"},
        {"b", "this project's brief"},
        {"esc", "back to the board"}
      ]
    }
  end

  # -- a session -----------------------------------------------------------------

  defp session do
    %{
      context: :session,
      title: "A SESSION",
      about: [
        "One Claude Code session, as if you had switched to it: its own terminal, " <>
          "live. Whatever you type here goes to this agent, so you can talk to it " <>
          "without leaving the board."
      ],
      parts: [
        {"READING IT",
         [
           {[{"TERMINAL", :quiet}],
            "The session's own cmux tab, refreshed twice a second. tab switches to " <>
              "the condensed transcript: what you said, what the agent said, its " <>
              "tool calls and errors."},
           {[{"› to studio-67", :you}],
            "Your message. ⏎ sends it exactly as you typed it. If the session isn't " <>
              "ready (text already in its prompt, a question open), Sprat waits up to " <>
              "two minutes; the NOW band shows it waiting, then sent, or why not."},
           {[{"a dialog is open", :you}],
            "The agent is asking something (allow a command, pick an option). Answer " <>
              "it here: 1–9 picks, ↑↓ moves, ⏎ confirms."},
           {[{"idle since 16:41", :quiet}],
            "Top right: what the session is doing, and since when."},
           {[{"why", :quiet}],
            "When it isn't working, why: a usage limit, a question for you, a " <>
              "command waiting for your ok, or simply a finished turn. Then the last " <>
              "thing it did, and how long ago."},
           {[{"next", :quiet}],
            "What Sprat will do about it, and when: continue it at the limit's " <>
              "reset, leave it for you, or look in once it has been idle 30 minutes " <>
              "(and then propose or nudge, as the project's autonomy allows)."}
         ]}
      ],
      keys: [
        {"type", "write a message to the agent"},
        {"space",
         "hold and speak: your words appear as you talk, then go into the message line; say “send” to send it"},
        {"⏎", "send it (in the transcript: expand a line)"},
        {"esc", "drop the message, or go back"},
        {"1–9 ↑↓ ⏎", "answer a question the agent is asking"},
        {"tab",
         "its terminal → its condensed transcript → its recap: what it did over the last hours (←→ 1h 4h 12h 24h)"},
        {"↑↓ pgup pgdn",
         "scroll its terminal back through its history, or the transcript; ↓ to the bottom follows it live again"},
        {"ctrl-o", "switch to the session's own cmux tab"}
      ]
    }
  end

  # -- activity ------------------------------------------------------------------

  defp activity do
    %{
      context: :activity,
      title: "ACTIVITY",
      about: [
        "Everything Sprat did, newest first, and the machinery doing it. Opened " <>
          "from a project, it shows only that project."
      ],
      parts: [
        {"READING IT",
         [
           {[{"✓ ✗ ▸ ·", :text}],
            "Each line: the time, the project, what kind of thing (a job, a pm " <>
              "investigation, a sent message, a finding, done, the engine, a " <>
              "program), and what happened. ✓ finished, ✗ failed, ▸ started, · noted."},
           {[{"PROCESSES", :quiet}],
            "Sprat's own parts, each running on its own: one per session and one per " <>
              "project that keep watch, and the engine that decides. mailbox is work " <>
              "waiting for that part; a number that keeps growing means it is " <>
              "falling behind."},
           {[{"PROGRAMS", :quiet}],
            "The programs Sprat runs to look at your machine (ps, git, cmux, claude): " <>
              "how often, how long on average and at worst, and how the last run ended."}
         ]}
      ],
      keys: [
        {"↑↓ pgup pgdn", "scroll the timeline"},
        {"g", "back to the newest"},
        {"esc", "back"}
      ]
    }
  end

  # -- sprat's processes -----------------------------------------------------------

  defp processes do
    %{
      context: :processes,
      title: "SPRAT'S PROCESSES",
      about: [
        "Sprat is an Elixir program: many small processes, each doing one job " <>
          "and talking to the others by messages, kept running by supervisors " <>
          "that restart any that fail. This screen shows them live, inside " <>
          "sprat serve, four ways: grouped by what they stand for (the default), " <>
          "as a pulse of the last two minutes, as a fish tank, or as the raw tree."
      ],
      parts: [
        {"GROUPED",
         [
           {[{"⏸ cafe-net-4b", :text}],
            "A Claude session, under its project, with its state. Each one has a " <>
              "watcher process that follows its transcript; beside it, the last " <>
              "thing the watcher read, green while it is new."},
           {[{"◆ engine", :text}],
            "The parts that decide and deliver: the engine (decides what each " <>
              "session needs), the publisher (sends every change out), the line to " <>
              "your board, the tasks running, the project watchers and the plumbing."},
           {[{"──●──▶", :you}],
            "From Claude to your screen: the latest thing a watcher read, hop by " <>
              "hop to this board. Sparks run along the hops while it is new."}
         ]},
        {"THE PULSE",
         [
           {[{"✎ ", :progress}, {"▶──", :bright}, {" ✗", :stuck}],
            "Each live session's last two minutes, newest on the right: a mark for " <>
              "each thing it did (✎ edited, ▶ ran a command, ◦ read, · wrote, › you " <>
              "wrote, ? asked you, ✗ failed), a bar while a command runs, the latest " <>
              "at the end. A session editing and testing, one stuck in a long build " <>
              "and one waiting on you each have their own rhythm."},
           {[{"┊  ┊  ┊", :quiet}],
            "Below: the engine checking every session, and your board being redrawn, " <>
              "on the same clock."}
         ]},
        {"THE TANK",
         [
           {[{"><(((°>", :bright}],
            "Every live session as a fish (Sprat is one too). A working one is big " <>
              "and quick, an idle one small and slow; one that needs you hangs at the " <>
              "surface; one that finished its turn rests on the sand. Bubbles rise when " <>
              "its watcher has just read something new."}
         ]},
        {"THE TREE",
         [
           {[{"◆", :quiet}],
            "A supervisor: it starts the processes under it and restarts one that " <>
              "crashes. A crash stays inside its branch."},
           {[{"●", :bright}],
            "A process at work: bright while it is busy, dim while it rests. One " <>
              "watches each Claude session, one each project; the engine decides."},
           {[{"⠋", :progress}],
            "A task: a short-lived process for one piece of work, such as an " <>
              "investigation or moving a session. It ends when the work does."},
           {[{"new", :progress}, {" ended", :quiet}],
            "Started or finished in the last few seconds."},
           {[{"▁▃▅▇", :progress}],
            "How hard it has worked over the last few seconds, newest on the right. " <>
              "The number beside it is its work per second (Erlang reductions)."},
           {[{"mailbox", :quiet}],
            "Messages waiting for it. A number that keeps growing means it is " <>
              "falling behind."}
         ]},
        {"MESSAGES",
         [
           {[{"──●──▶", :you}],
            "Messages one process sent another in the last sample, sender on the " <>
              "left. More dots, more messages; the word says what kind (a call, a " <>
              "cast, a snapshot) and the number how many per second. Sampled only " <>
              "while this screen is open."}
         ]}
      ],
      keys: [
        {"p", "the pulse, and back"},
        {"f", "the fish tank, and back"},
        {"t", "the tree, and back"},
        {"esc", "back to activity"}
      ]
    }
  end

  # -- the brief -----------------------------------------------------------------

  defp brief do
    %{
      context: :brief,
      title: "THE BRIEF",
      about: [
        "Today's brief: one line per project, written like a standup note: what " <>
          "moved, what's stuck, what needs you. The last line adds it up."
      ],
      parts: [],
      keys: [{"esc", "close the brief"}]
    }
  end
end
