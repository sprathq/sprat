defmodule Sprat.Engine.Commands do
  @moduledoc """
  The owner's commands from the Pass TUI (spec-v4 §10.9), applied to the
  engine state. Every command returns `{reply, state}` where reply is `:ok`,
  `{:ok, payload}` or `{:error, message}`.
  """

  alias Sprat.Engine
  alias Sprat.Observer.{Store, Transcript}
  alias Sprat.Observer.Model.{Finding, Project, Served, Session}

  def run(cmd, state, now), do: do_run(cmd, state, now)

  # f — the owner sends a proposal (a suggested answer, a propose-mode decision).
  defp do_run({:fire, ticket_id, text}, state, now) do
    with {:ok, f} <- finding(state, ticket_id),
         text when is_binary(text) and text != "" <- text || f.data[:proposal] do
      text = ensure_prefix(text)
      session = Map.get(state.sessions, f.session_id)
      project = Map.get(state.projects, f.project_root)
      except = (session && session.config_dir) || (f.data || %{})[:account]

      alt =
        f.rule == "Q1" && project &&
          List.first(Engine.free_accounts(state, f.project_root, except, now, f.session_id))

      cond do
        alt ->
          switch_account(state, f, session, project, alt, text, now)

        Sprat.PM.Policy.owner_only(text) != [] and
            not String.starts_with?(text, "[sprat, from the owner]") ->
          # Owner-only content is fine when the owner sends it; just label it as theirs.
          fire(
            state,
            f,
            session,
            project,
            String.replace_prefix(text, "[sprat]", "[sprat, from the owner]"),
            now
          )

        true ->
          fire(state, f, session, project, text, now)
      end
    else
      nil -> {{:error, "Nothing to send on this ticket."}, state}
      "" -> {{:error, "Nothing to send on this ticket."}, state}
      {:error, _} = e -> {e, state}
    end
  end

  defp do_run({:dismiss, ticket_id, reason}, state, now) do
    with {:ok, f} <- finding(state, ticket_id) do
      if String.ends_with?(ticket_id, ":note") do
        f2 = %{f | data: Map.put(f.data || %{}, :owner_note_done, true)}
        Store.upsert_finding(state.store, f2)
        Store.log_event(state.store, :owner_note_done, %{finding: f.id}, now)
        {:ok, Engine.put_finding(state, f2)}
      else
        Store.set_finding_state(state.store, f.id, :dismissed,
          dismiss_reason: reason || "dismissed"
        )

        Store.log_event(
          state.store,
          :dismissed,
          %{finding: f.id, rule: f.rule, reason: reason},
          now
        )

        {:ok,
         Engine.put_finding(
           %{
             state
             | follow_ups: Map.delete(state.follow_ups, f.id),
               holds: Map.delete(state.holds, f.id)
           },
           %{f | state: :dismissed}
         )}
      end
    end
    |> normalise(state)
  end

  defp do_run({:mute, finding_id}, state, now),
    do: do_run({:dismiss, finding_id, "muted"}, state, now)

  defp do_run({:revert, write_id}, state, now) do
    write =
      state.projects
      |> Map.keys()
      |> Enum.flat_map(&Store.list_writes(state.store, &1))
      |> Enum.find(&(&1[:id] == write_id))

    case write do
      nil ->
        {{:error, "No such roadmap change."}, state}

      w ->
        record = %{
          item_id: w[:item_id],
          from: to_atom(w[:from_state]),
          to: to_atom(w[:to_state]),
          reason: w[:reason],
          from_reason: nil,
          at: w[:at]
        }

        case Sprat.Roadmap.revert(w[:project_root], record) do
          {:ok, _} ->
            Store.mark_reverted(state.store, write_id, now)
            Store.log_event(state.store, :reverted, %{write: write_id}, now)

            {{:ok, {:message, "Reverted #{w[:item_id]}."}},
             Engine.invalidate_roadmap(state, w[:project_root])}

          {:error, reason} ->
            {{:error, "Could not revert: #{inspect(reason)}"}, state}
        end
    end
  end

  defp do_run({:set_autonomy, root, level}, state, now)
       when level in [:watch, :propose, :act, :act_resume] do
    Store.set_autonomy(state.store, root, level, "owner", now)

    projects =
      Map.update(state.projects, root, nil, fn %Project{} = p -> %{p | autonomy: level} end)
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)
      |> Map.new()

    {{:ok, {:message, "#{Path.basename(root)}: #{level}"}}, %{state | projects: projects}}
  end

  defp do_run({:write_roadmap, root}, state, _now) do
    case Map.get(state.projects, root) do
      %Project{roadmap: rm} when not is_nil(rm) ->
        :ok = Sprat.Roadmap.write(rm, root)

        {{:ok, {:message, "Wrote .sprat/roadmap.md"}}, Engine.invalidate_roadmap(state, root)}

      _ ->
        {{:error, "No roadmap to write for this project."}, state}
    end
  end

  defp do_run({:reread_roadmap, root}, state, _now),
    do: {{:ok, {:message, "Re-reading roadmap sources…"}}, Engine.invalidate_roadmap(state, root)}

  defp do_run({:edit_roadmap, root}, state, _now) do
    path = Path.join([root, ".sprat", "roadmap.md"])

    if not File.exists?(path) do
      case Map.get(state.projects, root) do
        %Project{roadmap: rm} when not is_nil(rm) -> Sprat.Roadmap.write(rm, root)
        _ -> :ok
      end
    end

    {{:ok, {:edit, path}}, Engine.invalidate_roadmap(state, root)}
  end

  defp do_run({:copy, text}, state, _now) do
    case Sprat.Nudge.Delivery.copy(text) do
      :ok -> {{:ok, {:message, "Copied."}}, state}
      {:error, r} -> {{:error, "Copy failed: #{inspect(r)}"}, state}
    end
  end

  defp do_run({:brief, scope}, state, now) do
    snap = Sprat.Engine.Snapshot.build(state, now)
    findings = state.findings |> Map.values()

    projects =
      case scope do
        :all -> snap.projects
        root -> Enum.filter(snap.projects, &(&1.root == root))
      end

    text =
      Sprat.Brief.compose(%{
        now: now,
        projects: projects,
        findings: findings,
        served: snap.served,
        pm_spend: snap.header.pm_spend
      })

    {{:ok, {:brief, text}}, state}
  end

  defp do_run({:open_session_terminal, sid}, state, _now) do
    case Map.get(state.sessions, sid) do
      %Session{surface: surface} when is_binary(surface) ->
        focus = Keyword.get(state.opts, :focus_fun, &Sprat.Observer.Surfaces.focus/1)

        case focus.(surface) do
          :ok ->
            {{:ok, {:message, "Switched to that session in cmux #{surface}; type away."}}, state}

          {:error, why} ->
            {{:error, "Couldn't switch to cmux #{surface}: #{inspect(why)}"}, state}
        end

      %Session{tmux: pane} when is_binary(pane) ->
        {{:ok, {:message, "That session is in tmux pane #{pane}."}}, state}

      %Session{cwd: cwd} ->
        {{:ok, {:message, "That session runs in #{cwd}."}}, state}

      nil ->
        {{:error, "Unknown session."}, state}
    end
  end

  # The owner typed a message on a session's screen: deliver it as typed (no
  # `[sprat]` label: these are the owner's words) once the session's prompt
  # is free, as a job, so the board shows it waiting and how it went.
  defp do_run({:send_to_session, sid, text}, state, now) do
    case Map.get(state.sessions, sid) do
      nil ->
        {{:error, "Unknown session."}, state}

      %Session{live?: false} = s ->
        {{:error, "#{s.name || "That session"} has ended; nothing is listening."}, state}

      %Session{} = s ->
        deliver = Keyword.get(state.opts, :deliver_fun, &Sprat.Nudge.Delivery.deliver/3)
        wait_ms = Keyword.get(state.opts, :send_wait_ms, 120_000)
        retry_ms = Keyword.get(state.opts, :send_retry_ms, 2_000)
        name = s.name || String.slice(sid, 0, 8)

        body = fn step -> send_when_free(deliver, s, text, step, wait_ms, retry_ms) end

        {_job, state} =
          Sprat.Engine.Jobs.start(
            state,
            [
              kind: :message,
              label: "to #{name}: " <> String.slice(text, 0, 60),
              project_root: s.project_root,
              session_id: sid
            ],
            body,
            fn st, _result, _job -> st end,
            now
          )

        {{:ok, {:message, "Sending to #{name}…"}}, state}
    end
  end

  defp do_run({:add_project, path}, state, _now) do
    path = Path.expand(path)

    if File.dir?(path) do
      list = Store.get_setting(state.store, "extra_projects") || []
      Store.put_setting(state.store, "extra_projects", Enum.uniq([path | list]))
      {{:ok, {:message, "Watching #{path}."}}, state}
    else
      {{:error, "No such directory: #{path}"}, state}
    end
  end

  defp do_run({:archive, root}, state, now) do
    p = Map.get(state.projects, root)

    if p do
      Store.upsert_project(state.store, %{p | archived?: true})
      Store.log_event(state.store, :archived, %{root: root}, now)

      {{:ok, {:message, "Archived #{p.name}."}},
       %{state | projects: Map.delete(state.projects, root)}}
    else
      {{:error, "Unknown project."}, state}
    end
  end

  defp do_run({:session_lines, sid}, state, _now),
    do:
      {{:ok,
        {:session_lines, Sprat.Engine.Snapshot.session_lines(Map.get(state.events, sid, []))}},
       state}

  defp do_run(other, state, _now), do: {{:error, "Unknown command: #{inspect(other)}"}, state}

  # -- helpers ---------------------------------------------------------------------

  # What the owner fires is only logged as served once it actually reached the
  # session (Engine.deliver does that, also for a send queued behind a busy
  # prompt) or a background session started. A failed send says why.
  defp fire(state, %Finding{} = f, session, project, text, now) do
    cond do
      session && session.live? ->
        state = Engine.deliver(state, f, session, text, :fired, now)
        after_f = Map.get(state.findings, f.id) || f

        cond do
          Map.has_key?(state.holds, f.id) ->
            {{:ok,
              {:message,
               "Queued: the session's prompt is busy; Sprat sends it as soon as it is free."}},
             state}

          after_f.state == :acted and (after_f.data || %{})[:delivered_at] == now ->
            {{:ok, {:message, "Sent."}}, state}

          true ->
            why = (after_f.data || %{})[:proposal_reason] || "delivery failed"
            {{:error, "Not sent: #{why}. #{reach_hint(why)}"}, state}
        end

      project ->
        bg = Keyword.get(state.opts, :background_fun)

        result =
          if bg do
            bg.(project.root, text,
              account: session && session.config_dir,
              resume: session && session.session_id
            )
          else
            start_bg(project.root, text, session)
          end

        if bg_ok?(result) do
          record_owner_served(
            state,
            f,
            project,
            "you started: " <> String.slice(text, 0, 80),
            now
          )

          {{:ok, {:message, "Started a background session."}}, state}
        else
          {{:error, "Couldn't start a background session: #{inspect(result)}"}, state}
        end

      true ->
        {{:error, "That ticket has no session or project to send to."}, state}
    end
  end

  # The session's account is limited and another account that works on this
  # project is free: carry on there. The new session forks the conversation
  # when that account can read its transcript (a shared projects/ folder),
  # else starts fresh with the resume prompt. The limited session is not
  # resumed again at the reset.
  # Moving a limited session to a free account is slow (a transcript can be
  # hundreds of MB) and can fail where nobody sees it (a terminal that
  # closes), so it runs as a job: the command answers at once, the job
  # reports each step, and only a session that really started dismisses
  # the finding.
  defp switch_account(state, f, session, project, dir, text, now) do
    acct = Path.basename(dir)
    name = (session && session.name) || "the session"
    running = Enum.find(Map.values(state.jobs), &(&1.ticket_id == f.id and &1.status == :running))

    if running do
      {{:ok, {:message, "Already on it: #{running.label} (#{running.step || "starting"})."}},
       state}
    else
      start = Keyword.get(state.opts, :account_fun, &Engine.start_and_confirm/5)
      root = project.root

      body = fn step ->
        {resume, carried?} = carry_conversation(session, dir, step)

        result =
          if is_function(start, 5),
            do: start.(root, dir, resume, text, step),
            else: start.(root, dir, resume, text)

        case result do
          {:ok, where} -> {:ok, started_text(where, acct, resume, carried?)}
          {:error, why} -> {:error, "couldn't start on #{acct}: #{why}"}
        end
      end

      on_done = fn st, result, _job -> switched(st, f, session, project, dir, result) end

      {_job, state} =
        Sprat.Engine.Jobs.start(
          state,
          [
            kind: :switch_account,
            label: "moving #{name} to #{acct}",
            project_root: root,
            session_id: session && session.session_id,
            ticket_id: f.id
          ],
          body,
          on_done,
          now
        )

      {{:ok, {:message, "Moving #{name} to #{acct}…"}}, state}
    end
  end

  defp switched(state, f, session, project, dir, {:ok, _text}) do
    now = Engine.now(state)

    Store.set_finding_state(state.store, f.id, :dismissed, dismiss_reason: "continued on #{dir}")

    Store.log_event(state.store, :switched_account, %{finding: f.id, to: dir}, now)

    record_owner_served(
      state,
      f,
      project,
      "you moved #{(session && session.name) || "it"} to #{Path.basename(dir)}",
      now
    )

    f = Map.get(state.findings, f.id, f)

    Engine.put_finding(
      %{state | holds: Map.delete(state.holds, f.id)},
      %{f | state: :dismissed}
    )
  end

  defp switched(state, _f, _session, _project, _dir, {:error, _}), do: state

  defp started_text(where, acct, resume, carried?) do
    place =
      case where do
        {:cmux, ws} when is_binary(ws) -> "started on #{acct} in cmux #{ws}"
        {:cmux, _} -> "started on #{acct} in a new cmux workspace"
        :cmux -> "started on #{acct} in a new cmux workspace"
        _ -> "started on #{acct} as a background session"
      end

    place <>
      cond do
        carried? -> "; the conversation was copied there and carries on"
        resume -> "; it carries on the same conversation"
        true -> "; it started fresh (the conversation couldn't be copied)"
      end
  end

  # The session's conversation, made readable from `dir`: already there (a
  # shared projects/ folder), or copied over. `{resume_id, copied?}`;
  # `{nil, false}` when there is no transcript to bring.
  defp carry_conversation(nil, _dir, _step), do: {nil, false}

  defp carry_conversation(session, dir, step) do
    sid = session.session_id

    source =
      session.transcript_path ||
        (session.config_dir && Transcript.locate(session.config_dir, sid))

    cond do
      Transcript.locate(dir, sid) ->
        {sid, false}

      is_binary(source) ->
        progress = fn
          {:bytes, done, total} -> step.("copying the conversation #{mb(done)}/#{mb(total)} MB")
          {:files, n} -> step.("copying #{n} agent transcripts")
        end

        case Transcript.carry(source, dir, progress) do
          {:ok, _} -> {sid, true}
          {:error, _} -> {nil, false}
        end

      true ->
        {nil, false}
    end
  end

  defp mb(bytes), do: div(bytes, 1_048_576)

  defp send_when_free(deliver, session, text, step, wait_ms, retry_ms) do
    deadline = System.monotonic_time(:millisecond) + wait_ms

    Stream.repeatedly(fn -> deliver.(session, text, []) end)
    |> Enum.reduce_while(nil, fn
      {:ok, adapter}, _ ->
        {:halt, {:ok, "sent via #{adapter}"}}

      {:hold, why}, _ ->
        if System.monotonic_time(:millisecond) >= deadline do
          {:halt, {:error, "not sent: #{hold_text(why)} for #{div(wait_ms, 1000)}s"}}
        else
          step.("waiting: " <> hold_text(why))
          Process.sleep(retry_ms)
          {:cont, nil}
        end

      {:error, :no_adapter}, _ ->
        {:halt,
         {:error, "not sent: Sprat can't reach this session's terminal (not in cmux or tmux)"}}

      {:error, why}, _ ->
        {:halt, {:error, "not sent: #{inspect(why, limit: 5)}"}}
    end)
  end

  defp hold_text(:owner_typing), do: "there is text in its prompt"
  defp hold_text(:dialog), do: "a dialog is open; answer it first"
  defp hold_text(:no_prompt), do: "its prompt isn't showing"
  defp hold_text(other), do: inspect(other)

  defp bg_ok?(:ok), do: true
  defp bg_ok?({_out, 0}), do: true
  defp bg_ok?(_), do: false

  defp reach_hint(why) do
    if String.contains?(why, "no_adapter"),
      do: "Sprat can't reach that session's terminal (see the header).",
      else: "Press ⏎ to open the session and paste it yourself."
  end

  defp record_owner_served(state, f, project, text, now) do
    Store.record_served(
      state.store,
      %Served{at: now, project_name: project.name, text: text, by: :owner, ref: f.id},
      f.project_root
    )
  end

  defp start_bg(root, text, session) do
    env = if session, do: [{"CLAUDE_CONFIG_DIR", session.config_dir}], else: []
    args = if session, do: ["--bg", "--resume", session.session_id, text], else: ["--bg", text]
    bin = System.find_executable("claude") || Path.expand("~/.local/bin/claude")
    Sprat.Cmd.run(bin, args, cd: root, env: env, timeout: 30_000)
  end

  defp finding(state, ticket_id) do
    id = String.replace_suffix(ticket_id, ":note", "")

    case Map.get(state.findings, id) do
      nil -> {:error, "That ticket is gone."}
      f -> {:ok, f}
    end
  end

  defp ensure_prefix(text) do
    if String.starts_with?(text, "[sprat"), do: text, else: "[sprat, from the owner] " <> text
  end

  defp normalise({:ok, state}, _), do: {:ok, state}
  defp normalise({:error, _} = e, state), do: {e, state}
  defp normalise({reply, %{} = st}, _), do: {reply, st}

  defp to_atom(s) when is_atom(s), do: s
  defp to_atom(s) when s in ["done", "active", "todo", "blocked"], do: String.to_existing_atom(s)
  defp to_atom(_), do: :todo
end
