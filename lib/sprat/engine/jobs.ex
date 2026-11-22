defmodule Sprat.Engine.Jobs do
  @moduledoc """
  Work the engine does outside its own process, in sight (spec-v5 §4).

  A job is a function run under `Sprat.Engine.TaskSupervisor`, given a
  `step.(text)` callback it calls as it goes. The engine keeps the job table:
  each job's kind, project, label, current step and outcome, so the board can
  show what Sprat is doing while it does it, and what came of it after.

  The body never touches engine state. It returns `{:ok, text}` or
  `{:error, text}`; the engine then runs the job's `on_done` with that
  result, so only the process that owns the data changes it, and a failed or
  crashed job changes nothing but its own record.
  """

  require Logger

  alias Sprat.Observer.Store

  @kept 200

  defmodule Job do
    @moduledoc "One job: what it is, where it is, how it ended."
    defstruct [
      :id,
      :kind,
      :label,
      :project_root,
      :session_id,
      :ticket_id,
      :step,
      :result,
      :started_at,
      :finished_at,
      status: :running,
      steps: []
    ]

    @type t :: %__MODULE__{}
  end

  @doc "The fields the engine state needs."
  def init_state, do: %{jobs: %{}, job_refs: %{}, job_done: %{}, job_seq: 0}

  @doc """
  Starts `body` as a job. `attrs`: `:kind`, `:label`, `:project_root`,
  `:session_id`, `:ticket_id`. `on_done.(state, result, job)` runs in the
  engine when the body returns (or crashes, as `{:error, reason}`).
  Returns `{job, state}`.
  """
  def start(state, attrs, body, on_done, now) do
    seq = state.job_seq + 1
    id = "job-#{seq}"
    engine = self()
    step = fn text -> send(engine, {:job_step, id, to_string(text)}) end
    sup = Keyword.get(state.opts, :task_supervisor, Sprat.Engine.TaskSupervisor)
    name = attrs[:label] || to_string(attrs[:kind] || "job")

    task =
      Task.Supervisor.async_nolink(sup, fn ->
        Sprat.Engine.ProcessMap.label(name)
        body.(step)
      end)

    job = %Job{
      id: id,
      kind: attrs[:kind],
      label: attrs[:label],
      project_root: attrs[:project_root],
      session_id: attrs[:session_id],
      ticket_id: attrs[:ticket_id],
      started_at: now
    }

    Store.log_event(state.store, :job_started, %{job: id, kind: job.kind, label: job.label}, now)

    Sprat.Activity.emit(:job,
      type: :started,
      project_root: job.project_root,
      text: "started: " <> (job.label || to_string(job.kind)),
      status: :running
    )

    state = %{
      state
      | jobs: Map.put(state.jobs, id, job),
        job_refs: Map.put(state.job_refs, task.ref, id),
        job_done: Map.put(state.job_done, id, on_done),
        job_seq: seq
    }

    {job, state}
  end

  @doc "Records a step the job reported."
  def step(state, id, text, now) do
    case Map.get(state.jobs, id) do
      %Job{status: :running} = job ->
        job = %{job | step: text, steps: job.steps ++ [{now, text}]}

        # Progress counters ("82/153 MB") update the job, not the stream.
        unless job.steps |> Enum.drop(-1) |> Enum.any?(fn {_, t} -> same_step?(t, text) end) do
          Sprat.Activity.emit(:job,
            type: :step,
            project_root: job.project_root,
            text: (job.label || "job") <> " · " <> text,
            status: :running
          )
        end

        %{state | jobs: Map.put(state.jobs, id, job)}

      _ ->
        state
    end
  end

  @doc """
  A task reply or `:DOWN` for `ref`: `{:ok, state}` when it was a job's,
  `:error` when the ref is not a job's.
  """
  def finish(state, ref, result, now) do
    case Map.pop(state.job_refs, ref) do
      {nil, _} ->
        :error

      {id, refs} ->
        Process.demonitor(ref, [:flush])
        job = Map.fetch!(state.jobs, id)
        result = normalize(result)
        {status, text} = result

        job = %{
          job
          | status: if(status == :ok, do: :done, else: :failed),
            result: text,
            finished_at: now
        }

        Store.log_event(
          state.store,
          :job_done,
          %{job: id, kind: job.kind, status: job.status, result: text},
          now
        )

        Sprat.Activity.emit(:job,
          type: job.status,
          project_root: job.project_root,
          text: (job.label || to_string(job.kind)) <> " · " <> text,
          status: if(job.status == :done, do: :ok, else: :failed)
        )

        {on_done, done} = Map.pop(state.job_done, id)
        state = %{state | jobs: Map.put(state.jobs, id, job), job_refs: refs, job_done: done}

        state =
          try do
            if on_done, do: on_done.(state, result, job), else: state
          rescue
            e ->
              Logger.error("sprat job #{id} on_done: " <> Exception.message(e))
              state
          end

        {:ok, prune(state)}
    end
  end

  @doc "Jobs newest first: every running one, and finished ones within `keep_s`."
  def recent(state, now, keep_s \\ 600) do
    state.jobs
    |> Map.values()
    |> Enum.filter(fn j ->
      j.status == :running or DateTime.diff(now, j.finished_at || now) <= keep_s
    end)
    |> Enum.sort_by(&{&1.status != :running, -seq(&1)})
  end

  @doc "Whether any job is still running."
  def running?(state), do: Enum.any?(Map.values(state.jobs), &(&1.status == :running))

  defp same_step?(a, b), do: String.replace(a, ~r/\d+/, "#") == String.replace(b, ~r/\d+/, "#")

  defp normalize({:ok, text}), do: {:ok, to_string(text)}
  defp normalize({:error, text}) when is_binary(text), do: {:error, text}
  defp normalize({:error, other}), do: {:error, inspect(other, limit: 5)}
  defp normalize({:crashed, reason}), do: {:error, "crashed: " <> crash_text(reason)}
  defp normalize(other), do: {:ok, inspect(other, limit: 5)}

  defp crash_text({e, _stack}) when is_exception(e), do: Exception.message(e)
  defp crash_text(reason), do: inspect(reason, limit: 5)

  defp seq(%Job{id: "job-" <> n}), do: String.to_integer(n)

  defp prune(state) do
    finished = state.jobs |> Map.values() |> Enum.reject(&(&1.status == :running))

    if length(finished) > @kept do
      drop = finished |> Enum.sort_by(&seq/1) |> Enum.take(length(finished) - @kept)
      %{state | jobs: Map.drop(state.jobs, Enum.map(drop, & &1.id))}
    else
      state
    end
  end
end
