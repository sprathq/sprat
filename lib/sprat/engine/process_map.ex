defmodule Sprat.Engine.ProcessMap do
  @moduledoc """
  Sprat's own processes as the board's processes screen draws them: the
  supervision tree of `sprat serve` (the engine's supervisor, the observers,
  every session's and project's watcher, the tasks running jobs and
  investigations, the door boards connect through), each with its mailbox,
  memory and reductions, and the messages they sent each other in the last
  sample (`Sprat.Engine.Tracer`).

  Workers name themselves with `label/1` (a session's watcher, an
  investigation): the name a person reads instead of a pid.
  """

  @label :"$sprat_label"
  @ref :"$sprat_ref"
  @did :"$sprat_did"
  @beats :"$sprat_beats"

  @roots [
    {Sprat.Engine.Supervisor, "sprat serve"},
    {Sprat.Engine.Door, "door"}
  ]

  @doc "Names the calling process on the processes screen."
  def label(text) when is_binary(text), do: Process.put(@label, text)

  @doc """
  What the calling process stands for, for the board to show it as the
  thing a person knows: `{:session, sid}`, `{:project, root}`,
  `{:investigation, root}`, `:board`.
  """
  def ref(term), do: Process.put(@ref, term)

  @doc "What the calling process's session did lately (`Sprat.Engine.Beats`)."
  def beats(list) when is_list(list), do: Process.put(@beats, list)

  @doc "The last thing the calling process did, in words (\"read 4 new lines\")."
  def did(text) when is_binary(text),
    do: Process.put(@did, {text, System.monotonic_time(:millisecond)})

  @doc """
  `%{nodes: [node], flows: [flow], processes: n, memory_mb: n, at: ms}`.

  A node is `%{id, parent, depth, name, kind, queue, memory_kb, reductions,
  ref, did, did_ago_ms, beats}` (`kind` is `:supervisor`, `:worker` or `:task`;
  `ref` what it stands for, `did` the last thing it said it did and how long
  ago), in tree order. A flow is
  `%{from, to, count, tag}`: messages one node sent another in the last
  sample, `tag` the most common kind ("call", "cast", "snapshot", …).
  """
  def snapshot(opts \\ []) do
    nodes =
      opts
      |> Keyword.get(:roots, @roots)
      |> Enum.flat_map(fn {name, label} ->
        case Process.whereis(name) do
          nil -> []
          pid -> walk(pid, label, nil, 0, :supervisor)
        end
      end)

    flows =
      case Keyword.get(opts, :tracer, Sprat.Engine.Tracer) do
        nil -> []
        tracer -> Sprat.Engine.Tracer.flows(tracer, Enum.map(nodes, & &1.pid))
      end

    ids = MapSet.new(nodes, & &1.id)

    %{
      nodes: Enum.map(nodes, &Map.delete(&1, :pid)),
      flows: Enum.filter(flows, &(MapSet.member?(ids, &1.from) and MapSet.member?(ids, &1.to))),
      processes: :erlang.system_info(:process_count),
      wall_ms: System.os_time(:millisecond),
      memory_mb: div(:erlang.memory(:total), 1_048_576),
      at: System.monotonic_time(:millisecond)
    }
  end

  @doc "The id a pid has on the screen."
  def id(pid) when is_pid(pid), do: pid |> :erlang.pid_to_list() |> to_string()

  # -- the tree -------------------------------------------------------------------

  defp walk(pid, name, parent, depth, kind) do
    me = node(pid, name, parent, depth, kind)
    tasks? = Process.whereis(Sprat.Engine.TaskSupervisor) == pid

    children =
      case kind do
        :supervisor ->
          pid
          |> children()
          |> Enum.flat_map(fn {child_id, child, type} ->
            kind = if tasks?, do: :task, else: child_kind(child_id, type)
            walk(child, child_name(child_id, child), me.id, depth + 1, kind)
          end)

        # A registry's partitions are its own business.
        :registry ->
          []

        _ ->
          owned(pid)
          |> Enum.flat_map(&walk(&1, "worker", me.id, depth + 1, :worker))
      end

    [me | children]
  end

  # Processes a worker started and linked to itself, outside any supervisor
  # (the socket's connections, one per board): shown under it when they
  # carry a label.
  defp owned(pid) do
    case Process.info(pid, :links) do
      {:links, links} -> Enum.filter(links, &owned_by?(&1, pid))
      _ -> []
    end
  end

  defp owned_by?(link, pid) when is_pid(link) do
    case Process.info(link, :dictionary) do
      {:dictionary, d} ->
        dict(d, @label) != nil and List.first(dict(d, :"$ancestors") || []) in names(pid)

      _ ->
        false
    end
  end

  defp owned_by?(_link, _pid), do: false

  # A process started by a registered one lists its parent by name.
  defp names(pid) do
    case Process.info(pid, :registered_name) do
      {:registered_name, name} when is_atom(name) -> [pid, name]
      _ -> [pid]
    end
  end

  defp dict(d, key) do
    case List.keyfind(d, key, 0) do
      {_, v} -> v
      nil -> nil
    end
  end

  defp children(pid) do
    pid
    |> Supervisor.which_children()
    |> Enum.reverse()
    |> Enum.flat_map(fn
      {id, child, type, _} when is_pid(child) -> [{id, child, type}]
      _ -> []
    end)
  catch
    :exit, _ -> []
  end

  defp node(pid, name, parent, depth, kind) do
    info = Process.info(pid, [:message_queue_len, :memory, :reductions, :dictionary]) || []
    d = info[:dictionary] || []

    {did, did_ago} =
      case dict(d, @did) do
        {text, at} -> {text, max(System.monotonic_time(:millisecond) - at, 0)}
        _ -> {nil, nil}
      end

    %{
      pid: pid,
      id: id(pid),
      parent: parent,
      depth: depth,
      name: dict(d, @label) || name,
      ref: dict(d, @ref),
      did: did,
      did_ago_ms: did_ago,
      beats: dict(d, @beats) || [],
      kind: if(kind == :registry, do: :worker, else: kind),
      queue: info[:message_queue_len] || 0,
      memory_kb: div(info[:memory] || 0, 1024),
      reductions: info[:reductions] || 0
    }
  end

  defp child_kind(id, _type)
       when id in [
              Sprat.Observer.SessionRegistry,
              Sprat.Observer.ProjectRegistry,
              Sprat.Activity.Registry
            ],
       do: :registry

  defp child_kind(_id, :supervisor), do: :supervisor
  defp child_kind(_id, _type), do: :worker

  defp child_name(:undefined, pid) do
    case Process.info(pid, :registered_name) do
      {:registered_name, name} when is_atom(name) and name != [] -> short(name)
      _ -> "worker"
    end
  end

  defp child_name(id, _pid), do: short(id)

  @names %{
    Sprat.Engine => "engine",
    Sprat.Engine.TaskSupervisor => "tasks",
    Sprat.Engine.Publisher => "publisher",
    Sprat.Engine.Socket => "socket",
    Sprat.Engine.Tracer => "tracer",
    Sprat.Observer.Store => "store",
    Sprat.Observer.Supervisor => "observers",
    Sprat.Observer.Live => "live tables",
    Sprat.Observer.SessionRegistry => "session names",
    Sprat.Observer.ProjectRegistry => "project names",
    Sprat.Observer.SessionSupervisor => "sessions",
    Sprat.Observer.ProjectSupervisor => "projects",
    Sprat.Observer.Accounts => "accounts",
    Sprat.Observer.Cmux => "cmux",
    Sprat.Observer.Sessions => "session scan",
    Sprat.Activity => "activity",
    Sprat.Activity.Registry => "subscribers"
  }

  defp short(id) do
    Map.get_lazy(@names, id, fn ->
      id |> inspect() |> String.replace_prefix("Sprat.", "") |> String.replace_prefix(":", "")
    end)
  end
end
