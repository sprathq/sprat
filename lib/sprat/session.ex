defmodule Sprat.Session do
  @moduledoc """
  One running session's in-memory projection (docs/spec-v1.md §13): the
  transcript (as `Sprat.Session.Block` maps), live-region state (stage
  checklist, activity line, pending prompt — the same shape
  `Sprat.Terminal.Renderer.set_live/2` already expects), current mode, and
  the session's project path (for composer history).

  This process is a **cache in front of `Sprat.Store`, not a second source
  of truth**: every block it holds was just written to the `messages` and
  `events` tables in the same `Store.transact/2` call, and on `init/1` it
  rebuilds its entire state by reading those tables back — nothing here
  survives that a restart couldn't reconstruct. It never touches
  `Sprat.Terminal.*` itself (see `Sprat.Session.Render` and
  `Sprat.Session.Subscriber` for the UI-facing boundary) — only
  `Sprat.Session.PubSub.broadcast/2`.

  Recovery (§13 "On start, tasks left `running` become `interrupted`...
  the TUI lists them on resume") runs once, in `init/1`, via
  `Sprat.Store.Recovery.scan/2`; any tasks it reclassifies are queued as
  numbered prompts in `live.permission`, one at a time, answered through
  `recovery_choice/2`.
  """

  use GenServer

  alias Sprat.Store.{Events, Messages, ProjectHistory, Recovery, Sessions, Tasks}
  alias Sprat.Session.{Block, PubSub}

  defstruct [
    :session_id,
    :store,
    :project_path,
    mode: "normal",
    blocks: [],
    live: %{activity: nil, checklist: nil, permission: nil},
    pending_recoveries: [],
    pending_prompt: nil,
    notify?: true,
    tty_check: &Sprat.Terminal.Mode.tty?/0,
    notifier: nil
  ]

  @recovery_choices %{0 => "resume", 1 => "skip", 2 => "cancel"}

  # -- public API -------------------------------------------------------------

  def start_link(opts) do
    session_id = Keyword.fetch!(opts, :session_id)
    GenServer.start_link(__MODULE__, opts, name: via(session_id))
  end

  def via(session_id), do: {:via, Registry, {Sprat.Session.Registry, session_id}}

  @doc "Appends and persists a user-submitted message. Also records it in the project's composer history."
  def submit_user_message(session, text),
    do: GenServer.call(resolve(session), {:add_block, %{kind: :user_message, text: text}})

  @doc "Appends and persists any other displayed block (agent message, tool call/result, stage change, ...)."
  def add_block(session, %{kind: kind} = block) when is_atom(kind),
    do: GenServer.call(resolve(session), {:add_block, block})

  def set_mode(session, mode) when mode in ["normal", "auto", "plan"],
    do: GenServer.call(resolve(session), {:set_mode, mode})

  @doc "Answers the currently-shown recovery prompt: 0 = resume, 1 = skip, 2 = cancel."
  def recovery_choice(session, choice_index) when choice_index in [0, 1, 2],
    do: GenServer.call(resolve(session), {:recovery_choice, choice_index})

  @doc "The full in-memory state, for the initial batched replay and for tests."
  def snapshot(session), do: GenServer.call(resolve(session), :snapshot)

  @doc """
  Shows `prompt` (the same numbered shape `live.permission` already uses)
  and **blocks the caller** until it is answered via `answer_permission/2`
  or cancelled via `cancel_permission/1`. Unlike the fire-and-forget
  recovery prompt (`recovery_choice/2`, decided by `Sprat.Session` itself
  from its own queue), this is for a caller — `Sprat.Mission`'s agent-loop
  task — that needs the actual answer back to resume with it: the §9 fetch
  rule, the first-run model picker, and the first-mission budget confirm.
  Only one such prompt can be pending at a time per session (matches the
  UI: one permission line can be shown at once).
  """
  def await_permission(session, prompt),
    do: GenServer.call(resolve(session), {:await_permission, prompt}, :infinity)

  @doc "Answers the pending `await_permission/2` prompt with option index `n`. `{:error, :no_prompt}` if none is pending."
  def answer_permission(session, n) when is_integer(n),
    do: GenServer.call(resolve(session), {:answer_permission, n})

  @doc "Cancels the pending `await_permission/2` prompt (Esc). `{:error, :no_prompt}` if none is pending."
  def cancel_permission(session), do: GenServer.call(resolve(session), :cancel_permission)

  @doc """
  Fires `Sprat.Notify.finished/3` for this session's project (bell + OS
  notification, spec: "tell the user when Sprat needs them" — a mission
  reaching a terminal state is the other half of that, alongside every
  `await_permission/2` pause already covered below). `status` is
  `:completed` or `:failed`.
  """
  def notify_finished(session, status) when status in [:completed, :failed],
    do: GenServer.cast(resolve(session), {:notify_finished, status})

  defp resolve(session) when is_pid(session), do: session
  defp resolve(session) when is_binary(session), do: via(session)

  # -- callbacks ----------------------------------------------------------

  @impl true
  def init(opts) do
    session_id = Keyword.fetch!(opts, :session_id)
    store = Keyword.get(opts, :store, Sprat.Store)

    session_row =
      Sessions.get(store, session_id) ||
        raise ArgumentError, "no session #{inspect(session_id)} in the store"

    blocks = replay_blocks(store, session_id)
    mode = last_mode(store, session_id)

    state = %__MODULE__{
      session_id: session_id,
      store: store,
      project_path: session_row.project_path,
      mode: mode,
      blocks: blocks,
      notify?: Keyword.get(opts, :notify?, true),
      tty_check: Keyword.get(opts, :tty_check, &Sprat.Terminal.Mode.tty?/0),
      notifier: Keyword.get(opts, :notifier)
    }

    state =
      if Keyword.get(opts, :recover?, true), do: run_recovery(state), else: state

    {:ok, state}
  end

  @impl true
  def handle_call({:add_block, block}, _from, state), do: reply_with(persist(state, block))

  def handle_call({:set_mode, mode}, _from, state) do
    state = %{state | mode: mode}

    Events.append(state.store, state.session_id, "session.mode_changed", %{
      payload: %{"mode" => mode}
    })

    PubSub.broadcast(state.session_id, {:mode_changed, mode})
    {:reply, :ok, state}
  end

  def handle_call({:recovery_choice, choice_index}, _from, state) do
    {:reply, :ok, apply_recovery_choice(state, choice_index)}
  end

  def handle_call(:snapshot, _from, state), do: {:reply, public_snapshot(state), state}

  def handle_call({:await_permission, prompt}, from, state) do
    live = %{state.live | permission: prompt}
    broadcast_permission(state.session_id, live)
    Sprat.Notify.pause(state.project_path, notify_opts(state))
    {:noreply, %{state | live: live, pending_prompt: from}}
  end

  def handle_call({:answer_permission, _n}, _from, %{pending_prompt: nil} = state),
    do: {:reply, {:error, :no_prompt}, state}

  def handle_call({:answer_permission, n}, _from, state) do
    GenServer.reply(state.pending_prompt, {:ok, n})
    live = %{state.live | permission: nil}
    broadcast_permission(state.session_id, live)
    {:reply, :ok, %{state | live: live, pending_prompt: nil}}
  end

  def handle_call(:cancel_permission, _from, %{pending_prompt: nil} = state),
    do: {:reply, {:error, :no_prompt}, state}

  def handle_call(:cancel_permission, _from, state) do
    GenServer.reply(state.pending_prompt, :cancelled)
    live = %{state.live | permission: nil}
    broadcast_permission(state.session_id, live)
    {:reply, :ok, %{state | live: live, pending_prompt: nil}}
  end

  @impl true
  def handle_cast({:notify_finished, status}, state) do
    Sprat.Notify.finished(state.project_path, status, notify_opts(state))
    {:noreply, state}
  end

  defp notify_opts(state) do
    [notify?: state.notify?, tty_check: state.tty_check] ++
      if(state.notifier, do: [notifier: state.notifier], else: [])
  end

  # -- persistence ----------------------------------------------------------

  defp persist(state, block) do
    {:ok, message} =
      Sprat.Store.transact(state.store, fn conn ->
        message =
          Messages.append_in_conn(conn, state.session_id, %{
            role: Block.role_column(block),
            content: Block.encode(block)
          })

        Events.append_in_conn(conn, state.session_id, "message.appended", %{
          payload: %{"kind" => to_string(block.kind)}
        })

        message
      end)

    full_block = Map.put(block, :occurred_at, message.occurred_at)

    if block.kind == :user_message and state.project_path do
      ProjectHistory.append(state.project_path, block.text)
    end

    PubSub.broadcast(state.session_id, {:block_added, full_block})
    %{state | blocks: state.blocks ++ [full_block]}
  end

  defp reply_with(state), do: {:reply, :ok, state}

  # `state.live` bundles `permission` with `checklist`/`activity` fields
  # this module never actually writes (those come straight from
  # `Sprat.Orchestrator`/`Sprat.Mission`'s own `PubSub.broadcast/2` calls,
  # bypassing this GenServer's state entirely — see the moduledoc). This
  # process only ever changes `permission`, so it only ever broadcasts
  # `permission` — broadcasting `state.live` wholesale would send
  # `checklist: nil`/`activity: nil` on every permission prompt shown,
  # cancelled or answered, clobbering whatever checklist status the
  # Orchestrator most recently broadcast (found live: a stage broadcast
  # as `:failed` right before `Session.await_permission/2`'s own prompt,
  # and the checklist went blank instead of showing the failed glyph,
  # because this broadcast rewrote it back to `nil` a moment later).
  # `Terminal.ZonedRenderer`/`Terminal.Renderer`'s `set_live/2` merge only
  # the keys a broadcast actually includes, so a partial map here is both
  # correct and the fix.
  defp broadcast_permission(session_id, live),
    do: PubSub.broadcast(session_id, {:live_updated, %{permission: live.permission}})

  # -- recovery ---------------------------------------------------------------

  defp run_recovery(state) do
    case Recovery.scan(state.store, state.session_id) do
      [] ->
        state

      task_ids ->
        tasks = Enum.map(task_ids, &Tasks.get(state.store, &1))
        state = %{state | pending_recoveries: tasks}
        show_next_recovery(state)
    end
  end

  defp show_next_recovery(%{pending_recoveries: []} = state) do
    live = %{state.live | permission: nil}
    broadcast_permission(state.session_id, live)
    %{state | live: live}
  end

  defp show_next_recovery(%{pending_recoveries: [task | _]} = state) do
    live = %{state.live | permission: recovery_prompt(task)}
    broadcast_permission(state.session_id, live)
    %{state | live: live}
  end

  defp recovery_prompt(task) do
    %{
      title: "Recovered task",
      lines: [
        "#{task.role} · #{task.objective}",
        "was running when Sprat last stopped and is now marked interrupted."
      ],
      options: [
        "Resume — records your choice; V1 has no orchestration to redo it yet",
        "Skip — leave it interrupted",
        "Cancel — mark it cancelled"
      ],
      selected: 0
    }
  end

  defp apply_recovery_choice(%{pending_recoveries: []} = state, _choice), do: state

  defp apply_recovery_choice(%{pending_recoveries: [task | rest]} = state, choice_index) do
    choice = Map.fetch!(@recovery_choices, choice_index)

    Events.append(state.store, state.session_id, "recovery.decision", %{
      task_id: task.id,
      payload: %{"task_id" => task.id, "choice" => choice}
    })

    if choice == "cancel" do
      Tasks.transition(state.store, task.id, :cancelled, %{
        session_id: state.session_id,
        reason: "cancelled from the recovery prompt"
      })
    end

    state = persist(%{state | pending_recoveries: rest}, recovery_outcome_block(task, choice))
    show_next_recovery(state)
  end

  defp recovery_outcome_block(task, "resume") do
    %{
      kind: :system,
      text:
        "Recorded: resume #{task.role} · #{task.objective}. " <>
          "V1 has no orchestration engine yet, so nothing was retried — this only " <>
          "records that you asked to resume it."
    }
  end

  defp recovery_outcome_block(task, "skip") do
    %{kind: :system, text: "Recorded: skip #{task.role} · #{task.objective}. Left interrupted."}
  end

  defp recovery_outcome_block(task, "cancel") do
    %{kind: :system, text: "Recorded: cancel #{task.role} · #{task.objective}."}
  end

  # -- replay ---------------------------------------------------------------

  defp replay_blocks(store, session_id) do
    store
    |> Messages.by_session(session_id)
    |> Enum.map(fn message ->
      message.content |> Block.decode() |> Map.put(:occurred_at, message.occurred_at)
    end)
  end

  defp last_mode(store, session_id) do
    case Events.by_type(store, session_id, "session.mode_changed", limit: 100_000) do
      [] ->
        "normal"

      events ->
        events |> List.last() |> Map.fetch!(:payload) |> JSON.decode!() |> Map.fetch!("mode")
    end
  end

  defp public_snapshot(state) do
    %{
      session_id: state.session_id,
      project_path: state.project_path,
      mode: state.mode,
      blocks: state.blocks,
      live: state.live
    }
  end
end
