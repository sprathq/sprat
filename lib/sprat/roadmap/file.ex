defmodule Sprat.Roadmap.File do
  @moduledoc """
  The normalised `.sprat/roadmap.md` (spec-v4 §5.2) and its state sidecar
  `.sprat/roadmap.state.json`.

      # Roadmap: cupful
      <!-- sprat: edit freely; lines you change are never overwritten -->

      goal: Cafe networks share one loyalty balance across venues
      due: 2026-12-15

      ## C · Cafe networks  [active]
      source: docs/superpowers/plans/2026-11-14-cafe-networks.md

      - [x] schema + migration
      - [ ] shared points ledger  <!-- branch: cafe-networks -->
      - [ ] cross-cafe redemption  <!-- blocked: needs the Stripe key -->

  `parse/2` and `render/1` are pure. Item ids are `<phase id>.<n>` by
  position. The sidecar keeps a hash of every item line as Sprat last wrote
  it; a line whose hash is not among them was edited (or added) by the owner,
  and `parse/2` marks it `owner_edited?`.
  """

  alias Sprat.Observer.Model.{Item, Phase, Roadmap}
  alias Sprat.Roadmap.Position

  @comment "<!-- sprat: edit freely; lines you change are never overwritten -->"

  @doc "The roadmap file's path under a project root."
  def path(root), do: Path.join([root, ".sprat", "roadmap.md"])

  @doc "The sidecar's path under a project root."
  def state_path(root), do: Path.join([root, ".sprat", "roadmap.state.json"])

  @doc """
  Parses the file's text. `known` is the set of line hashes Sprat wrote (from
  the sidecar): with it, lines outside the set are `owner_edited?`; with
  `nil`, nothing is marked.
  """
  @spec parse(String.t(), MapSet.t() | nil) :: Roadmap.t()
  def parse(text, known \\ nil) do
    lines = String.split(text, ~r/\r?\n/)

    {roadmap, phases} =
      Enum.reduce(lines, {%Roadmap{confirmed?: true}, []}, fn raw, {rm, phases} ->
        line = String.trim_trailing(raw)

        case classify(line, phases == []) do
          {:name, v} ->
            {%{rm | name: String.trim(v)}, phases}

          {:phase, v} ->
            {rm, [phase_header(v, length(phases)) | phases]}

          {:goal, v} ->
            {%{rm | goal: blank_nil(v)}, phases}

          {:due, v} ->
            {%{rm | due: parse_due(v)}, phases}

          {:source, v} ->
            [p | rest] = phases
            {rm, [%{p | source: String.trim(v)} | rest]}

          {:item, item} ->
            [p | rest] = phases
            {rm, [%{p | items: [item | p.items]} | rest]}

          nil ->
            {rm, phases}
        end
      end)

    phases =
      phases
      |> Enum.reverse()
      |> Enum.map(fn p ->
        items =
          p.items
          |> Enum.reverse()
          |> Enum.with_index(1)
          |> Enum.map(fn {it, n} ->
            edited? = known != nil and not MapSet.member?(known, hash(render_item(it)))
            %{it | id: "#{p.id}.#{n}", source: p.source, owner_edited?: edited?}
          end)

        %{p | items: items}
      end)

    %{roadmap | phases: phases}
  end

  defp classify(line, before_phases?) do
    rules =
      if before_phases?,
        do: [
          name: ~r/^#\s+Roadmap:\s*(.*)$/,
          phase: ~r/^##\s+(.*)$/,
          goal: ~r/^goal:\s*(.*)$/i,
          due: ~r/^due:\s*(.*)$/i
        ],
        else: [phase: ~r/^##\s+(.*)$/, source: ~r/^source:\s*(.+)$/i]

    Enum.find_value(rules, fn {tag, re} ->
      case Regex.run(re, line) do
        [_, v] -> {tag, v}
        _ -> nil
      end
    end) ||
      if(not before_phases?, do: (item = item_line(line)) && {:item, item})
  end

  defp phase_header(text, index) do
    text = String.replace(text, ~r/\s*\[active\]\s*$/i, "") |> String.trim()

    case Regex.run(~r/^([A-Za-z0-9]{1,4})\s*·\s*(.+)$/u, text) do
      [_, id, title] -> %Phase{id: id, title: String.trim(title), items: []}
      _ -> %Phase{id: Sprat.Roadmap.Ids.letter(index), title: text, items: []}
    end
  end

  defp item_line(line) do
    case Regex.run(~r/^\s*[-*]\s+\[([ xX])\]\s+(.*)$/, line) do
      [_, mark, rest] ->
        branch = comment(rest, "branch")
        blocked = comment(rest, "blocked")
        text = rest |> String.replace(~r/<!--.*?-->/, "") |> String.trim()

        state =
          cond do
            mark in ["x", "X"] -> :done
            blocked != nil -> :blocked
            true -> :todo
          end

        %Item{id: nil, text: text, state: state, branch: branch, blocked_reason: blocked}

      _ ->
        nil
    end
  end

  defp comment(text, key) do
    case Regex.run(~r/<!--\s*#{key}:\s*(.*?)\s*-->/, text) do
      [_, v] -> blank_nil(v)
      _ -> nil
    end
  end

  defp blank_nil(v) do
    case String.trim(v || "") do
      "" -> nil
      s -> s
    end
  end

  defp parse_due(v) do
    case Date.from_iso8601(String.trim(v)) do
      {:ok, d} -> d
      _ -> blank_nil(v)
    end
  end

  @doc "Renders a roadmap as the file's text."
  @spec render(Roadmap.t()) :: String.t()
  def render(%Roadmap{} = rm) do
    name = rm.name || (rm.project_root && Path.basename(rm.project_root)) || "project"
    active_id = Position.active_phase_id(rm)

    head =
      ["# Roadmap: #{name}", @comment, ""] ++
        if(rm.goal || rm.due,
          do: ["goal: #{rm.goal || ""}", "due: #{due_text(rm.due)}", ""],
          else: []
        )

    body =
      Enum.flat_map(rm.phases, fn p ->
        marker = if p.id == active_id, do: "  [active]", else: ""

        ["## #{p.id} · #{p.title}#{marker}"] ++
          if(p.source, do: ["source: #{p.source}"], else: []) ++
          [""] ++ Enum.map(p.items, &render_item/1) ++ [""]
      end)

    Enum.join(head ++ body, "\n")
  end

  defp due_text(nil), do: ""
  defp due_text(%Date{} = d), do: Date.to_iso8601(d)
  defp due_text(other), do: to_string(other)

  @doc "One item's line, exactly as `render/1` writes it."
  @spec render_item(Item.t()) :: String.t()
  def render_item(%Item{} = it) do
    box = if it.state == :done, do: "[x]", else: "[ ]"
    text = it.text |> String.replace(~r/[\r\n]+/, " ") |> String.trim()

    tags =
      [
        it.branch && "<!-- branch: #{it.branch} -->",
        it.state == :blocked && "<!-- blocked: #{it.blocked_reason || "blocked"} -->"
      ]
      |> Enum.filter(&is_binary/1)

    Enum.join(["- #{box} #{text}" | tags], "  ")
  end

  @doc "The hash of a rendered item line."
  @spec hash(String.t()) :: String.t()
  def hash(line) do
    :crypto.hash(:sha256, String.trim(line)) |> Base.encode16(case: :lower) |> binary_part(0, 16)
  end

  @doc """
  The sidecar's data for a roadmap about to be written: the hash of every
  line Sprat writes. Owner-edited lines are left out, so they stay the
  owner's after the write.
  """
  @spec state(Roadmap.t(), DateTime.t()) :: map()
  def state(%Roadmap{} = rm, now) do
    lines =
      for p <- rm.phases, it <- p.items, not it.owner_edited?, into: %{} do
        {"#{p.id}.#{position(p, it)}", hash(render_item(it))}
      end

    %{"version" => 1, "written_at" => DateTime.to_iso8601(now), "lines" => lines}
  end

  defp position(p, it), do: Enum.find_index(p.items, &(&1 == it)) + 1

  @doc "The known-hash set from sidecar text (`nil` input gives an empty set)."
  @spec known_hashes(String.t() | nil) :: MapSet.t()
  def known_hashes(nil), do: MapSet.new()

  def known_hashes(json) do
    case JSON.decode(json) do
      {:ok, %{"lines" => lines}} when is_map(lines) -> MapSet.new(Map.values(lines))
      _ -> MapSet.new()
    end
  end

  @doc "Reads and parses the project's roadmap file, or nil when it does not exist."
  @spec read(Path.t()) :: Roadmap.t() | nil
  def read(root) do
    case Elixir.File.read(path(root)) do
      {:ok, text} ->
        sidecar =
          case Elixir.File.read(state_path(root)) do
            {:ok, json} -> json
            _ -> nil
          end

        %{parse(text, known_hashes(sidecar)) | project_root: root}

      {:error, _} ->
        nil
    end
  end

  @doc "Writes the roadmap file and its sidecar."
  @spec write(Roadmap.t(), Path.t(), DateTime.t()) :: :ok | {:error, term()}
  def write(%Roadmap{} = rm, root, now \\ DateTime.utc_now()) do
    with :ok <- Elixir.File.mkdir_p(Path.join(root, ".sprat")),
         :ok <- Elixir.File.write(path(root), render(rm)) do
      Elixir.File.write(state_path(root), JSON.encode!(state(rm, now)))
    end
  end
end
