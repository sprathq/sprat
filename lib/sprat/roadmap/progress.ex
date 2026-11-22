defmodule Sprat.Roadmap.Progress do
  @moduledoc """
  Progress evidence against a roadmap (spec-v4 §3, §5.1 source 5). Pure: the
  caller reads git; this module only matches.

  A commit binds to an item, in order of strength:

    1. its branch is the item's `<!-- branch: x -->`;
    2. its subject is a commit message the item's plan quotes for it
       (`git commit -m "…"` in the task's steps), compared loosely;
    3. its subject contains the item's text, or shares most of its words.

  Unbound commits are still progress events (`item_id: nil`): something
  landed in the project.
  """

  alias Sprat.Observer.Model.{Item, Roadmap}

  @type commit :: %{
          required(:sha) => String.t(),
          required(:at) => DateTime.t(),
          required(:subject) => String.t(),
          optional(:branches) => [String.t()]
        }
  @type event :: %{
          kind: :commit | :tick,
          at: DateTime.t(),
          item_id: String.t() | nil,
          ref: term()
        }

  @stop ~w(a an the and or of to in on for with by from at as is are be into via not no it its this that
           add adds added update updates fix fixes use make run test tests step task plan implement wip)

  @spec from_git([commit()], Roadmap.t()) :: [event()]
  def from_git(commits, %Roadmap{} = rm) do
    # Each item's normalised text, words and hints once, not once per commit
    # (a year of history is thousands of commits; this ran in the engine).
    items = Enum.map(items(rm), &prepare/1)

    Enum.map(commits, fn c ->
      %{kind: :commit, at: c.at, ref: c.sha, item_id: bind(c, items)}
    end)
  end

  @doc """
  The items a commit list completes with strong evidence: a commit whose
  subject is the message the item's plan quotes for it. Returns item ids.
  """
  @spec completed_by([commit()], Roadmap.t()) :: [String.t()]
  def completed_by(commits, %Roadmap{} = rm) do
    subjects = commits |> Enum.map(&norm(&1.subject)) |> MapSet.new()

    for it <- items(rm),
        it.state != :done,
        Enum.any?(it.hints, &MapSet.member?(subjects, norm(&1))),
        do: it.id
  end

  @spec diff_ticks(Roadmap.t() | nil, Roadmap.t(), DateTime.t()) :: [event()]
  def diff_ticks(nil, _new, _now), do: []

  def diff_ticks(%Roadmap{} = old, %Roadmap{} = new, now) do
    before = Map.new(items(old), &{&1.id, &1.state})

    for it <- items(new),
        it.state == :done,
        Map.has_key?(before, it.id),
        before[it.id] != :done,
        do: %{kind: :tick, at: now, item_id: it.id, ref: it.id}
  end

  defp items(%Roadmap{phases: phases}), do: Enum.flat_map(phases, & &1.items)

  defp prepare(%Item{} = it) do
    text = norm(it.text)

    %{
      id: it.id,
      state: it.state,
      branch: it.branch,
      hints: MapSet.new(it.hints, &norm/1),
      text: text,
      words: words(text)
    }
  end

  defp bind(commit, items) do
    branches = Map.get(commit, :branches) || []
    subject = norm(commit.subject)

    by_branch(items, branches) || by_hint(items, subject) || by_text(items, subject)
  end

  defp by_branch(_items, []), do: nil

  defp by_branch(items, branches) do
    bound = Enum.filter(items, &(&1.branch != nil and &1.branch in branches))

    case Enum.find(bound, &(&1.state != :done)) || List.first(bound) do
      %{id: id} -> id
      nil -> nil
    end
  end

  defp by_hint(items, subject) do
    Enum.find_value(items, fn it ->
      if MapSet.member?(it.hints, subject), do: it.id
    end)
  end

  defp by_text(items, subject) do
    subject_words = words(subject)

    Enum.find_value(items, fn %{text: text, words: iw} = it ->
      cond do
        MapSet.size(iw) >= 2 and String.contains?(subject, text) ->
          it.id

        MapSet.size(iw) >= 3 and
            MapSet.size(MapSet.intersection(iw, subject_words)) / MapSet.size(iw) >= 0.75 ->
          it.id

        true ->
          nil
      end
    end)
  end

  @doc false
  def norm(text) do
    text
    |> String.downcase()
    |> String.replace(~r/[`*"'“”‘’]/u, "")
    |> String.replace(~r/[^\p{L}\p{N}\s]+/u, " ")
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  defp words(normed) do
    normed
    |> String.split(" ", trim: true)
    |> Enum.reject(&(&1 in @stop or String.length(&1) < 3))
    |> MapSet.new()
  end
end
