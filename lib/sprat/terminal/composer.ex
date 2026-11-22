defmodule Sprat.Terminal.Composer do
  @moduledoc """
  Pure editing state machine for the composer box: a struct plus reducer
  functions, no process. Multi-line input, Emacs-style movement/edit keys,
  history navigation over a caller-supplied list (no persistence), a paste
  placeholder that expands to the real content on submit, and a `/` command
  menu with Tab completion.

  `@`-completion (fuzzy file attachment, spec §10) mirrors the `/`-menu:
  `mention/1` is the parallel of `menu/1`, matching a `files:` list (the
  caller's job to keep current — this module does no I/O) fuzzily against
  the `@token` immediately before the cursor. `Tab`/`↑`/`↓` dispatch to
  whichever of the two is active; only one ever is, since `/` requires the
  whole buffer to start with `/` while `@` looks only at the current word.
  Completing inserts `@<path> ` into the buffer — resolving that mention
  into an actual attachment (reading the file, recording it as evidence)
  is `Sprat.Attachments`' job, done downstream on submit.
  """

  defstruct text: "",
            cursor: 0,
            history: [],
            history_index: nil,
            draft: nil,
            pastes: %{},
            paste_seq: 0,
            commands: [],
            files: [],
            menu_selected: 0

  @type t :: %__MODULE__{}

  @paste_collapse_threshold 3

  @doc "commands: [{name, description}]. files: [relative_path] for `@`-completion. history: most-recent-first strings."
  def new(opts \\ []) do
    %__MODULE__{
      history: Keyword.get(opts, :history, []),
      commands: Keyword.get(opts, :commands, []),
      files: Keyword.get(opts, :files, [])
    }
  end

  @doc """
  Handle one parsed key event. Returns `{:submit, text, new_state}` when
  Enter submits (paste placeholders expanded), or `{:ok, new_state}`
  otherwise.
  """
  def handle_event(%__MODULE__{} = state, event) do
    case event do
      {:char, ch} ->
        {:ok, insert(state, ch)}

      :backspace ->
        {:ok, delete_backward(state)}

      :enter ->
        handle_enter(state)

      :alt_enter ->
        {:ok, insert(state, "\n")}

      :shift_enter ->
        {:ok, insert(state, "\n")}

      :tab ->
        {:ok, complete_active(state)}

      {:ctrl, "a"} ->
        {:ok, move_line_start(state)}

      {:ctrl, "e"} ->
        {:ok, move_line_end(state)}

      {:ctrl, "k"} ->
        {:ok, kill_to_line_end(state)}

      {:ctrl, "u"} ->
        {:ok, kill_to_line_start(state)}

      {:ctrl, "w"} ->
        {:ok, kill_word_backward(state)}

      {:left, [:alt]} ->
        {:ok, move_word_backward(state)}

      {:right, [:alt]} ->
        {:ok, move_word_forward(state)}

      :left ->
        {:ok, %{state | cursor: max(state.cursor - 1, 0)}}

      :right ->
        {:ok, %{state | cursor: min(state.cursor + 1, length_of(state.text))}}

      :up ->
        {:ok, menu_move(state, -1) || mention_move(state, -1) || history_or_move(state, :up)}

      :down ->
        {:ok, menu_move(state, 1) || mention_move(state, 1) || history_or_move(state, :down)}

      {:paste, content} ->
        {:ok, insert_paste(state, content)}

      _ ->
        {:ok, state}
    end
  end

  @doc "Grapheme count of the buffer (helper for callers laying out the box)."
  def length_of(text), do: text |> String.graphemes() |> length()

  @doc "Lines of the buffer, for rendering (does not expand paste placeholders)."
  def lines(%__MODULE__{text: text}), do: String.split(text, "\n")

  @doc "Current 0-indexed {row, col} of the cursor, in graphemes."
  def cursor_position(%__MODULE__{text: text, cursor: cursor}) do
    graphemes = String.graphemes(text)
    {before, _} = Enum.split(graphemes, cursor)
    joined = Enum.join(before)
    parts = String.split(joined, "\n")
    row = length(parts) - 1
    col = parts |> List.last() |> String.graphemes() |> length()
    {row, col}
  end

  @doc """
  `/`-menu matches for the current buffer, or `nil` when the menu isn't
  active (buffer must start with `/` and contain no space yet).
  """
  def menu(%__MODULE__{text: text, commands: commands, menu_selected: selected}) do
    case text do
      "/" <> rest ->
        if String.contains?(rest, " ") or String.contains?(rest, "\n") do
          nil
        else
          matches = Enum.filter(commands, fn {name, _desc} -> String.starts_with?(name, rest) end)
          if matches == [], do: nil, else: %{query: rest, matches: matches, selected: selected}
        end

      _ ->
        nil
    end
  end

  @doc """
  Replaces the `@`-completion file list. The renderer starts empty and fills
  this from a background walk: scanning a project costs hundreds of
  milliseconds, and doing it inline delayed the first paint.
  """
  def set_files(%__MODULE__{} = state, files) when is_list(files),
    do: %{state | files: files}

  @doc """
  `@`-mention fuzzy matches for the `@token` immediately before the
  cursor, or `nil` when none is active (no `@token` there, or it matches
  nothing in `files`). Mirrors `menu/1`, but the token can start anywhere
  in the buffer, not just at its head.
  """
  def mention(%__MODULE__{text: text, cursor: cursor, files: files, menu_selected: selected}) do
    case at_token(text, cursor) do
      nil ->
        nil

      query ->
        matches = fuzzy_matches(files, query)
        if matches == [], do: nil, else: %{query: query, matches: matches, selected: selected}
    end
  end

  # -- insertion / deletion ----------------------------------------------------

  defp insert(state, str) do
    {before, after_} = split_at(state.text, state.cursor)
    text = before <> str <> after_
    %{state | text: text, cursor: state.cursor + length_of(str), history_index: nil, draft: nil}
  end

  defp insert_paste(state, content) do
    line_count = paste_line_count(content)

    if line_count > @paste_collapse_threshold do
      id = state.paste_seq + 1
      placeholder = "[Pasted text ##{id} +#{line_count} lines]"
      pastes = Map.put(state.pastes, id, content)
      insert(%{state | pastes: pastes, paste_seq: id}, placeholder)
    else
      insert(state, content)
    end
  end

  defp delete_backward(%{cursor: 0} = state), do: state

  defp delete_backward(state) do
    {before, after_} = split_at(state.text, state.cursor)
    before = before |> String.graphemes() |> Enum.slice(0..-2//1) |> Enum.join()
    %{state | text: before <> after_, cursor: state.cursor - 1}
  end

  # -- movement -----------------------------------------------------------

  defp move_line_start(state) do
    {row_start, _row_end} = current_line_bounds(state)
    %{state | cursor: row_start}
  end

  defp move_line_end(state) do
    {_row_start, row_end} = current_line_bounds(state)
    %{state | cursor: row_end}
  end

  defp move_word_backward(state) do
    {before, _after} = split_at(state.text, state.cursor)
    new_before = before |> String.trim_trailing(" ") |> trim_last_word()
    %{state | cursor: length_of(new_before)}
  end

  defp move_word_forward(state) do
    {_before, after_} = split_at(state.text, state.cursor)
    stripped = after_ |> String.trim_leading(" ")
    [_first_word | rest] = String.split(stripped, " ", parts: 2) ++ [""]
    consumed = length_of(after_) - length_of(Enum.join(rest, " "))
    %{state | cursor: state.cursor + consumed}
  end

  defp trim_last_word(text) do
    case Regex.run(~r/^(.*?)(\S+)$/us, text) do
      [_, head, _word] -> head
      nil -> ""
    end
  end

  # -- kill / word deletion --------------------------------------------------

  defp kill_to_line_end(state) do
    {_row_start, row_end} = current_line_bounds(state)
    {before, after_line} = split_at(state.text, state.cursor)
    {_killed, rest} = split_at(after_line, row_end - state.cursor)
    %{state | text: before <> rest}
  end

  defp kill_to_line_start(state) do
    {row_start, _row_end} = current_line_bounds(state)
    {before, after_} = split_at(state.text, state.cursor)
    {kept_before, _killed} = split_at(before, row_start)
    %{state | text: kept_before <> after_, cursor: row_start}
  end

  defp kill_word_backward(state) do
    {before, after_} = split_at(state.text, state.cursor)
    new_before = before |> String.trim_trailing(" ") |> trim_last_word()
    %{state | text: new_before <> after_, cursor: length_of(new_before)}
  end

  defp current_line_bounds(state) do
    graphemes = String.graphemes(state.text)
    len = length(graphemes)
    row_start = find_boundary(graphemes, state.cursor, -1)
    row_end = find_boundary(graphemes, state.cursor, 1, len)
    {row_start, row_end}
  end

  defp find_boundary(graphemes, from, -1) do
    graphemes
    |> Enum.slice(0, from)
    |> Enum.reverse()
    |> Enum.find_index(&(&1 == "\n"))
    |> case do
      nil -> 0
      idx -> from - idx
    end
  end

  defp find_boundary(graphemes, from, 1, len) do
    graphemes
    |> Enum.slice(from, len - from)
    |> Enum.find_index(&(&1 == "\n"))
    |> case do
      nil -> len
      idx -> from + idx
    end
  end

  # -- submit / newline-escape ------------------------------------------------

  defp handle_enter(state) do
    if String.ends_with?(state.text, "\\") and state.cursor == length_of(state.text) do
      before = String.slice(state.text, 0..-2//1)
      {:ok, %{state | text: before <> "\n", cursor: length_of(before) + 1}}
    else
      {:submit, expand_pastes(state), reset_after_submit(state)}
    end
  end

  # A trailing newline ends the last line, it does not start an empty one:
  # a 3-line file pasted whole is 3 lines, not 4.
  defp paste_line_count(content) do
    content |> String.trim_trailing("\n") |> String.split("\n") |> length()
  end

  defp expand_pastes(state) do
    Enum.reduce(state.pastes, state.text, fn {id, content}, text ->
      String.replace(
        text,
        "[Pasted text ##{id} +#{paste_line_count(content)} lines]",
        content
      )
    end)
  end

  defp reset_after_submit(state) do
    history = [state.text | state.history]
    %{state | text: "", cursor: 0, pastes: %{}, history: history, history_index: nil, draft: nil}
  end

  # -- history --------------------------------------------------------------

  defp history_or_move(state, :up) do
    {row, _col} = cursor_position(state)

    if row == 0 do
      recall(state, 1)
    else
      move_up_a_line(state)
    end
  end

  defp history_or_move(state, :down) do
    {row, _col} = cursor_position(state)
    line_count = state |> lines() |> length()

    cond do
      state.history_index != nil -> recall(state, -1)
      row == line_count - 1 -> state
      true -> move_down_a_line(state)
    end
  end

  defp move_up_a_line(state), do: %{state | cursor: max(state.cursor - 1, 0)}

  defp move_down_a_line(state),
    do: %{state | cursor: min(state.cursor + 1, length_of(state.text))}

  defp recall(state, delta) do
    max_index = length(state.history) - 1
    current = state.history_index || -1
    next = current + delta

    cond do
      next < 0 ->
        draft = state.draft || state.text
        %{state | text: draft, cursor: length_of(draft), history_index: nil, draft: nil}

      next > max_index ->
        state

      true ->
        draft = state.draft || (state.history_index == nil && state.text) || state.draft
        entry = Enum.at(state.history, next)
        %{state | text: entry, cursor: length_of(entry), history_index: next, draft: draft}
    end
  end

  # -- `/` menu ---------------------------------------------------------------

  defp menu_move(state, delta) do
    case menu(state) do
      nil ->
        nil

      %{matches: matches} ->
        n = length(matches)
        %{state | menu_selected: rem(state.menu_selected + delta + n, n)}
    end
  end

  defp complete_menu(state) do
    case menu(state) do
      nil ->
        state

      %{matches: matches, selected: selected} ->
        {name, _desc} = Enum.at(matches, selected) || List.first(matches)
        text = "/" <> name <> " "
        %{state | text: text, cursor: length_of(text), menu_selected: 0}
    end
  end

  defp complete_active(state) do
    cond do
      menu(state) -> complete_menu(state)
      mention(state) -> complete_mention(state)
      true -> state
    end
  end

  # -- `@` mention ----------------------------------------------------------

  defp mention_move(state, delta) do
    case mention(state) do
      nil ->
        nil

      %{matches: matches} ->
        n = length(matches)
        %{state | menu_selected: rem(state.menu_selected + delta + n, n)}
    end
  end

  defp complete_mention(state) do
    case mention(state) do
      nil ->
        state

      %{matches: matches, selected: selected} ->
        {before, after_} = split_at(state.text, state.cursor)
        path = Enum.at(matches, selected) || List.first(matches)
        new_before = Regex.replace(~r/@[^\s]*$/u, before, "@" <> path <> " ")
        text = new_before <> after_
        %{state | text: text, cursor: length_of(new_before), menu_selected: 0}
    end
  end

  # The `@token` ending at `cursor` (graphemes before it, up to the
  # nearest whitespace/newline or the start of the buffer), or `nil` if
  # that token isn't a `@`-mention (no `@`, or an `@` isn't where it
  # starts — `a@b` mid-word is not a mention).
  defp at_token(text, cursor) do
    {before, _after} = text |> String.graphemes() |> Enum.split(cursor)
    before_str = Enum.join(before)

    case Regex.run(~r/(?:^|[\s\n])@([^\s\n]*)$/u, before_str) do
      [_, query] -> query
      nil -> nil
    end
  end

  defp fuzzy_matches(files, query) do
    files
    |> Enum.filter(&subsequence?(String.downcase(&1), String.downcase(query)))
    |> Enum.sort_by(&{String.length(&1), &1})
    |> Enum.take(10)
  end

  defp subsequence?(str, query),
    do: do_subsequence?(String.graphemes(str), String.graphemes(query))

  defp do_subsequence?(_str, []), do: true
  defp do_subsequence?([], _query), do: false
  defp do_subsequence?([ch | rest], [ch | qrest]), do: do_subsequence?(rest, qrest)
  defp do_subsequence?([_ | rest], query), do: do_subsequence?(rest, query)

  # -- helpers ----------------------------------------------------------------

  defp split_at(text, offset) do
    graphemes = String.graphemes(text)
    {before, after_} = Enum.split(graphemes, offset)
    {Enum.join(before), Enum.join(after_)}
  end
end
