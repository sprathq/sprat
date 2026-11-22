defmodule Sprat.Debug do
  @moduledoc """
  Pure query helpers behind the Debug/audit surface (`Alt+d`/`d`, `/debug`):
  Requests, Tools, Events, Costs, Logs. Everything here reads through
  existing store modules — `Sprat.Store.Usage`/`Sprat.Store.Events` — and
  never synthesises a number: a leaf `Sprat.Store.Usage` record is the
  Requests row, `Sprat.Store.Usage.totals/1` (never re-summed, per
  docs/spec-v1.md §12) is Costs, and `Sprat.Store.Events` filtered by type
  is Tools/Events. `Sprat.Store.Redact` has already scrubbed every payload
  by the time it reaches these functions (`Sprat.Store.Events.append/5`
  scrubs on write, not on read) — this module adds no new redaction
  boundary, it only reads what is already safe.
  """

  alias Sprat.Store.{Events, Usage}

  @doc """
  One row per model call for a mission's Requests tab, newest first:
  the leaf `Usage` record plus its coverage/pricing already carry
  everything the design's table asks for except duration/TTFT, which come
  from the matching `model.request`/`model.response` event pair (same
  `correlation_id` as the usage record's `request_id`).
  """
  def requests(store \\ Sprat.Store, mission_id) do
    store
    |> Usage.by_mission(mission_id)
    |> Enum.sort_by(& &1.ended_at, :desc)
    |> Enum.map(&request_row(store, &1))
  end

  defp request_row(store, usage) do
    events = events_for_correlation(store, usage.task_id, usage.request_id)
    request_event = Enum.find(events, &(&1.type == "model.request"))
    response_event = Enum.find(events, &(&1.type == "model.response"))
    failed_event = Enum.find(events, &(&1.type == "model.failed"))

    %{
      usage: usage,
      request_event: request_event,
      response_event: response_event,
      stop_reason: response_event && response_payload(response_event)["stop_reason"],
      failed?: failed_event != nil
    }
  end

  @doc "Full redacted request/response payload for one Requests row, for the detail pane. `nil` fields mean the event (or its blob) is gone, not that it never existed — said honestly by the caller, never rendered as empty JSON."
  def request_detail(store \\ Sprat.Store, %{request_event: req, response_event: resp}) do
    %{request: event_payload(store, req), response: event_payload(store, resp)}
  end

  defp events_for_correlation(store, task_id, request_id) do
    store
    |> Events.by_task(task_id, limit: 100_000)
    |> Enum.filter(&(&1.correlation_id == request_id))
  end

  defp response_payload(event), do: (event.payload && JSON.decode!(event.payload)) || %{}

  defp event_payload(_store, nil), do: nil

  defp event_payload(_store, %Events{payload: payload}) when is_binary(payload),
    do: JSON.decode!(payload)

  defp event_payload(_store, %Events{payload_ref: "blob:sha256:" <> hash}) do
    case Sprat.Store.Blob.get(hash, Sprat.Store.Paths.blobs_dir()) do
      {:ok, bytes} -> JSON.decode!(bytes)
      {:error, :not_found} -> nil
    end
  end

  defp event_payload(_store, _event), do: nil

  @doc """
  One row per tool call for a mission's Tools tab: `tool.requested` paired
  with its `tool.completed` (or left `nil` if the mission ended mid-call —
  shown as "no result recorded", never guessed).
  """
  def tool_calls(store \\ Sprat.Store, tasks) do
    tasks
    |> Enum.flat_map(&Events.by_task(store, &1.id, limit: 100_000))
    |> Enum.filter(&(&1.type in ["tool.requested", "tool.completed"]))
    |> Enum.group_by(&tool_call_id/1)
    |> Enum.reject(fn {id, _} -> is_nil(id) end)
    |> Enum.map(fn {_id, events} -> tool_row(events) end)
    |> Enum.sort_by(& &1.requested.occurred_at, :desc)
  end

  defp tool_call_id(event), do: response_payload(event)["tool_call_id"]

  defp tool_row(events) do
    requested = Enum.find(events, &(&1.type == "tool.requested"))
    completed = Enum.find(events, &(&1.type == "tool.completed"))

    %{
      requested: requested,
      completed: completed,
      name: response_payload(requested)["tool"],
      ok?: completed && response_payload(completed)["ok?"]
    }
  end

  @doc "Redacted full input/output for one Tools row's detail pane."
  def tool_detail(store \\ Sprat.Store, %{requested: req, completed: completed}) do
    %{input: event_payload(store, req), result: completed && event_payload(store, completed)}
  end

  @doc """
  Cost totals for the Costs tab: per-task and mission-level, both computed
  straight from `Sprat.Store.Usage.totals/1` over that task's/mission's own
  leaf records — never a sum of the per-task totals, matching §12's
  explicit rule. `unknown_calls` counts leaf records with `coverage !=
  "reported"` so the UI can label the total as partial without averaging
  anything.
  """
  def costs(store \\ Sprat.Store, mission_id, tasks) do
    mission_records = Usage.by_mission(store, mission_id)

    per_task =
      Enum.map(tasks, fn task ->
        records = Enum.filter(mission_records, &(&1.task_id == task.id))
        %{task: task, totals: Usage.totals(records)}
      end)

    %{
      mission_totals: Usage.totals(mission_records),
      per_task: per_task,
      unknown_or_estimated: Enum.count(mission_records, &(&1.coverage != "reported")),
      pricing_version: mission_records |> Enum.map(& &1.pricing_version) |> Enum.find(& &1)
    }
  end

  @doc "Raw §11 event timeline for a session, optionally filtered by a substring of `type` and/or a task id — the audit view underneath everything else here."
  def events(store \\ Sprat.Store, session_id, opts \\ []) do
    type_filter = Keyword.get(opts, :type)
    task_filter = Keyword.get(opts, :task_id)
    search = Keyword.get(opts, :search)

    store
    |> Events.by_session(session_id, limit: 100_000)
    |> Enum.filter(&(is_nil(type_filter) or String.contains?(&1.type, type_filter)))
    |> Enum.filter(&(is_nil(task_filter) or &1.task_id == task_filter))
    |> Enum.filter(&(is_nil(search) or matches_search?(&1, search)))
    |> Enum.reverse()
  end

  defp matches_search?(event, search) do
    haystack = "#{event.type} #{event.payload}"
    String.contains?(String.downcase(haystack || ""), String.downcase(search))
  end
end
