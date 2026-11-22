defmodule Sprat.Terminal.Board.Keys do
  @moduledoc """
  Pure key handling for the Pass (`docs/spec-v4.md` §10.9):
  `handle(view, key) → {view, [command]}`. Keys are the events
  `Sprat.Terminal.Keys` produces. Navigation changes only the view; anything
  that acts on the world comes back as a command for the app to run:

    * `{:fire, ticket_id, text}` — send the (possibly edited) proposal
    * `{:dismiss, ticket_id, reason | nil}`
    * `{:revert, write_id}`
    * `{:set_autonomy, root, level}`
    * `{:open_session_terminal, session_id}`
    * `{:copy, text}`
    * `{:mute, finding_id}`
    * `{:write_roadmap, root}` / `{:reread_roadmap, root}` / `{:edit_roadmap, root}`
    * `{:brief, root | :all}`
    * `{:edit_in_editor, ticket_id, text}` — `E` on an opened ticket; the
      app runs `$EDITOR` itself and fires the edit
    * `{:session_lines, session_id}` — when the session view opens (the app
      repeats it every poll while the view stays open)
    * `{:slash, name, arg | nil}` — `/settings`, `/findings`, `/nudges`,
      `/add <path>`, `/stats` (`/brief` becomes `{:brief, :all}`)
    * `:quit`
  """

  alias Sprat.Observer.Model.Ticket
  alias Sprat.Terminal.Board.View
  alias Sprat.Terminal.Composer

  @autonomy [:watch, :propose, :act, :act_resume]

  @slash_commands [
    {"settings", "autonomy, budgets, accounts"},
    {"brief", "one line per project"},
    {"findings", "every open finding"},
    {"nudges", "nudges sent and their follow-up"},
    {"add", "add a project by path"},
    {"stats", "how Sprat is doing"}
  ]

  @type command ::
          {:fire, String.t(), String.t()}
          | {:dismiss, String.t(), String.t() | nil}
          | {:revert, String.t()}
          | {:set_autonomy, String.t(), atom()}
          | {:open_session_terminal, String.t()}
          | {:copy, String.t()}
          | {:mute, String.t()}
          | {:write_roadmap, String.t()}
          | {:reread_roadmap, String.t()}
          | {:edit_roadmap, String.t()}
          | {:brief, String.t() | :all}
          | {:edit_in_editor, String.t(), String.t()}
          | {:session_lines, String.t()}
          | {:slash, String.t(), String.t() | nil}
          | :quit

  @doc "Handles one key event."
  @spec handle(View.t(), term()) :: {View.t(), [command()]}
  def handle(%View{} = view, :ctrl_c), do: {view, [:quit]}

  # Listening to the microphone: space let go (or tapped again) stops, Esc
  # cancels; nothing else does anything until then. The board app tells a
  # held space's auto-repeat from a second tap (`:voice_space`).
  def handle(%View{voice: %{state: :listening}} = view, key) do
    case key do
      {:key, 32, _, :release} -> {view, [:voice_stop]}
      {:key, 32, _, _} -> {view, []}
      {:char, " "} -> {view, [:voice_space]}
      :esc -> {view, [:voice_cancel]}
      {:key, 27, _, :press} -> {view, [:voice_cancel]}
      _ -> {view, []}
    end
  end

  # Space, with no message line open: talk to the board.
  def handle(%View{composer: nil, help?: false, voice: nil} = view, {:char, " "}),
    do: {view, [:voice_start]}

  def handle(%View{composer: c} = view, key) when not is_nil(c), do: composer_key(view, key)

  def handle(%View{help?: true} = view, key) do
    at = view.help_index

    case normalize(key) do
      k when k in [:esc, {:char, "?"}, {:char, "q"}, :enter] -> {%{view | help?: false}, []}
      :down -> {%{view | help_index: at + 1}, []}
      :up -> {%{view | help_index: max(at - 1, 0)}, []}
      :page_down -> {%{view | help_index: at + 10}, []}
      :page_up -> {%{view | help_index: max(at - 10, 0)}, []}
      {:char, " "} -> {%{view | help_index: at + 10}, []}
      _ -> {view, []}
    end
  end

  def handle(%View{} = view, key) do
    view = %{view | status: nil}

    case session_keys(view, key) do
      nil -> global_key(view, key)
      handled -> handled
    end
  end

  defp global_key(view, key) do
    case normalize(key) do
      :esc when not is_nil(view.overlay) -> {%{view | overlay: nil}, []}
      {:char, "?"} -> {%{view | help?: true, help_index: 0, first_run?: false}, []}
      {:char, "q"} -> {view, [:quit]}
      {:char, "/"} -> {open_composer(view, :command, nil, "/"), []}
      key -> screen_key(view, key)
    end
  end

  # On a session's screen the keyboard talks to the session: typing starts a
  # message to it; while its terminal shows a dialog, digits, arrows and ⏎
  # answer the dialog. `?` stays help, tab switches terminal/transcript,
  # ctrl-o goes to the session's own cmux tab.
  defp session_keys(%View{screen: {:session, sid}, opened_ticket: nil, overlay: nil} = view, key) do
    dialog? = View.session_dialog?(view, sid)

    case key do
      {:char, d} when dialog? and d in ~w(1 2 3 4 5 6 7 8 9) -> {view, [{:session_key, sid, d}]}
      :up when dialog? -> {view, [{:session_key, sid, "up"}]}
      :down when dialog? -> {view, [{:session_key, sid, "down"}]}
      :enter when dialog? -> {view, [{:session_key, sid, "enter"}]}
      {:char, "?"} -> nil
      {:char, c} -> {open_composer(view, :to_session, sid, c), []}
      {:paste, text} -> {open_composer(view, :to_session, sid, text), []}
      :tab -> {%{view | session_mode: toggle_mode(view.session_mode)}, []}
      {:ctrl, "o"} -> {view, [{:open_session_terminal, sid}]}
      _ -> nil
    end
  end

  defp session_keys(_view, _key), do: nil

  defp toggle_mode(:terminal), do: :transcript
  defp toggle_mode(_), do: :terminal

  @doc "The `/` commands, for the command line's completion menu."
  def slash_commands, do: @slash_commands

  # h/j/k/l are arrows everywhere outside a composer.
  defp normalize({:char, "h"}), do: :left
  defp normalize({:char, "l"}), do: :right
  defp normalize({:char, "j"}), do: :down
  defp normalize({:char, "k"}), do: :up
  defp normalize(key), do: key

  # == an opened ticket ========================================================

  defp screen_key(%View{opened_ticket: id} = view, key) when not is_nil(id) do
    t = View.ticket(view, id)

    case key do
      :esc -> {%{view | opened_ticket: nil}, []}
      :left -> {step_opened(view, -1), []}
      :right -> {step_opened(view, 1), []}
      {:char, "f"} -> fire(view, t)
      {:char, "e"} -> edit(view, t)
      {:char, "E"} -> {view, [{:edit_in_editor, t.id, View.fire_text(view, t) || note(t) || ""}]}
      {:char, "c"} -> copy(view, t)
      {:char, "x"} -> {open_composer(view, :dismiss_reason, t.id, ""), []}
      {:char, "m"} -> mute(view, t)
      {:char, "u"} -> revert(view, t)
      :enter -> open_session(view, t.session_id)
      {:char, "b"} -> {view, [{:brief, t.project_root}]}
      _ -> {view, []}
    end
  end

  # == the board ===============================================================

  defp screen_key(%View{screen: :board} = view, key) do
    rail = View.rail(view)
    line = View.line(view)
    served = View.served_today(view)

    case key do
      :left ->
        {%{view | focus: rail_focus(rail, view), rail_index: max(view.rail_index - 1, 0)}, []}

      :right ->
        {%{
           view
           | focus: rail_focus(rail, view),
             rail_index: min(view.rail_index + 1, max(length(rail) - 1, 0))
         }, []}

      :down ->
        {move_down(view, line, served), []}

      :up ->
        {move_up(view, rail), []}

      :enter ->
        board_enter(view, line, served)

      {:char, "f"} ->
        fire(view, View.selected_ticket(view))

      {:char, "x"} ->
        dismiss_now(view, View.selected_ticket(view))

      {:char, "b"} ->
        {view, [{:brief, :all}]}

      {:char, "a"} ->
        {%{view | screen: {:activity, nil}, activity_index: 0}, []}

      {:char, c} when c in ["A", "r", "w", "e"] ->
        case view.focus == :line && Enum.at(line, view.line_index) do
          %{} = p -> project_command(view, p, c)
          _ -> {view, []}
        end

      _ ->
        {view, []}
    end
  end

  # == a project ===============================================================

  defp screen_key(%View{screen: {:project, root}} = view, key) do
    items = View.project_items(view, root)
    p = View.project(view, root)

    case key do
      :esc ->
        {%{view | screen: :board}, []}

      :up ->
        {%{view | project_index: max(view.project_index - 1, 0)}, []}

      :down ->
        {%{view | project_index: min(view.project_index + 1, max(length(items) - 1, 0))}, []}

      :enter ->
        case Enum.at(items, view.project_index) do
          {:ticket, t} -> {%{view | opened_ticket: t.id}, []}
          {:session, s} -> open_session(view, s.session_id)
          nil -> {view, []}
        end

      {:char, "f"} ->
        fire(view, View.selected_ticket(view))

      {:char, "x"} ->
        dismiss_now(view, View.selected_ticket(view))

      {:char, "b"} ->
        {view, [{:brief, root}]}

      {:char, "a"} ->
        {%{view | screen: {:activity, root}, activity_index: 0}, []}

      {:char, c} when c in ["A", "r", "w", "e"] ->
        project_command(view, p, c)

      _ ->
        {view, []}
    end
  end

  # == activity ================================================================

  defp screen_key(%View{screen: {:activity, root}} = view, key) do
    n = length(View.activity(view, root))
    at = view.activity_index

    case key do
      :esc -> {%{view | screen: if(root, do: {:project, root}, else: :board)}, []}
      :up -> {%{view | activity_index: max(at - 1, 0)}, []}
      :down -> {%{view | activity_index: min(at + 1, max(n - 1, 0))}, []}
      :page_up -> {%{view | activity_index: max(at - 10, 0)}, []}
      :page_down -> {%{view | activity_index: min(at + 10, max(n - 1, 0))}, []}
      {:char, "g"} -> {%{view | activity_index: 0}, []}
      {:char, "p"} -> {%{view | screen: {:processes, root}, procs: nil}, []}
      _ -> {view, []}
    end
  end

  # == sprat's processes =======================================================

  defp screen_key(%View{screen: {:processes, root}} = view, key) do
    case key do
      :esc -> {%{view | screen: {:activity, root}}, []}
      {:char, "t"} -> {%{view | procs_view: toggle(view.procs_view, :tree)}, []}
      {:char, "p"} -> {%{view | procs_view: toggle(view.procs_view, :pulse)}, []}
      {:char, "f"} -> {%{view | procs_view: toggle(view.procs_view, :tank)}, []}
      _ -> {view, []}
    end
  end

  # == a session ===============================================================

  defp screen_key(%View{screen: {:session, sid}} = view, key) do
    n = length(View.session_lines(view, sid))

    case key do
      :esc ->
        back =
          case View.session(view, sid) do
            {_s, p} -> {:project, p.root}
            nil -> :board
          end

        {View.clamp(%{view | screen: back, session_expanded: MapSet.new()}), []}

      :up ->
        {%{view | session_index: max(view.session_index - 1, 0)}, []}

      :down ->
        {%{view | session_index: min(view.session_index + 1, max(n - 1, 0))}, []}

      :page_up ->
        {%{view | session_index: max(view.session_index - 10, 0)}, []}

      :page_down ->
        {%{view | session_index: min(view.session_index + 10, max(n - 1, 0))}, []}

      :enter ->
        i = view.session_index
        set = view.session_expanded

        set = if MapSet.member?(set, i), do: MapSet.delete(set, i), else: MapSet.put(set, i)
        {%{view | session_expanded: set}, []}

      _ ->
        {view, []}
    end
  end

  # == board movement ==========================================================

  defp rail_focus([], view), do: view.focus
  defp rail_focus(_rail, _view), do: :rail

  defp move_down(view, line, served) do
    case view.focus do
      :rail ->
        if line == [], do: view, else: %{view | focus: :line}

      :line ->
        cond do
          view.line_index < length(line) - 1 -> %{view | line_index: view.line_index + 1}
          served != [] -> %{view | focus: :served, served_index: 0}
          true -> view
        end

      :served ->
        %{view | served_index: min(view.served_index + 1, min(length(served), 5) - 1)}
    end
  end

  defp move_up(view, rail) do
    case view.focus do
      :rail ->
        view

      :line ->
        cond do
          view.line_index > 0 -> %{view | line_index: view.line_index - 1}
          rail != [] -> %{view | focus: :rail}
          true -> view
        end

      :served ->
        if view.served_index > 0,
          do: %{view | served_index: view.served_index - 1},
          else: %{view | focus: :line}
    end
  end

  defp board_enter(view, line, served) do
    case view.focus do
      :rail ->
        case View.selected_ticket(view) do
          nil -> {view, []}
          t -> {%{view | opened_ticket: t.id}, []}
        end

      :line ->
        case Enum.at(line, view.line_index) do
          nil -> {view, []}
          p -> {View.clamp(%{view | screen: {:project, p.root}, project_index: 0}), []}
        end

      :served ->
        s = Enum.at(served, view.served_index)

        case s && s.ref && View.ticket(view, s.ref) do
          %Ticket{id: id} -> {%{view | opened_ticket: id}, []}
          _ -> {%{view | status: "no PM run on the rail for that line"}, []}
        end
    end
  end

  defp step_opened(view, delta) do
    list =
      case view.screen do
        {:project, root} -> View.project_tickets(view, root)
        _ -> View.rail(view)
      end

    case Enum.find_index(list, &(&1.id == view.opened_ticket)) do
      nil ->
        view

      i ->
        j = (i + delta) |> max(0) |> min(length(list) - 1)
        t = Enum.at(list, j)

        view = %{view | opened_ticket: t.id}

        case view.screen do
          :board -> %{view | rail_index: j, focus: :rail}
          {:project, root} -> %{view | project_index: project_index_of(view, root, t.id)}
          _ -> view
        end
    end
  end

  defp project_index_of(view, root, id) do
    view
    |> View.project_items(root)
    |> Enum.find_index(&match?({:ticket, %{id: ^id}}, &1)) || 0
  end

  # == actions =================================================================

  defp fire(view, nil), do: {%{view | status: "nothing selected"}, []}

  defp fire(view, %Ticket{} = t) do
    case View.fire_text(view, t) do
      text when is_binary(text) and text != "" ->
        {%{
           view
           | status: "fired to #{t.session_name || t.project_name}",
             edited: Map.delete(view.edited, t.id)
         }, [{:fire, t.id, text}]}

      _ ->
        {%{view | status: "nothing to fire on this ticket"}, []}
    end
  end

  defp edit(view, %Ticket{} = t) do
    case View.fire_text(view, t) do
      nil -> {%{view | status: "nothing to edit on this ticket"}, []}
      text -> {open_composer(view, :edit_proposal, t.id, text), []}
    end
  end

  defp copy(view, %Ticket{} = t) do
    case View.fire_text(view, t) || note(t) do
      nil -> {view, []}
      text -> {%{view | status: "copied"}, [{:copy, text}]}
    end
  end

  defp note(%Ticket{decision: %{owner_note: n}}) when is_binary(n), do: n
  defp note(%Ticket{decision: %{message: m}}) when is_binary(m), do: m
  defp note(%Ticket{headline: h}), do: h

  defp mute(view, %Ticket{finding: %{id: fid}}),
    do: {%{view | status: "muted this rule for this session"}, [{:mute, fid}]}

  defp mute(view, _t), do: {%{view | status: "no finding to mute"}, []}

  defp revert(view, %Ticket{did: did}) do
    ids = for entry <- did || [], id = Map.get(entry, :revertible_id), do: id

    case ids do
      [] ->
        {%{view | status: "no roadmap writes to revert"}, []}

      ids ->
        {%{view | status: "reverting #{length(ids)} roadmap write(s)"},
         Enum.map(ids, &{:revert, &1})}
    end
  end

  defp dismiss_now(view, nil), do: {view, []}

  defp dismiss_now(view, %Ticket{} = t) do
    word = if t.owner == :yours, do: "marked done", else: "dismissed"
    {%{view | status: word}, [{:dismiss, t.id, nil}]}
  end

  defp open_session(view, nil), do: {%{view | status: "no session on this ticket"}, []}

  defp open_session(view, sid) do
    case View.session(view, sid) do
      nil ->
        {%{view | status: "session not found"}, []}

      _ ->
        view = %{view | screen: {:session, sid}, opened_ticket: nil, session_lines: nil}
        {%{view | session_index: last_line_index(view, sid)}, [{:session_lines, sid}]}
    end
  end

  defp last_line_index(view, sid), do: max(length(View.session_lines(view, sid)) - 1, 0)

  defp project_command(view, nil, _c), do: {view, []}

  defp project_command(view, p, "A") do
    next = next_autonomy(p.autonomy)

    {%{view | status: "#{p.name}: autonomy → #{autonomy_word(next)}"},
     [{:set_autonomy, p.root, next}]}
  end

  defp project_command(view, p, "r") do
    if is_nil(p.roadmap),
      do: {%{view | status: "proposing a roadmap for #{p.name}"}, [{:write_roadmap, p.root}]},
      else: {%{view | status: "re-reading #{p.name}'s roadmap"}, [{:reread_roadmap, p.root}]}
  end

  defp project_command(view, p, "w"), do: {view, [{:write_roadmap, p.root}]}
  defp project_command(view, p, "e"), do: {view, [{:edit_roadmap, p.root}]}

  @doc "The next autonomy level: watch → propose → act → act+resume → watch."
  def next_autonomy(level) do
    i = Enum.find_index(@autonomy, &(&1 == level)) || -1
    Enum.at(@autonomy, rem(i + 1, length(@autonomy)))
  end

  defp autonomy_word(:act_resume), do: "act+resume"
  defp autonomy_word(level), do: to_string(level)

  # == the inline composer =====================================================

  defp open_composer(view, purpose, ticket_id, text) do
    commands = if purpose == :command, do: @slash_commands, else: []
    c = Composer.new(commands: commands)
    c = %{c | text: text, cursor: Composer.length_of(text)}
    %{view | composer: %{purpose: purpose, ticket_id: ticket_id, composer: c}, status: nil}
  end

  defp composer_key(%View{composer: %{composer: c} = comp} = view, key) do
    case key do
      :esc ->
        {%{view | composer: nil}, []}

      _ ->
        case Composer.handle_event(c, key) do
          {:submit, text, _c} -> submit(%{view | composer: nil}, comp, text)
          {:ok, c} -> backspaced_out(view, comp, c)
        end
    end
  end

  # Backspacing over the `/` closes the command line.
  defp backspaced_out(view, %{purpose: :command}, %Composer{text: ""}),
    do: {%{view | composer: nil}, []}

  defp backspaced_out(view, comp, c), do: {%{view | composer: %{comp | composer: c}}, []}

  defp submit(view, %{purpose: :edit_proposal, ticket_id: id}, text) do
    text = String.trim(text)

    if text == "",
      do: {%{view | status: "empty answer not saved"}, []},
      else: {%{view | edited: Map.put(view.edited, id, text), status: "edited · f sends it"}, []}
  end

  defp submit(view, %{purpose: :dismiss_reason, ticket_id: id}, text) do
    reason = if String.trim(text) == "", do: nil, else: String.trim(text)
    {%{view | opened_ticket: nil, status: "dismissed"}, [{:dismiss, id, reason}]}
  end

  defp submit(view, %{purpose: :command}, text), do: slash(view, String.trim(text))

  defp submit(view, %{purpose: :to_session, ticket_id: sid}, text) do
    case String.trim(text) do
      "" -> {view, []}
      text -> {view, [{:send_to_session, sid, text}]}
    end
  end

  defp slash(view, "/" <> rest) do
    {name, arg} =
      case String.split(rest, ~r/\s+/, parts: 2) do
        [name] -> {name, nil}
        [name, arg] -> {name, String.trim(arg)}
      end

    known = Enum.map(@slash_commands, &elem(&1, 0))

    cond do
      name == "brief" -> {view, [{:brief, :all}]}
      name == "add" and arg in [nil, ""] -> {%{view | status: "usage: /add <path>"}, []}
      name in known -> {view, [{:slash, name, arg}]}
      true -> {%{view | status: "unknown command /#{name}"}, []}
    end
  end

  defp slash(view, _), do: {view, []}

  # A view's key opens it, and from it, goes back to the grouped one.
  defp toggle(mode, mode), do: :story
  defp toggle(_mode, mode), do: mode
end
