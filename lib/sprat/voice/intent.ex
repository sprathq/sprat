defmodule Sprat.Voice.Intent do
  @moduledoc """
  What a spoken sentence means on the board. Plain matching, no AI: a few
  verbs, and project and session names matched by their words. Anything it
  does not recognise comes back as `:unknown`, shown to the owner, never
  guessed at.

  On a session's screen speech is dictation (it fills the message line),
  except the words that end a message: "send", "cancel".

  Returns `{:keys, [key]}` (fed to `Sprat.Terminal.Board.Keys` as if typed),
  `{:open, screen, label}`, `{:dictate, text}` or `{:unknown, text}`.
  """

  alias Sprat.Terminal.Board.View

  @verbs %{
    "send" => [{:char, "f"}],
    "send it" => [{:char, "f"}],
    "fire" => [{:char, "f"}],
    "activity" => [{:char, "a"}],
    "show activity" => [{:char, "a"}],
    "help" => [{:char, "?"}],
    "brief" => [{:char, "b"}],
    "the brief" => [{:char, "b"}],
    "back" => [:esc],
    "go back" => [:esc],
    "close" => [:esc],
    "cancel" => [:esc],
    "escape" => [:esc],
    "next" => [:right],
    "next ticket" => [:right],
    "previous" => [:left],
    "previous ticket" => [:left],
    "down" => [:down],
    "up" => [:up],
    "open" => [:enter],
    "open it" => [:enter],
    "details" => [:enter],
    "dismiss" => [{:char, "x"}]
  }

  def parse(text, %View{} = view) do
    words = normalize(text)

    cond do
      words == "" ->
        {:unknown, text}

      match?({:session, _}, view.screen) ->
        session_speech(words, text, view)

      keys = Map.get(@verbs, words) ->
        {:keys, keys}

      name = strip_prefix(words, ["open ", "go to ", "show ", "show me "]) ->
        open(name, view, text)

      name = strip_prefix(words, ["talk to ", "speak to ", "message "]) ->
        talk(name, view, text)

      true ->
        {:unknown, text}
    end
  end

  # On a session's screen: "send" sends what is in the message line,
  # "cancel" drops it; everything else is what to say to the agent.
  defp session_speech(words, text, view) do
    composing? = match?(%{purpose: :to_session}, view.composer)

    cond do
      composing? and words in ["send", "send it"] -> {:keys, [:enter]}
      words in ["cancel", "never mind", "nevermind"] -> {:keys, [:esc]}
      not composing? and words in ["back", "go back", "close"] -> {:keys, [:esc]}
      true -> {:dictate, String.trim(text)}
    end
  end

  defp open(name, view, text) do
    case best(name, view) do
      {:project, p} -> {:open, {:project, p.root}, p.name || Path.basename(p.root)}
      {:session, s} -> {:open, {:session, s.session_id}, s.name}
      nil -> {:unknown, text}
    end
  end

  # "talk to studio": the session itself, or the project's newest live one.
  defp talk(name, view, text) do
    case best(name, view) do
      {:session, s} ->
        {:open, {:session, s.session_id}, s.name}

      {:project, p} ->
        case Enum.find(p.sessions, & &1.live?) || List.first(p.sessions) do
          nil -> {:open, {:project, p.root}, p.name}
          s -> {:open, {:session, s.session_id}, s.name}
        end

      nil ->
        {:unknown, text}
    end
  end

  # The project or session whose name best matches the spoken words: all of
  # the name's words heard wins; a session name ("studio 67") beats its
  # project's ("studio") when its number was said too.
  defp best(spoken, view) do
    candidates =
      Enum.flat_map(view.snapshot.projects, fn p ->
        [{:project, p, normalize(p.name || Path.basename(p.root))}] ++
          for s <- p.sessions, s.name, do: {:session, s, normalize(s.name)}
      end)

    heard = String.split(spoken)

    candidates
    |> Enum.map(fn {kind, item, name} -> {kind, item, score(String.split(name), heard)} end)
    |> Enum.filter(fn {_, _, score} -> score > 0 end)
    |> Enum.max_by(fn {kind, _, score} -> {score, if(kind == :session, do: 0, else: 1)} end, fn ->
      nil
    end)
    |> case do
      nil -> nil
      {kind, item, _} -> {kind, item}
    end
  end

  # Every word of the name heard scores best (longer names are more
  # specific); then the name run together inside what was heard
  # ("insta dreams" for dreamboard); then a near miss of the whole name.
  defp score([], _heard), do: 0

  defp score(name_words, heard) do
    name = Enum.join(name_words)
    said = Enum.join(heard)

    cond do
      Enum.all?(name_words, &(&1 in heard)) -> 2 * length(name_words) + 1
      String.length(name) >= 4 and String.contains?(said, name) -> 2 * length(name_words)
      String.length(name) >= 5 and near?(name, heard) -> 1
      true -> 0
    end
  end

  # Some run of the heard words, joined, is within a letter or two of the name.
  defp near?(name, heard) do
    n = length(heard)

    for i <- 0..(n - 1), j <- i..(n - 1), reduce: false do
      true -> true
      false -> String.jaro_distance(name, heard |> Enum.slice(i..j) |> Enum.join()) >= 0.9
    end
  end

  @doc """
  What whisper should expect on this screen: the command words and the
  names of projects and sessions (its prompt; capped, whisper reads about
  200 tokens of it).
  """
  def vocabulary(%View{} = view) do
    names =
      view.snapshot.projects
      |> Enum.flat_map(fn p ->
        [p.name || Path.basename(p.root) | for(s <- p.sessions, s.name, do: s.name)]
      end)
      |> Enum.uniq()
      |> Enum.take(40)

    "Open, talk to, activity, help, brief, back, next, send it. " <> Enum.join(names, ", ") <> "."
  end

  defp strip_prefix(words, prefixes) do
    Enum.find_value(prefixes, fn pre ->
      if String.starts_with?(words, pre), do: String.trim_leading(words, pre)
    end)
  end

  @doc false
  # "Open Studio-67." → "open studio 67"; "cupful_backend" → "cupful backend".
  def normalize(text) do
    text
    |> String.downcase()
    |> String.replace(~r/[-_.,!?;:"'()]+/u, " ")
    |> String.replace(~r/\s+/u, " ")
    |> String.trim()
  end
end
