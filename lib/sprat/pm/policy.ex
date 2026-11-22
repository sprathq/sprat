defmodule Sprat.PM.Policy do
  @moduledoc """
  Pure guardrails over a PM decision (spec §8.4, §9.1, §9.2). The model's
  decision is an input; this module decides what code does with it.

  `authorize/2` returns one of:

  - `{:deliver, text}`: send `text` into the session now (`act`, `act_resume`).
  - `{:propose, reason}`: put the decision on the rail for `f fire`.
  - `{:escalate, reason}`: a **yours** ticket; only the owner can resolve it.
  - `{:refuse, reason}`: the decision is not acceptable as written (owner-only
    content, no evidence, no message, a text already sent). The caller
    escalates or retries the PM run; nothing is delivered or proposed.
  - `{:noop, reason}`: nothing to send (`watch`, `wait`), or a **hold**.

  ## Holds

  A deliverable decision that may not go out *yet* returns
  `{:noop, {:hold, why, retry_at}}`, with `why` one of:

  - `:owner_typing`: the owner typed in the session in the last 2 minutes;
    `retry_at` is `now + 2 min`.
  - `:rationed`: a message was delivered to this session less than 20 minutes
    ago; `retry_at` is that delivery plus 20 minutes.

  A hold is not a proposal: the decision stays Sprat's and the caller simply
  re-runs `authorize/2` at `retry_at` (with a fresh ledger), so rationing never
  turns into an interruption for the owner.

  ## Order of checks

  1. `escalate` decisions and `owner_needed?` escalate.
  2. No `evidence_used` → `{:refuse, :no_evidence}` (spec §8.3: retry once).
  3. More than `max_pm_runs` (3) runs for the finding → `{:escalate, :pm_run_limit}`.
     `ledger.pm_runs_for_finding` counts the run that produced this decision.
  4. Owner-only content in the message → `{:refuse, {:owner_only, category}}`.
  5. `answer` without `answer_source` → `{:escalate, :no_recorded_answer}`;
     an answer already given for this finding → `{:escalate, :already_answered}`.
  6. Autonomy: `watch` → `{:noop, :watch}`; low confidence → `{:propose, :low_confidence}`;
     `propose` → `{:propose, :autonomy}`; `resume` under `act` →
     `{:propose, :resume_needs_act_resume}`; `wait` → `{:noop, :wait}`.
  7. Budget: project or fleet daily spend at its cap → `{:propose, :budget_cap}`.
  8. Delivery: no message → refuse; a text already sent to the session → refuse;
     owner typing → hold; rationed → hold; otherwise deliver.
  """

  alias Sprat.Observer.Model.{Decision, Item}

  @ration_seconds 20 * 60
  @owner_quiet_seconds 2 * 60
  @max_pm_runs 3

  @type result ::
          {:deliver, String.t()}
          | {:propose, term()}
          | {:escalate, term()}
          | {:refuse, term()}
          | {:noop, term()}

  # Patterns for what stays the owner's (§8.4). A nudge may never ask an agent
  # to do any of these. Case-insensitive.
  @owner_only [
    {:push,
     ~r/\bgit\s+push\b|\bforce[- ]push\b|\bpush\b[^.\n]{0,30}\b(to\s+)?(origin|upstream|remote|github|the\s+remote)\b/i},
    {:deploy,
     ~r/\b(re)?deploy(ing|s|ed)?\b|\bship\s+(it\s+)?to\s+prod(uction)?\b|\brelease\s+to\s+prod(uction)?\b|\b(kubectl|terraform)\s+apply\b/i},
    {:publish, ~r/\bpublish(ing|es|ed)?\b|\bnpm\s+publish\b|\bhex\.publish\b/i},
    {:send,
     ~r/\bsend\b[^.\n]{0,40}\b(e-?mails?|newsletters?|sms|text\s+messages?|invoices?|tweets?|notifications?\s+to\s+(users|customers))\b/i},
    {:rm_rf, ~r/\brm\s+-(?=[a-z]*r)(?=[a-z]*f)[a-z]+\b/i},
    {:drop, ~r/\b(drop|truncate)\s+(table|database|schema)\b|\bmix\s+ecto\.(drop|reset)\b/i},
    {:delete_data,
     ~r/\bdelete\s+from\b|\b(delete|wipe|purge|erase)\s+(all\s+)?(the\s+|of\s+the\s+)?(production\s+|prod\s+|user\s+|customer\s+)?(data|records|rows|users|accounts|customers|database)\b/i},
    {:shared_migration,
     ~r/\bmigrat\w*\b[^.\n]{0,40}\b(prod|production|shared|staging|live)\b|\b(prod|production|shared|staging|live)\b[^.\n]{0,20}\b(db|database)\b[^.\n]{0,30}\bmigrat\w*/i},
    {:credentials,
     ~r/\b(add|create|generate|provide|paste|enter|set|rotate|obtain|fetch|get|request|share|import|regenerate|issue|sign\s+in|log\s+in)\b[^.\n]{0,40}\b(api[- ]?keys?|secrets?|passwords?|passphrases?|tokens?|credentials?|certificates?|certs?|private\s+keys?|ssh\s+keys?|keychain)\b/i},
    {:purchase,
     ~r/\b(buy|purchase|pay\s+for|subscribe\s+to|upgrade\s+(the\s+|your\s+|our\s+)?(plan|subscription|tier))\b/i},
    {:scope, ~r/\b(add|create|insert|remove|delete|reorder)\b[^.\n]{0,20}\broadmap\s+items?\b/i}
  ]

  @doc "The owner-only categories (§8.4) a text matches, in a stable order."
  @spec owner_only(String.t() | nil) :: [atom()]
  def owner_only(nil), do: []

  def owner_only(text) when is_binary(text) do
    for {category, re} <- @owner_only, Regex.match?(re, text), do: category
  end

  @doc "Applies every guardrail to `decision`. See the moduledoc for the order."
  @spec authorize(Decision.t(), map()) :: result()
  def authorize(%Decision{} = d, ctx) do
    ledger = Map.get(ctx, :ledger, %{})
    finding = Map.get(ctx, :finding)
    finding_id = finding && finding.id

    cond do
      d.action == :escalate ->
        {:escalate, :pm_escalated}

      d.owner_needed? == true ->
        {:escalate, :owner_needed}

      d.evidence_used in [nil, []] ->
        {:refuse, :no_evidence}

      pm_runs(ledger, finding_id) > @max_pm_runs ->
        {:escalate, :pm_run_limit}

      (cats = owner_only(d.message)) != [] ->
        {:refuse, {:owner_only, hd(cats)}}

      d.action == :answer and blank?(d.answer_source) ->
        {:escalate, :no_recorded_answer}

      d.action == :answer and member?(Map.get(ledger, :answers_given), finding_id) ->
        {:escalate, :already_answered}

      true ->
        by_autonomy(d, ctx)
    end
  end

  defp by_autonomy(d, ctx) do
    autonomy = Map.get(ctx, :autonomy, :propose)

    cond do
      autonomy == :watch -> {:noop, :watch}
      d.confidence == :low -> {:propose, :low_confidence}
      autonomy == :propose -> {:propose, :autonomy}
      d.action == :resume and autonomy != :act_resume -> {:propose, :resume_needs_act_resume}
      d.action == :wait -> {:noop, :wait}
      autonomy in [:act, :act_resume] -> by_budget(d, ctx)
      true -> {:propose, {:unknown_autonomy, autonomy}}
    end
  end

  defp by_budget(d, ctx) do
    b = Map.get(ctx, :budget, %{})

    if at_cap?(b[:project_spent_today], b[:project_cap]) or
         at_cap?(b[:fleet_spent_today], b[:fleet_cap]) do
      {:propose, :budget_cap}
    else
      by_delivery(d, ctx)
    end
  end

  defp by_delivery(d, ctx) do
    ledger = Map.get(ctx, :ledger, %{})
    now = Map.fetch!(ctx, :now)
    sid = session_id(ctx)
    text = message_for(d, Map.get(ctx, :item))
    sent = ledger |> Map.get(:sent_texts_by_session, %{}) |> Map.get(sid, [])
    last = ledger |> Map.get(:last_delivery_at_by_session, %{}) |> Map.get(sid)

    cond do
      blank?(d.message) ->
        {:refuse, :no_message}

      Enum.any?(sent, &(normalize(&1) in [normalize(text), normalize(d.message)])) ->
        {:refuse, :duplicate_text}

      Map.get(ctx, :owner_typing?) == true ->
        {:noop, {:hold, :owner_typing, DateTime.add(now, @owner_quiet_seconds)}}

      match?(%DateTime{}, last) and DateTime.diff(now, last) < @ration_seconds ->
        {:noop, {:hold, :rationed, DateTime.add(last, @ration_seconds)}}

      true ->
        {:deliver, text}
    end
  end

  @doc """
  The text delivered into a session: `"[sprat] <message> (roadmap: <id> <text>)"`.
  With no item the roadmap suffix is left out.
  """
  @spec message_for(Decision.t(), Item.t() | nil) :: String.t()
  def message_for(%Decision{message: message}, item) do
    body =
      (message || "")
      |> String.trim()
      |> String.replace(~r/^\[sprat\]\s*/, "")

    suffix =
      case item do
        %Item{id: id, text: text} -> " (roadmap: #{id} #{text})"
        _ -> ""
      end

    "[sprat] " <> body <> suffix
  end

  defp session_id(ctx) do
    case ctx do
      %{session: %{session_id: sid}} when not is_nil(sid) -> sid
      %{finding: %{session_id: sid}} -> sid
      _ -> nil
    end
  end

  defp pm_runs(ledger, finding_id) do
    case Map.get(ledger, :pm_runs_for_finding, 0) do
      n when is_integer(n) -> n
      %{} = m -> Map.get(m, finding_id, 0)
      _ -> 0
    end
  end

  defp member?(nil, _), do: false
  defp member?(_, nil), do: false
  defp member?(%MapSet{} = s, k), do: MapSet.member?(s, k)
  defp member?(%{} = m, k), do: Map.has_key?(m, k)
  defp member?(l, k) when is_list(l), do: k in l

  defp at_cap?(spent, cap) when is_number(spent) and is_number(cap), do: spent >= cap
  defp at_cap?(_, _), do: false

  defp blank?(nil), do: true
  defp blank?(s) when is_binary(s), do: String.trim(s) == ""
  defp blank?(_), do: false

  defp normalize(nil), do: ""

  defp normalize(s),
    do:
      s
      |> String.replace(~r/^\[sprat\]\s*/, "")
      |> String.replace(~r/\s+/, " ")
      |> String.trim()
      |> String.downcase()
end
