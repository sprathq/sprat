defmodule Sprat.Roadmap do
  @moduledoc """
  A project's roadmap (spec-v4 §5): built from its sources, normalised into
  `.sprat/roadmap.md`, marked by the PM, reverted by the owner.

  `build/2` reads files but never writes. `write/2`, `mark/5` and `revert/2`
  are the only writers, and only ever touch `.sprat/` under the root.

  ## How `build/2` merges (spec §5.1, by authority)

    1. `.sprat/roadmap.md`, when it exists, is the roadmap (`confirmed?:
       true`). Each phase with a `source:` re-syncs from that source: lines
       the owner edited are kept as written; other lines take the source's
       text; an item done or blocked in the file stays so (marks are explicit
       actions), and an item the source ticks becomes done.
    2. Without it, a proposal: the PAUSE.md resume list first (it is the
       current position), then the open plans and the newest spec with
       phases, most recently touched first, each source a block. Completed
       plans (all items done) collapse to one done phase each and go first,
       as history. Only the `max_plans` (6) most recent plan files count.
    3. Disagreements are never resolved silently: they go into `notes`.

  ## Options

    * `:globs` — source globs (see `Sprat.Roadmap.Sources`)
    * `:max_plans` — how many recent plan files count (default 6)
    * `:infer_fun` — `fn text -> [Phase] | nil end` for unstructured docs;
      the default infers nothing
    * `:commits` — `[%{sha, at, subject, branches}]` from git; an item whose
      plan quotes a commit message that one of these subjects matches is done
    * `:now` — the clock
  """

  alias Sprat.Observer.Model.{Item, Phase, Roadmap}
  alias Sprat.Roadmap.{Ids, Position, Progress, Sources}
  alias Sprat.Roadmap.File, as: RFile
  alias Sprat.Roadmap.Markdown, as: Md
  alias Sprat.Roadmap.Parser

  @max_plans 6
  @root_plan_names ~w(PLAN.md TODO.md ROADMAP.md)

  @type write_record :: %{
          item_id: String.t(),
          from: Item.state(),
          to: Item.state(),
          reason: String.t() | nil,
          from_reason: String.t() | nil,
          at: DateTime.t()
        }

  # ── build ────────────────────────────────────────────────────────────────

  @spec build(Path.t(), keyword()) :: Roadmap.t()
  @doc """
  Builds the roadmap with git evidence: commits from the last year (all
  branches) are passed to `build/2` so plan tasks whose quoted commit landed
  count as done. Returns `{roadmap, commits}` so callers can reuse the commits
  for progress events. This is what every runtime caller should use.
  """
  def load(root, opts \\ []) do
    now = Keyword.get(opts, :now, DateTime.utc_now())
    since = DateTime.add(now, -365 * 86_400, :second)

    commits =
      Keyword.get_lazy(opts, :commits, fn ->
        Sprat.Observer.Projects.commits_since(root, since, Keyword.take(opts, [:cmd]))
      end)

    {build(root, Keyword.merge(opts, commits: commits, now: now)), commits}
  end

  def build(root, opts \\ []) do
    now = Keyword.get(opts, :now, DateTime.utc_now())
    sources = Sources.discover(root, opts)
    subjects = commit_subjects(Keyword.get(opts, :commits))

    {parsed, notes} =
      sources
      |> Enum.reject(&(&1.kind == :sprat))
      |> Enum.map_reduce([], fn src, notes ->
        case parse_source(root, src, opts) do
          {:ok, result} -> {[Map.merge(src, result)], notes}
          {:error, reason} -> {[], notes ++ ["could not read #{src.path}: #{reason}"]}
        end
      end)

    parsed =
      parsed
      |> List.flatten()
      |> Enum.map(&apply_commit_evidence(&1, subjects))
      |> mark_referenced_plans_done()

    pause = Enum.find(parsed, &(&1.kind == :pause))

    all_plans = Enum.filter(parsed, &(&1.kind == :plan and &1.phases != []))

    plans =
      all_plans
      |> Enum.sort_by(&recency/1, :desc)
      |> Enum.take(Keyword.get(opts, :max_plans, @max_plans))

    spec =
      parsed
      |> Enum.filter(&(&1.kind == :spec and &1.phases != []))
      |> Enum.max_by(&recency/1, fn -> nil end)

    dropped = length(all_plans) - length(plans)

    notes =
      notes ++
        if(dropped > 0,
          do: [
            "#{dropped} older plan file(s) not counted (only the #{length(plans)} most recent are)"
          ],
          else: []
        )

    pause_info = pause && pause_info(pause, now)
    file_rm = RFile.read(root)

    rm =
      if file_rm do
        resync(file_rm, parsed)
      else
        propose(pause, plans, spec)
      end

    rm = %{rm | phases: Ids.assign(rm.phases)}

    notes =
      notes ++ rm.notes ++ pause_notes(rm, pause, pause_info, plans, spec, file_rm != nil, now)

    used =
      if file_rm,
        do: [".sprat/roadmap.md" | rm.phases |> Enum.map(& &1.source) |> Enum.reject(&is_nil/1)],
        else: rm.phases |> Enum.map(& &1.source) |> Enum.reject(&is_nil/1)

    %{
      rm
      | project_root: root,
        name: rm.name || Path.basename(root),
        sources: Enum.uniq(used),
        confirmed?: file_rm != nil,
        inferred?: Enum.any?(parsed, &Map.get(&1, :inferred?, false)),
        notes: Enum.uniq(notes),
        pause: pause_info
    }
  end

  # Plans are dated by the date in their file name when they carry one (the
  # day the plan was written; mtimes move on checkouts), else by mtime.
  defp recency(src) do
    named =
      case Regex.run(~r/(?:^|\/)(\d{4}-\d{2}-\d{2})[^\/]*$/, src.path) do
        [_, iso] ->
          Date.from_iso8601(iso)
          |> then(fn
            {:ok, d} -> d
            _ -> nil
          end)

        _ ->
          nil
      end

    day = named || DateTime.to_date(src.mtime)
    {Date.to_gregorian_days(day), DateTime.to_unix(src.mtime), src.path}
  end

  defp parse_source(root, src, opts) do
    with {:ok, text} <- File.read(Path.join(root, src.path)) do
      {:ok, parse_text(text, src, opts)}
    else
      {:error, reason} -> {:error, inspect(reason)}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp parse_text(text, %{kind: :pause, path: path}, _opts) do
    result = Parser.Pause.parse(text, source: path)

    phases =
      case result.items do
        [] -> []
        items -> [%Phase{id: nil, title: "Resume (PAUSE.md)", source: path, items: items}]
      end

    %{pause: result, phases: phases, title: "PAUSE.md"}
  end

  defp parse_text(text, %{kind: :spec, path: path}, opts) do
    case Parser.Spec.parse(text, source: path) do
      [] -> infer(text, path, opts, Path.basename(path))
      phases -> %{phases: phases, title: Path.basename(path)}
    end
  end

  defp parse_text(text, %{kind: :plan, path: path}, opts) do
    root_level? = Path.basename(path) in @root_plan_names and Path.dirname(path) == "."
    result = Parser.Plan.parse(text, source: path, status_lists: root_level?)

    cond do
      result.phases != [] -> %{phases: result.phases, title: result.title, mode: result.mode}
      root_level? -> infer(text, path, opts, result.title)
      true -> %{phases: [], title: result.title, mode: :none}
    end
  end

  defp infer(text, path, opts, title) do
    fun = Keyword.get(opts, :infer_fun, fn _text -> nil end)

    case fun.(text) do
      phases when is_list(phases) and phases != [] ->
        phases =
          Enum.map(phases, fn %Phase{} = p ->
            items = Enum.map(p.items, &%{&1 | source: &1.source || path})
            %{p | source: p.source || path, items: items}
          end)

        %{phases: phases, title: title, inferred?: true}

      _ ->
        %{phases: [], title: title}
    end
  end

  defp commit_subjects(nil), do: MapSet.new()

  defp commit_subjects(commits),
    do: commits |> Enum.map(&Progress.norm(&1.subject)) |> MapSet.new()

  defp apply_commit_evidence(src, subjects) do
    if MapSet.size(subjects) == 0 do
      src
    else
      map_items(src, fn it ->
        if it.state != :done and Enum.any?(it.hints, &MapSet.member?(subjects, Progress.norm(&1))),
          do: %{it | state: :done, blocked_reason: nil},
          else: it
      end)
    end
  end

  # A done line in a status-list roadmap (ROADMAP.md "Shipped") that links a
  # plan file is evidence that plan is finished.
  defp mark_referenced_plans_done(parsed) do
    shipped =
      for %{kind: :plan, mode: :status, phases: phases} <- parsed,
          p <- phases,
          it <- p.items,
          it.state == :done,
          h <- it.hints,
          into: MapSet.new(),
          do: Path.basename(h)

    Enum.map(parsed, fn src ->
      if src.kind == :plan and Map.get(src, :mode) != :status and
           MapSet.member?(shipped, Path.basename(src.path)) do
        map_items(src, &%{&1 | state: :done, blocked_reason: nil})
      else
        src
      end
    end)
  end

  defp map_items(src, fun) do
    %{src | phases: Enum.map(src.phases, fn p -> %{p | items: Enum.map(p.items, fun)} end)}
  end

  defp all_done?(%{phases: phases}),
    do:
      phases != [] and
        Enum.all?(phases, fn p -> p.items != [] and Enum.all?(p.items, &(&1.state == :done)) end)

  @doc false
  # The phases a source contributes, with completed plans collapsed to one done phase.
  def view(%{kind: :plan} = src) do
    if all_done?(src) and Map.get(src, :mode) != :status do
      title = src.title || Path.basename(src.path, ".md")

      [
        %Phase{
          id: nil,
          title: title,
          source: src.path,
          items: [%Item{id: nil, text: title, state: :done, source: src.path, source_line: 1}]
        }
      ]
    else
      src.phases
    end
  end

  def view(src), do: src.phases

  defp propose(pause, plans, spec) do
    {done, open} = Enum.split_with(plans, &(all_done?(&1) and Map.get(&1, :mode) != :status))

    history = done |> Enum.sort_by(&recency/1) |> Enum.flat_map(&view/1)
    pause_phases = if pause, do: pause.phases, else: []

    blocks =
      (open ++ List.wrap(spec))
      |> Enum.sort_by(&recency/1, :desc)
      |> Enum.flat_map(&view/1)

    %Roadmap{phases: history ++ pause_phases ++ blocks, notes: []}
  end

  # ── re-sync a confirmed roadmap from its sources ─────────────────────────

  defp resync(%Roadmap{} = file_rm, parsed) do
    views = Map.new(parsed, &{&1.path, view(&1)})

    {phases, {_seen, notes}} =
      Enum.map_reduce(file_rm.phases, {%{}, []}, fn p, {seen, notes} ->
        ordinal = Map.get(seen, p.source, 0)
        seen = if p.source, do: Map.put(seen, p.source, ordinal + 1), else: seen

        cond do
          p.source == nil ->
            {p, {seen, notes}}

          not Map.has_key?(views, p.source) ->
            {p, {seen, notes ++ ["#{p.id} · #{p.title}: source #{p.source} was not found"]}}

          true ->
            case Enum.at(Map.fetch!(views, p.source), ordinal) do
              nil ->
                {p,
                 {seen, notes ++ ["#{p.id} · #{p.title}: #{p.source} no longer has this phase"]}}

              %Phase{} = sp ->
                {%{p | items: merge_items(p.items, sp.items)}, {seen, notes}}
            end
        end
      end)

    %{file_rm | phases: phases, notes: notes}
  end

  defp merge_items(file_items, source_items) do
    n = max(length(file_items), length(source_items))

    Enum.flat_map(0..(n - 1)//1, fn i ->
      fi = Enum.at(file_items, i)
      si = Enum.at(source_items, i)

      cond do
        fi && fi.owner_edited? -> [fi]
        fi && si -> [merge_item(fi, si)]
        si -> [%{si | id: nil}]
        true -> []
      end
    end)
  end

  defp merge_item(fi, si) do
    state =
      cond do
        si.state == :done -> :done
        fi.state in [:done, :blocked] -> fi.state
        true -> si.state
      end

    %{
      si
      | id: fi.id,
        state: state,
        branch: fi.branch || si.branch,
        blocked_reason: if(state == :blocked, do: fi.blocked_reason || si.blocked_reason),
        owner_edited?: false
    }
  end

  # ── notes about PAUSE.md ─────────────────────────────────────────────────

  defp pause_info(pause, now) do
    written = pause.pause.written_on || DateTime.to_date(pause.mtime)

    %{
      path: pause.path,
      title: pause.pause.title,
      written_on: written,
      updated_on: pause.pause.updated_on || written,
      age_days: Date.diff(DateTime.to_date(now), pause.pause.updated_on || written),
      repo_state: pause.pause.repo_state
    }
  end

  defp pause_notes(_rm, nil, _info, _plans, _spec, _confirmed?, _now), do: []

  defp pause_notes(rm, pause, info, plans, spec, confirmed?, _now) do
    age = ["PAUSE.md last updated #{info.updated_on} (#{info.age_days} days ago)"]

    newer =
      (plans ++ List.wrap(spec))
      |> Enum.filter(fn src ->
        Date.compare(DateTime.to_date(src.mtime), info.updated_on) == :gt
      end)
      |> Enum.reject(&all_done?/1)
      |> Enum.max_by(&recency/1, fn -> nil end)

    stale =
      if newer,
        do: [
          "PAUSE.md predates #{newer.path} (#{DateTime.to_date(newer.mtime)}); its resume list may be stale"
        ],
        else: []

    first = Enum.find(pause.pause.items, &(&1.state == :active))

    disagree =
      cond do
        first == nil ->
          []

        confirmed? and not Enum.any?(rm.phases, &(&1.source == pause.path)) ->
          pos = Position.compute(rm, [], DateTime.utc_now())

          if pos.item_text && Progress.norm(pos.item_text) != Progress.norm(first.text),
            do: [
              "PAUSE.md says next: \"#{first.text}\"; the roadmap's position is #{pos.item_id} \"#{pos.item_text}\""
            ],
            else: []

        confirmed? ->
          []

        true ->
          rest = %{rm | phases: Enum.reject(rm.phases, &(&1.source == pause.path))}
          pos = Position.compute(rest, [], DateTime.utc_now())

          if pos.item_text,
            do: [
              "PAUSE.md puts the position at \"#{first.text}\"; without it the plans and specs point at #{pos.phase_title}: \"#{pos.item_text}\""
            ],
            else: []
      end

    age ++ stale ++ disagree
  end

  # ── writing ──────────────────────────────────────────────────────────────

  @doc "Writes `.sprat/roadmap.md` and its sidecar (on owner confirmation or a PM mark)."
  @spec write(Roadmap.t(), Path.t()) :: :ok | {:error, term()}
  def write(%Roadmap{} = rm, root), do: RFile.write(rm, root, DateTime.utc_now())

  @doc """
  Marks an item `:blocked`, `:done` or `:todo` in `.sprat/roadmap.md` and
  returns the record `revert/2` takes. Writes the proposal first when the
  file does not exist yet (`opts` go to `build/2`).
  """
  @spec mark(Path.t(), String.t(), :blocked | :done | :todo, String.t() | nil, keyword()) ::
          {:ok, write_record()} | {:error, term()}
  def mark(root, item_id, state, reason, opts \\ []) when state in [:blocked, :done, :todo] do
    rm = RFile.read(root) || build(root, opts)

    case find_item(rm, item_id) do
      nil ->
        {:error, :not_found}

      %Item{} = it ->
        rm = update_item(rm, item_id, state, if(state == :blocked, do: reason))

        record = %{
          item_id: item_id,
          from: it.state,
          to: state,
          reason: reason,
          from_reason: it.blocked_reason,
          at: Keyword.get(opts, :now, DateTime.utc_now())
        }

        with :ok <- write(rm, root), do: {:ok, record}
    end
  end

  @doc """
  Undoes a `mark/5`: puts the item back to its previous state. Refuses when
  the item has changed since (`{:error, {:changed, state}}`).
  """
  @spec revert(Path.t(), write_record()) :: {:ok, write_record()} | {:error, term()}
  def revert(root, %{item_id: id, from: from, to: to} = record) do
    with %Roadmap{} = rm <- RFile.read(root) || {:error, :no_roadmap},
         %Item{} = it <- find_item(rm, id) || {:error, :not_found},
         true <- it.state == to || {:error, {:changed, it.state}},
         rm = update_item(rm, id, from, Map.get(record, :from_reason)),
         :ok <- write(rm, root) do
      {:ok,
       %{
         item_id: id,
         from: to,
         to: from,
         reason: "revert",
         from_reason: it.blocked_reason,
         at: DateTime.utc_now()
       }}
    end
  end

  defp update_item(rm, id, state, reason) do
    phases =
      Enum.map(rm.phases, fn p ->
        %{
          p
          | items:
              Enum.map(p.items, fn
                %Item{id: ^id} = it ->
                  %{
                    it
                    | state: state,
                      blocked_reason: if(state == :blocked, do: reason || "blocked")
                  }

                it ->
                  it
              end)
        }
      end)

    %{rm | phases: phases}
  end

  # ── reading ──────────────────────────────────────────────────────────────

  @doc "The item with this id, or nil."
  @spec find_item(Roadmap.t(), String.t()) :: Item.t() | nil
  def find_item(%Roadmap{phases: phases}, id) do
    Enum.find_value(phases, fn p -> Enum.find(p.items, &(&1.id == id)) end)
  end

  @doc "Items in the active phase that are neither done nor blocked, in order (the PM's reassign)."
  @spec unblocked(Roadmap.t()) :: [Item.t()]
  def unblocked(%Roadmap{} = rm) do
    case Position.active_phase(rm) do
      nil -> []
      p -> Enum.filter(p.items, &(&1.state not in [:done, :blocked]))
    end
  end

  @doc "A one-line summary of the roadmap's sources, for display."
  @spec describe(Roadmap.t()) :: String.t()
  def describe(%Roadmap{} = rm) do
    items = Enum.flat_map(rm.phases, & &1.items)

    "#{length(rm.phases)} phases, #{length(items)} items from #{Md.truncate(Enum.join(rm.sources, ", "), 200)}" <>
      if(rm.confirmed?, do: "", else: " (unconfirmed)")
  end
end
