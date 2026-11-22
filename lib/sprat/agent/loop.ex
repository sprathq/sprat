defmodule Sprat.Agent.Loop do
  @moduledoc """
  The agent loop (docs/spec-v1.md §7/§8/§13): given a role prompt, a
  context package and a tool set, runs turns against a `Sprat.Model` until
  a final answer, a tool call needing approval, a budget/turn limit, or
  cancellation — emitting an event for every request, response, tool call
  and usage record through `Sprat.Store` (§11), and publishing streaming
  deltas via the caller's `on_delta` for the UI to render (never calling a
  renderer itself, per §13 "the domain never calls the renderer").

  Not built here (session/Orchestrator territory, owned elsewhere): the
  Orchestrator's 3-consecutive-empty-turns stall detector itself, and
  `request_task` delegation. This module only exposes the hook the
  detector needs — `opts[:on_turn_end]`, called once per completed turn
  with `%{turn: state.turns}` — and re-checks `opts[:cancel?]` right
  after, so a caller that flips its cancel flag from inside
  `on_turn_end` (as the stall detector does) actually stops the loop
  even when the model adapter itself never polls `cancel?` mid-stream
  (true of `Sprat.StubModel`, used by every test). `run/1`'s `max_turns`
  is this module's own turn cap in the meantime.

  `{:needs_approval, request, resume}` carries a `resume` continuation
  (an opaque map) for `resume/3`: the caller (`Sprat.Mission`) decides the
  fetch-approval prompt (docs/spec-v1.md §9), then calls back with either
  `{:approved, tool_context_patch}` (merged into `tool_context` before the
  tool is retried — e.g. adding the approved host to `auto_fetch_hosts`)
  or `:denied` (the model sees a "denied by user" tool error and can
  recover, same as any other tool failure).

  ## Mid-mission steering (docs/spec-v1.md §10)

  `opts[:steering_fetch]`, a zero-arg function, is polled at the top of
  every turn — including the first, and every turn a fetch-approval
  resume continues into via `continue_after_tool/4` — which is this
  module's one real "between model turns" boundary. A non-empty return
  (delivering the caller's queued steering, e.g. `Sprat.Steering.take_pending/3`,
  and marking it delivered as a side effect) is folded into `state.messages`
  as one clearly-marked `"user"` message (`Sprat.Steering.turn_note/1`)
  before that turn's request is built, so the model sees it before
  deciding anything that turn. Absent (nil, the default for every caller
  that doesn't pass it) or always-`[]`, this is a no-op — existing callers
  and every test that never mentions steering are unaffected.
  """

  alias Sprat.Model.Pricing
  alias Sprat.Store.{Events, Usage}
  alias Sprat.Budget

  @default_max_turns 20
  @default_max_tokens 4_096

  @type opts :: %{
          required(:model_mod) => module(),
          required(:model_id) => String.t(),
          required(:role_prompt) => String.t(),
          required(:context_package) => String.t(),
          required(:tools) => [module()],
          required(:session_id) => String.t(),
          required(:mission_id) => String.t(),
          required(:task_id) => String.t(),
          optional(:attempt) => integer(),
          optional(:agent_id) => String.t(),
          optional(:store) => term(),
          optional(:tool_context) => map(),
          optional(:budget) => module() | pid() | atom(),
          optional(:max_turns) => pos_integer(),
          optional(:max_tokens) => pos_integer(),
          optional(:on_delta) => (map() -> any()),
          optional(:cancel?) => (-> boolean()),
          optional(:on_turn_end) => (map() -> any()),
          optional(:api_key) => String.t(),
          optional(:catalog) => Sprat.Model.Pricing.t()
        }

  @doc """
  Runs the loop. Returns:

    * `{:ok, %{content:, turns:}}` — final answer
    * `{:needs_approval, request, %{turns:}}` — a tool call is waiting on
      approval; the caller resumes by calling `run/1` again with the tool
      result substituted in (out of scope here, see moduledoc)
    * `{:cancelled, %{turns:}}`
    * `{:error, reason}` — `:max_turns_exceeded`, `:budget_exceeded`,
      `:price_unknown`, or whatever the model adapter returned
  """
  def run(opts) do
    store = Map.get(opts, :store, Sprat.Store)
    budget = Map.get(opts, :budget, Sprat.Budget)
    max_turns = Map.get(opts, :max_turns, @default_max_turns)
    max_tokens = Map.get(opts, :max_tokens, @default_max_tokens)
    tools = Map.get(opts, :tools, [])
    tool_context = Map.get(opts, :tool_context, %{})

    messages = [
      %{"role" => "system", "content" => opts.role_prompt},
      %{"role" => "user", "content" => opts.context_package}
    ]

    state = %{
      store: store,
      budget: budget,
      opts: opts,
      max_tokens: max_tokens,
      tools: tools,
      tool_context: tool_context,
      messages: messages,
      turns: 0,
      catalog: Map.get(opts, :catalog) || Pricing.load()
    }

    loop(state, max_turns)
  end

  @doc """
  Resumes a loop paused by `{:needs_approval, request, resume}`, deciding
  `decision`:

    * `{:approved, tool_context_patch}` — merges `tool_context_patch` into
      the task's tool context, retries the tool call that needed approval,
      then continues with the rest of that turn's tool calls and the loop
    * `:denied` — the tool call is recorded as a denied error and the loop
      continues with the rest of that turn's tool calls

  Returns exactly what `run/1` returns.
  """
  def resume(resume, decision, max_turns \\ @default_max_turns)

  def resume(%{state: state, tool_call: tc} = resume, {:approved, patch}, max_turns) do
    tool_context = Map.merge(state.tool_context, patch || %{})
    state = %{state | tool_context: tool_context}

    case safe_tool_call(find_tool(state.tools, tc.name), tc.arguments, tool_context) do
      {:needs_approval, request} ->
        emit(state, "tool.approval_requested", %{payload: %{tool: tc.name, request: request}})
        {:needs_approval, approval_request(request, tc), %{resume | state: state}}

      result ->
        emit(state, "tool.completed", %{payload: completion_payload(tc, result)})

        continue_after_tool(state, resume, tool_result_message(tc.id, result), max_turns)
    end
  end

  def resume(%{tool_call: tc} = resume, :denied, max_turns) do
    emit(resume.state, "tool.completed", %{
      payload: %{tool: tc.name, tool_call_id: tc.id, ok?: false}
    })

    message =
      tool_result_message(
        tc.id,
        {:error,
         %{
           "kind" => "denied_by_user",
           "message" =>
             "the user declined to approve this fetch. This is not evidence the URL or " <>
               "domain doesn't exist — ask the user, or continue without it."
         }}
      )

    continue_after_tool(resume.state, resume, message, max_turns)
  end

  defp continue_after_tool(
         state,
         %{assistant_message: am, acc: acc, remaining: []},
         message,
         max_turns
       ) do
    messages = state.messages ++ [am] ++ Enum.reverse([message | acc])
    loop(%{state | messages: messages}, max_turns)
  end

  defp continue_after_tool(
         state,
         %{assistant_message: am, acc: acc, remaining: remaining},
         message,
         max_turns
       ) do
    case run_each_tool_call(state, remaining, [message | acc]) do
      {:ok, tool_messages} ->
        messages = state.messages ++ [am] ++ tool_messages
        loop(%{state | messages: messages}, max_turns)

      {:needs_approval, request, tc2, acc2, rest2} ->
        {:needs_approval, approval_request(request, tc2),
         %{state: state, assistant_message: am, acc: acc2, remaining: rest2, tool_call: tc2}}
    end
  end

  defp loop(state, max_turns) do
    if state.turns >= max_turns do
      {:error, :max_turns_exceeded}
    else
      state = inject_steering(state)
      run_turn(%{state | turns: state.turns + 1}, max_turns)
    end
  end

  # See the moduledoc's "Mid-mission steering" section. `steering_fetch`
  # both returns and (as a side effect, in whatever it wraps —
  # `Sprat.Steering.take_pending/3`) marks its result delivered, so this
  # must run at most once per turn and never be retried/re-derived —
  # exactly what calling it here, once, right before `run_turn/2` builds
  # that turn's request, guarantees.
  defp inject_steering(state) do
    case Map.get(state.opts, :steering_fetch) do
      nil ->
        state

      fetch ->
        case fetch.() do
          texts when is_list(texts) and texts != [] ->
            note = %{"role" => "user", "content" => Sprat.Steering.turn_note(texts)}
            %{state | messages: state.messages ++ [note]}

          _ ->
            state
        end
    end
  end

  defp run_turn(state, max_turns) do
    opts = state.opts
    catalog = state.catalog
    entry = Pricing.find(catalog, opts.model_id)
    input_estimate = estimate_tokens(state.messages)
    worst_case = entry && Pricing.worst_case(entry, input_estimate, state.max_tokens)

    case reserve_budget(state, worst_case) do
      {:ok, reservation} ->
        call_model(state, entry, catalog, input_estimate, reservation, max_turns)

      {:error, reason} ->
        emit(state, "budget.limit_hit", %{payload: %{reason: inspect(reason)}})
        {:error, reason}
    end
  end

  defp call_model(state, entry, catalog, input_estimate, reservation, max_turns) do
    opts = state.opts
    request = %{model: opts.model_id, messages: state.messages, tools: tool_specs(state.tools)}
    correlation_id = generate_call_id()

    emit(state, "model.request", %{
      correlation_id: correlation_id,
      payload: %{model: opts.model_id, messages: state.messages}
    })

    on_delta = Map.get(opts, :on_delta, fn _ -> :ok end)
    cancel? = Map.get(opts, :cancel?, fn -> false end)
    model_opts = [on_delta: on_delta, cancel?: cancel?] ++ api_key_opt(opts)

    case opts.model_mod.stream(request, model_opts) do
      {:ok, response} ->
        handle_response(
          state,
          response,
          entry,
          catalog,
          input_estimate,
          reservation,
          correlation_id,
          max_turns
        )

      {:error, reason} ->
        Budget.release(state.budget, reservation)

        emit(state, "model.failed", %{
          correlation_id: correlation_id,
          payload: %{reason: inspect(reason)}
        })

        {:error, reason}
    end
  end

  defp reserve_budget(_state, nil), do: {:error, :price_unknown}

  defp reserve_budget(state, worst_case) do
    case Budget.reserve(state.budget, state.opts.mission_id, worst_case) do
      {:ok, ref} -> {:ok, ref}
      {:error, reason} -> {:error, reason}
    end
  end

  defp handle_response(
         state,
         response,
         _entry,
         catalog,
         input_estimate,
         reservation,
         correlation_id,
         max_turns
       ) do
    opts = state.opts
    interrupted? = response.stop_reason == :cancelled

    usage_attrs =
      opts.model_mod.normalize_usage(response.usage, %{
        model: opts.model_id,
        interrupted?: interrupted?,
        local_input_tokens: input_estimate,
        streamed_output_estimate: estimate_output_tokens(response),
        catalog: catalog
      })

    record_usage(state, usage_attrs, correlation_id)
    Budget.settle(state.budget, reservation)

    emit(state, "model.response", %{
      correlation_id: correlation_id,
      payload: %{
        stop_reason: to_string(response.stop_reason),
        content: response.content,
        tool_calls: response.tool_calls
      }
    })

    warn_if_near_budget(state)

    # Fires exactly once per completed turn, regardless of how it ends
    # (final answer, tool calls, or cancellation) — the Orchestrator's
    # stall detector (docs/spec-v1.md §8) hooks in here to update its
    # progress snapshot. Right after it runs is also the only point,
    # besides the model adapter's own mid-stream polling, where `cancel?`
    # is re-checked: a stub/offline model never polls `cancel?` mid-turn
    # (see `Sprat.StubModel`), so without this a caller flipping `cancel?`
    # to true from inside `on_turn_end` — as the stall detector does —
    # would never actually stop the loop between turns.
    on_turn_end = Map.get(opts, :on_turn_end, fn _ -> :ok end)
    on_turn_end.(%{turn: state.turns})
    cancel? = Map.get(opts, :cancel?, fn -> false end)

    cond do
      interrupted? ->
        {:cancelled, %{turns: state.turns}}

      cancel?.() ->
        {:cancelled, %{turns: state.turns}}

      response.stop_reason == :tool_calls and response.tool_calls != [] ->
        run_tool_calls(state, response, max_turns)

      true ->
        {:ok, %{content: response.content, turns: state.turns, stop_reason: response.stop_reason}}
    end
  end

  defp run_tool_calls(state, response, max_turns) do
    assistant_message = %{
      "role" => "assistant",
      "content" => response.content,
      "tool_calls" =>
        Enum.map(response.tool_calls, fn tc ->
          %{
            "id" => tc.id,
            "type" => "function",
            "function" => %{"name" => tc.name, "arguments" => JSON.encode!(tc.arguments)}
          }
        end)
    }

    case run_each_tool_call(state, response.tool_calls) do
      {:ok, tool_messages} ->
        messages = state.messages ++ [assistant_message] ++ tool_messages
        loop(%{state | messages: messages}, max_turns)

      {:needs_approval, request, tc, acc, remaining} ->
        {:needs_approval, approval_request(request, tc),
         %{
           state: state,
           assistant_message: assistant_message,
           acc: acc,
           remaining: remaining,
           tool_call: tc
         }}
    end
  end

  defp approval_request(request, tc),
    do: Map.merge(request, %{tool: tc.name, tool_call_id: tc.id, arguments: tc.arguments})

  defp run_each_tool_call(state, tool_calls, acc \\ [])
  defp run_each_tool_call(_state, [], acc), do: {:ok, Enum.reverse(acc)}

  defp run_each_tool_call(state, [tc | rest], acc) do
    emit(state, "tool.requested", %{
      payload: %{tool: tc.name, arguments: tc.arguments, tool_call_id: tc.id}
    })

    case find_tool(state.tools, tc.name) do
      nil ->
        message = tool_result_message(tc.id, {:error, "unknown tool: #{tc.name}"})

        emit(state, "tool.completed", %{
          payload: %{tool: tc.name, tool_call_id: tc.id, ok?: false}
        })

        run_each_tool_call(state, rest, [message | acc])

      tool_mod ->
        case safe_tool_call(tool_mod, tc.arguments, state.tool_context) do
          {:needs_approval, request} ->
            emit(state, "tool.approval_requested", %{payload: %{tool: tc.name, request: request}})
            {:needs_approval, request, tc, acc, rest}

          result ->
            emit(state, "tool.completed", %{payload: completion_payload(tc, result)})

            run_each_tool_call(state, rest, [tool_result_message(tc.id, result) | acc])
        end
    end
  end

  # A failed tool call must record WHY, not just that it failed: a live
  # staged mission logged `ok?: false` for every web_search call and the
  # debug view could not say that the search model was simply unconfigured.
  defp completion_payload(tc, {:ok, _}),
    do: %{tool: tc.name, tool_call_id: tc.id, ok?: true}

  # Any structured field beyond "kind"/"message" (e.g. `write_artifact`'s
  # "artifact_type") rides along under its own key — so a caller like
  # `Sprat.Orchestrator`'s same-type-reject tracking (docs/spec-v1.md §8)
  # can read it off the event without re-parsing the message text.
  defp completion_payload(tc, {:error, %{"kind" => kind} = err}) do
    %{
      tool: tc.name,
      tool_call_id: tc.id,
      ok?: false,
      error_kind: kind,
      error: Map.get(err, "message")
    }
    |> Map.merge(err |> Map.drop(["kind", "message"]) |> atomize_keys())
  end

  defp completion_payload(tc, {:error, reason}),
    do: %{
      tool: tc.name,
      tool_call_id: tc.id,
      ok?: false,
      error: if(is_binary(reason), do: reason, else: inspect(reason))
    }

  defp completion_payload(tc, other),
    do: %{tool: tc.name, tool_call_id: tc.id, ok?: false, error: inspect(other)}

  defp find_tool(tools, name), do: Enum.find(tools, &(&1.name() == name))

  # Keys here are always our own tools' fixed error-map keys (e.g.
  # `"artifact_type"`), never arbitrary model input, so `String.to_atom/1`
  # is safe — it isn't the model choosing what atom gets created.
  defp atomize_keys(map), do: Map.new(map, fn {k, v} -> {String.to_atom(k), v} end)

  # A tool implementation crashing (a real one: `record_claim` hard-matched
  # `{:ok, claim} = Claims.record(...)`, which raised a `MatchError` and
  # took the whole mission `Task` down the instant a model cited a source
  # id that failed the `claim_sources` foreign key) must never crash the
  # agent loop — "no crash may ever reach the user's screen, whatever the
  # path" (docs/spec-v1.md §13). One rescue here covers every tool,
  # present and future, instead of every tool needing its own.
  defp safe_tool_call(tool_mod, args, context) do
    tool_mod.call(args, context)
  rescue
    error ->
      {:error,
       %{
         "kind" => "tool_error",
         "message" => "#{inspect(tool_mod)} failed unexpectedly: #{Exception.message(error)}"
       }}
  end

  defp tool_result_message(tool_call_id, {:ok, result}) do
    %{"role" => "tool", "tool_call_id" => tool_call_id, "content" => JSON.encode!(result)}
  end

  defp tool_result_message(tool_call_id, {:error, reason}) do
    %{
      "role" => "tool",
      "tool_call_id" => tool_call_id,
      "content" => JSON.encode!(%{"error" => to_error_payload(reason)})
    }
  end

  # A tool's `{:error, reason}` may already be structured (a `%{"kind" =>
  # ..., "message" => ...}` map — see `Sprat.Agent.Tools.WebFetch`) so the
  # model can tell a network error apart from a refusal or a 404, rather
  # than every failure reading as the same flat string.
  defp to_error_payload(%{"kind" => _} = reason), do: reason

  defp to_error_payload(reason) when is_binary(reason),
    do: %{"kind" => "error", "message" => reason}

  defp to_error_payload(reason), do: %{"kind" => "error", "message" => inspect(reason)}

  defp tool_specs(tools), do: Enum.map(tools, & &1.spec())

  defp record_usage(state, usage_attrs, correlation_id) do
    opts = state.opts

    attrs =
      Map.merge(usage_attrs, %{
        task_id: opts.task_id,
        mission_id: opts.mission_id,
        role_instance: Map.get(opts, :agent_id),
        attempt: Map.get(opts, :attempt),
        provider: usage_attrs[:provider] || "openai",
        request_id: correlation_id,
        started_at: nil,
        first_token_at: nil,
        ended_at: DateTime.utc_now() |> DateTime.to_iso8601()
      })

    Usage.record(state.store, attrs)
  end

  defp warn_if_near_budget(state) do
    status = Budget.status(state.budget, state.opts.mission_id)

    if status.warn? do
      emit(state, "budget.warning", %{payload: %{percent_used: status.percent_used}})
    end
  end

  defp emit(state, type, attrs) do
    opts = state.opts
    secrets = Sprat.Secrets.redaction_set()

    full_attrs =
      Map.merge(
        %{
          mission_id: opts.mission_id,
          task_id: opts.task_id,
          attempt: Map.get(opts, :attempt),
          agent_id: Map.get(opts, :agent_id)
        },
        attrs
      )

    Events.append(state.store, opts.session_id, type, full_attrs, secrets)
  end

  defp api_key_opt(%{api_key: key}), do: [api_key: key]
  defp api_key_opt(_), do: []

  # Rough local token estimate (chars/4) — used only for the pre-call
  # budget worst-case, never recorded as a usage figure. Real usage always
  # comes from the provider's own report when available.
  defp estimate_tokens(messages) do
    messages
    |> Enum.map(fn m -> content_length(Map.get(m, "content")) end)
    |> Enum.sum()
    |> div(4)
    |> max(1)
  end

  defp content_length(content) when is_binary(content), do: byte_size(content)
  defp content_length(content) when is_list(content), do: content |> JSON.encode!() |> byte_size()
  defp content_length(_), do: 0

  defp estimate_output_tokens(%{content: content}) when is_binary(content),
    do: max(div(byte_size(content), 4), 1)

  defp estimate_output_tokens(_), do: nil

  defp generate_call_id,
    do: "call_" <> (:crypto.strong_rand_bytes(8) |> Base.url_encode64(padding: false))
end
