defmodule Sprat.Engine.Quiet do
  @moduledoc """
  Why a session is quiet, what it last did, and what Sprat means to do
  about it: the line the board shows for every session that is not working,
  so a test still running, a usage limit and a question waiting for the owner
  stop looking alike from another project.

  `explain/2` reads what the detector reads (the session, its folded state,
  its account, its project and bound item, the open findings) and returns
  plain data; `why_text/2`, `last_text/2` and `plan_text/2` word it. Pure: the
  clock comes in with the input.

  The plan follows the engine's own rules, so it says what will happen:

  - a usage limit: a live session is continued at the reset; an ended one is
    started again at the reset under `act_resume`, else proposed to the owner;
  - a question, or a tool waiting on a permission prompt: it waits for the
    owner, and Sprat sends it nothing;
  - the owner typed there in the last two minutes: Sprat stays out;
  - a finished turn with its roadmap item not done: once it has been idle
    `p4_idle`, Sprat looks into it (P4), and what it may do then depends on
    the project's autonomy;
  - a finished turn with nothing left on its item, or no item: nothing.
  """

  alias Sprat.Observer.Detector
  alias Sprat.Observer.Model.{Account, Item, Project, Session, SessionState}

  @owner_quiet_s 2 * 60
  @looking ~w(L1 L2 L3 P3 P4)

  @type reason ::
          {:limit, DateTime.t() | nil}
          | {:question, String.t() | nil}
          | {:permission, String.t()}
          | {:running, String.t(), DateTime.t() | nil}
          | {:typing, DateTime.t()}
          | :turn_done

  @type plan ::
          {:continue_at, DateTime.t() | nil}
          | {:restart_at, DateTime.t() | nil}
          | {:propose_restart_at, DateTime.t() | nil}
          | :waits_for_you
          | :stays_out
          | :looking_now
          | :on_rail
          | {:check_at, DateTime.t(), atom()}
          | {:nothing, :item_done | :no_item}
          | nil

  @type t :: %{
          reason: reason(),
          last: {DateTime.t(), atom(), String.t() | nil} | nil,
          plan: plan()
        }

  @doc """
  The explanation for `session`. `ctx`: `:now`, `:state` (`%SessionState{}`
  or nil), `:account` (`%Account{}` or nil), `:project` (`%Project{}`),
  `:findings` (this session's, any state), `:p4_idle` (seconds, optional).
  """
  @spec explain(Session.t(), map()) :: t()
  def explain(%Session{} = s, ctx) do
    st = ctx[:state] || %SessionState{}
    now = ctx.now
    reason = reason(s, st, ctx[:account], now)

    %{reason: reason, last: last(st), plan: plan(reason, s, st, ctx)}
  end

  # -- why -------------------------------------------------------------------------

  defp reason(s, st, account, now) do
    pending = main_pending(st)

    cond do
      limit = limit(s, st, account, now) ->
        {:limit, dt(limit)}

      st.asks_user? == true ->
        {:question, st.pending_question}

      s.status == :busy and pending != nil ->
        {:running, tool_label(pending), pending.at}

      pending != nil ->
        {:permission, tool_label(pending)}

      typing?(st, now) ->
        {:typing, st.last_user_at}

      true ->
        :turn_done
    end
  end

  defp limit(s, st, account, now) do
    by_session = Detector.effective_limit(s, st, now)

    by_account =
      case account do
        %Account{limited_until: %DateTime{} = until} ->
          if DateTime.compare(until, now) == :gt, do: until

        _ ->
          nil
      end

    cond do
      by_session -> by_session.reset_at || by_account || :unknown
      by_account -> by_account
      true -> nil
    end
  end

  defp main_pending(%SessionState{pending_tool_uses: pending}) when map_size(pending) > 0 do
    pending
    |> Map.values()
    |> Enum.reject(& &1.sidechain?)
    |> Enum.reject(&(&1.data[:name] == "AskUserQuestion"))
    |> Enum.max_by(&(&1.line || 0), fn -> nil end)
  end

  defp main_pending(_), do: nil

  defp tool_label(event) do
    case Sprat.Engine.Beats.kind(event) do
      {:run, cmd} when is_binary(cmd) -> cmd
      {_kind, label} when is_binary(label) -> "#{event.data[:name]} #{label}"
      _ -> to_string(event.data[:name] || "a tool")
    end
  end

  defp typing?(%SessionState{last_user_at: %DateTime{} = at}, now),
    do: DateTime.diff(now, at) < @owner_quiet_s

  defp typing?(_, _), do: false

  # -- last --------------------------------------------------------------------------

  defp last(%SessionState{last_action: {at, :say, _}} = st),
    do: {at, :say, first_line(st.last_assistant_text)}

  defp last(%SessionState{last_action: {_, _, _} = a}), do: a
  defp last(_), do: nil

  # -- plan --------------------------------------------------------------------------

  defp plan({:limit, at}, %Session{live?: true}, _st, _ctx), do: {:continue_at, dt(at)}

  defp plan({:limit, at}, _s, _st, ctx) do
    case ctx[:project] do
      %Project{autonomy: :act_resume} -> {:restart_at, dt(at)}
      _ -> {:propose_restart_at, dt(at)}
    end
  end

  defp plan({:question, _}, _s, _st, _ctx), do: :waits_for_you
  defp plan({:permission, _}, _s, _st, _ctx), do: :waits_for_you
  defp plan({:running, _, _}, _s, _st, _ctx), do: nil
  defp plan({:typing, _}, _s, _st, _ctx), do: :stays_out

  defp plan(:turn_done, s, st, ctx) do
    findings = ctx[:findings] || []
    looking = Enum.filter(findings, &(&1.rule in @looking))

    cond do
      Enum.any?(looking, &(&1.state == :pm_running)) ->
        :looking_now

      Enum.any?(looking, &(&1.state in [:open, :acted, :escalated])) ->
        :on_rail

      true ->
        case ctx[:item] do
          nil ->
            {:nothing, :no_item}

          %Item{state: :done} ->
            {:nothing, :item_done}

          %Item{} ->
            since = s.status_since || st.last_event_at
            autonomy = (ctx[:project] && ctx.project.autonomy) || :propose
            idle = ctx[:p4_idle] || Detector.default_settings().p4_idle

            if since,
              do: {:check_at, DateTime.add(since, idle, :second), autonomy},
              else: {:check_at, nil, autonomy}
        end
    end
  end

  defp dt(%DateTime{} = at), do: at
  defp dt(_), do: nil

  # -- words ---------------------------------------------------------------------------

  @doc "Why it is quiet, in a few words. `hhmm` formats a time."
  def why_text(%{reason: reason}, hhmm) do
    case reason do
      {:limit, %DateTime{} = at} -> "usage limit until #{hhmm.(at)}"
      {:limit, _} -> "paused by a usage limit"
      {:question, q} when is_binary(q) -> "asked you: " <> first_line(q)
      {:question, _} -> "asked you something"
      {:permission, label} -> "waiting for your ok to run " <> label
      {:running, label, _} -> "running " <> label
      {:typing, _} -> "you are typing there"
      :turn_done -> "finished its turn"
    end
  end

  @doc "What it last did, and how long ago: \"edited board.ex 12m ago\"."
  def last_text(%{last: nil}, _now), do: nil

  def last_text(%{last: {at, kind, label}}, now) do
    what =
      case {kind, label} do
        {:edit, l} when is_binary(l) -> "edited " <> l
        {:run, l} when is_binary(l) -> "ran " <> l
        {:read, l} when is_binary(l) -> "read " <> l
        {:web, l} when is_binary(l) -> "searched " <> l
        {:agent, l} when is_binary(l) -> "sent an agent: " <> l
        {:ask, _} -> "asked you a question"
        {:say, l} when is_binary(l) and l != "" -> "wrote “" <> l <> "”"
        {:say, _} -> "wrote to you"
        {:you, _} -> "you wrote to it"
        {:fail, _} -> "hit an error"
        {:tool, l} when is_binary(l) -> "used " <> l
        {k, _} -> to_string(k)
      end

    what <> " " <> ago(now, at)
  end

  @doc "What Sprat will do about it, or nil when nothing is planned to say."
  def plan_text(%{plan: plan}, now, hhmm) do
    at = fn
      %DateTime{} = t -> if DateTime.compare(t, now) == :gt, do: "at #{hhmm.(t)}", else: "shortly"
      _ -> "when it resets"
    end

    case plan do
      {:continue_at, t} -> "sprat continues it #{at.(t)}"
      {:restart_at, t} -> "sprat starts it again #{at.(t)}"
      {:propose_restart_at, t} -> "sprat asks you to start it again #{at.(t)}"
      :waits_for_you -> "waits for you; sprat sends it nothing"
      :stays_out -> "sprat stays out while you type"
      :looking_now -> "sprat is looking into it now"
      :on_rail -> "sprat has a ticket for it on the rail"
      {:check_at, t, :watch} -> "sprat looks #{at.(t)}, but only watches"
      {:check_at, t, :propose} -> "sprat looks #{at.(t)} and proposes a next step"
      {:check_at, t, _act} -> "sprat looks #{at.(t)} and may nudge it on"
      {:nothing, :item_done} -> "its item is done; sprat leaves it"
      {:nothing, :no_item} -> "no roadmap item; sprat leaves it"
      nil -> nil
    end
  end

  defp ago(now, at) do
    s = max(DateTime.diff(now, at), 0)

    cond do
      s < 60 -> "just now"
      s < 3600 -> "#{div(s, 60)}m ago"
      s < 86_400 -> "#{div(s, 3600)}h ago"
      true -> "#{div(s, 86_400)}d ago"
    end
  end

  defp first_line(nil), do: ""

  defp first_line(text) do
    text |> String.trim() |> String.split("\n", parts: 2) |> hd() |> String.slice(0, 80)
  end
end
