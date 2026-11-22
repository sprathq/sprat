defmodule Sprat.Spike.Renderer do
  @moduledoc """
  Points 3, 4, 5, 7: the single stdout-writing process. Committed blocks are
  written once; the live region (spinner/checklist/composer/footer, or a
  permission prompt) is redrawn in place by moving the cursor to the top of
  the region, clearing to end of screen, and repainting — capped at
  `rows - 2`. Repaints are coalesced to <= 30fps.
  """

  use GenServer
  alias IO.ANSI
  alias Sprat.Spike.Wcwidth

  @frame_ms 33
  @spinner_frames ~w(✢ ✳ ∗ ✻ ✽)
  @spinner_tick_ms 120

  defstruct cols: 80,
            rows: 24,
            last_live_height: 0,
            repaint_scheduled?: false,
            spinner_index: 0,
            verb: "Researching",
            started_at: nil,
            tokens: 0,
            checklist: [],
            composer: "",
            footer: %{mode: "normal", cost: "$0.00", sources: 0},
            streaming_text: "",
            permission: nil,
            last_permission_choice: nil,
            latencies: [],
            pending_keystrokes: [],
            log: [],
            exit_notify: nil,
            ctrl_c_at: nil

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(opts) do
    {cols, rows} = terminal_size()

    state = %__MODULE__{
      cols: cols,
      rows: rows,
      started_at: System.monotonic_time(:millisecond),
      checklist: Keyword.get(opts, :checklist, []),
      exit_notify: Keyword.get(opts, :exit_notify)
    }

    :timer.send_interval(@spinner_tick_ms, :spinner_tick)
    :timer.send_interval(250, :resize_poll)
    {:ok, state, {:continue, :paint}}
  end

  @impl true
  def handle_continue(:paint, state), do: {:noreply, paint(state)}

  # -- public API (cast so callers never block on the sole writer) --------

  def commit(lines) when is_list(lines), do: GenServer.cast(__MODULE__, {:commit, lines})
  def set_verb(verb), do: GenServer.cast(__MODULE__, {:set_verb, verb})
  def stream_token(text), do: GenServer.cast(__MODULE__, {:stream_token, text})
  def add_tokens(n), do: GenServer.cast(__MODULE__, {:add_tokens, n})
  def set_checklist(items), do: GenServer.cast(__MODULE__, {:set_checklist, items})
  def set_footer(map), do: GenServer.cast(__MODULE__, {:set_footer, map})

  def open_permission(title, lines, options),
    do: GenServer.cast(__MODULE__, {:open_permission, title, lines, options})

  def latency_report, do: GenServer.call(__MODULE__, :latency_report)
  def snapshot, do: GenServer.call(__MODULE__, :snapshot)

  # -- casts ----------------------------------------------------------------

  @impl true
  def handle_cast({:commit, lines}, state),
    do: {:noreply, state |> do_commit(lines) |> request_repaint()}

  def handle_cast({:set_verb, verb}, state), do: {:noreply, request_repaint(%{state | verb: verb})}

  def handle_cast({:stream_token, text}, state) do
    {:noreply, request_repaint(%{state | streaming_text: state.streaming_text <> text})}
  end

  def handle_cast({:add_tokens, n}, state), do: {:noreply, %{state | tokens: state.tokens + n}}

  def handle_cast({:set_checklist, items}, state),
    do: {:noreply, request_repaint(%{state | checklist: items})}

  def handle_cast({:set_footer, map}, state),
    do: {:noreply, request_repaint(%{state | footer: map})}

  def handle_cast({:open_permission, title, lines, options}, state) do
    prompt = %{title: title, lines: lines, options: options, selected: 0}
    {:noreply, request_repaint(%{state | permission: prompt})}
  end

  # -- calls ------------------------------------------------------------------

  @impl true
  def handle_call(:latency_report, _from, state), do: {:reply, percentiles(state.latencies), state}
  def handle_call(:snapshot, _from, state), do: {:reply, state, state}

  # -- input events -----------------------------------------------------------

  @impl true
  def handle_info({:input_event, event}, state), do: {:noreply, apply_key(event, state)}

  def handle_info(:spinner_tick, state) do
    idx = rem(state.spinner_index + 1, length(@spinner_frames))
    {:noreply, request_repaint(%{state | spinner_index: idx})}
  end

  def handle_info(:resize_poll, state) do
    {cols, rows} = terminal_size()

    if {cols, rows} != {state.cols, state.rows} do
      {:noreply, request_repaint(%{state | cols: cols, rows: rows})}
    else
      {:noreply, state}
    end
  end

  def handle_info(:do_repaint, state) do
    {:noreply, state |> flush_latencies() |> paint() |> Map.put(:repaint_scheduled?, false)}
  end

  def handle_info(:sigwinch, state), do: {:noreply, request_repaint(state)}

  # -- key handling -------------------------------------------------------

  defp apply_key(event, state) do
    now = System.monotonic_time(:millisecond)

    state =
      case event do
        {:char, ch} -> %{state | composer: state.composer <> ch}
        :backspace -> %{state | composer: backspace(state.composer)}
        :enter -> if state.permission, do: confirm_permission(state), else: handle_enter(state)
        :alt_enter -> %{state | composer: state.composer <> "\n"}
        {:ctrl, "a"} -> state
        {:ctrl, "e"} -> state
        {:ctrl, "u"} -> %{state | composer: ""}
        {:ctrl, "k"} -> state
        {:ctrl, "w"} -> %{state | composer: drop_last_word(state.composer)}
        :shift_tab -> cycle_mode(state)
        :esc -> maybe_close_permission(state)
        :up -> move_permission(state, -1)
        :down -> move_permission(state, 1)
        {:paste, content} -> %{state | composer: state.composer <> collapse_paste(content)}
        :ctrl_c -> handle_ctrl_c(state)
        :ctrl_d -> handle_ctrl_d(state)
        :input_closed -> notify_exit(state, :input_closed)
        _ -> state
      end

    keystroke_events = [:up, :down, :esc, :ctrl_c, :ctrl_d, :input_closed]

    state =
      if event in keystroke_events do
        state
      else
        %{state | pending_keystrokes: [now | state.pending_keystrokes]}
      end

    request_repaint(state)
  end

  defp handle_enter(%{composer: composer} = state) do
    if String.ends_with?(composer, "\\") do
      %{state | composer: String.slice(composer, 0..-2//1) <> "\n"}
    else
      %{state | composer: ""}
    end
  end

  defp backspace(""), do: ""
  defp backspace(text), do: text |> String.graphemes() |> Enum.slice(0..-2//1) |> Enum.join()

  defp drop_last_word(text) do
    text
    |> String.trim_trailing()
    |> String.split(~r/\s+/)
    |> Enum.slice(0..-2//1)
    |> Enum.join(" ")
  end

  defp cycle_mode(state) do
    modes = ["normal", "auto", "plan"]
    idx = Enum.find_index(modes, &(&1 == state.footer.mode)) || 0
    next = Enum.at(modes, rem(idx + 1, length(modes)))
    %{state | footer: %{state.footer | mode: next}}
  end

  defp maybe_close_permission(%{permission: nil} = state), do: state
  defp maybe_close_permission(state), do: %{state | permission: nil}

  defp confirm_permission(%{permission: p} = state) do
    %{state | permission: nil, last_permission_choice: p.selected + 1}
  end

  # Spec §10 keybindings: Ctrl+C clears the composer; if it's already empty,
  # pressing it again within 2s exits.
  defp handle_ctrl_c(%{composer: ""} = state) do
    now = System.monotonic_time(:millisecond)

    if state.ctrl_c_at && now - state.ctrl_c_at < 2_000 do
      notify_exit(state, :ctrl_c_twice)
    else
      %{state | ctrl_c_at: now}
    end
  end

  defp handle_ctrl_c(state), do: %{state | composer: "", ctrl_c_at: nil}

  # Spec §10 keybindings: Ctrl+D exits only when the composer is empty.
  defp handle_ctrl_d(%{composer: ""} = state), do: notify_exit(state, :ctrl_d)
  defp handle_ctrl_d(state), do: state

  defp notify_exit(state, reason) do
    if state.exit_notify, do: send(state.exit_notify, {:renderer_exit, reason})
    state
  end

  defp move_permission(%{permission: nil} = state, _delta), do: state

  defp move_permission(%{permission: p} = state, delta) do
    n = length(p.options)
    selected = rem(p.selected + delta + n, n)
    %{state | permission: %{p | selected: selected}}
  end

  defp collapse_paste(content) do
    lines = content |> String.split("\n")

    if length(lines) > 3 do
      "[Pasted text ##{:erlang.unique_integer([:positive])} +#{length(lines)} lines]"
    else
      content
    end
  end

  # -- painting -------------------------------------------------------------

  defp request_repaint(%{repaint_scheduled?: true} = state), do: state

  defp request_repaint(state) do
    Process.send_after(self(), :do_repaint, @frame_ms)
    %{state | repaint_scheduled?: true}
  end

  defp do_commit(state, lines) do
    clear = if state.last_live_height > 0, do: "\r\e[#{state.last_live_height}A\e[J", else: ""
    IO.write(clear <> Enum.join(lines, "\r\n") <> "\r\n")
    %{state | last_live_height: 0, streaming_text: ""}
  end

  defp flush_latencies(state) do
    now = System.monotonic_time(:millisecond)
    new_latencies = Enum.map(state.pending_keystrokes, &(now - &1))
    %{state | latencies: state.latencies ++ new_latencies, pending_keystrokes: []}
  end

  defp paint(state) do
    lines = live_lines(state)
    max_lines = max(state.rows - 2, 3)
    lines = Enum.take(lines, max_lines)

    clear = if state.last_live_height > 0, do: "\r\e[#{state.last_live_height}A\e[J", else: ""
    IO.write(clear <> Enum.join(lines, "\r\n"))
    %{state | last_live_height: physical_height(lines, state.cols)}
  end

  # `\e[nA` moves the cursor up N *physical terminal rows*, not N logical
  # lines -- a logical line whose visible width exceeds the terminal width
  # wraps into more than one physical row, and undercounting that leaves
  # stale fragments behind on repaint (found the hard way in this spike;
  # see docs/phase0/03-terminal-spike.md).
  defp physical_height(lines, cols) when cols > 0 do
    Enum.reduce(lines, 0, fn line, acc ->
      w = line |> strip_ansi() |> Wcwidth.width()
      acc + max(1, ceil(w / cols))
    end)
  end

  defp strip_ansi(text), do: String.replace(text, ~r/\e\[[0-9;]*m/, "")

  defp live_lines(state) do
    if state.permission do
      permission_lines(state)
    else
      spinner_lines(state) ++
        checklist_lines(state) ++
        composer_lines(state) ++
        footer_lines(state)
    end
  end

  defp spinner_lines(%{streaming_text: ""} = state) do
    frame = Enum.at(@spinner_frames, state.spinner_index)
    elapsed = div(System.monotonic_time(:millisecond) - state.started_at, 1000)

    [
      "#{frame} #{state.verb}… (#{elapsed}s · ↓ #{format_k(state.tokens)} tokens · esc to interrupt)"
    ]
  end

  defp spinner_lines(state) do
    state.streaming_text
    |> String.split("\n")
    |> Enum.flat_map(&wrap_plain(&1, draw_width(state)))
    |> Enum.take(-3)
  end

  # Leave one spare column: a line that exactly fills the terminal width
  # leaves the cursor in a "deferred wrap" state that some terminals resolve
  # by eating an extra row on the next \n, which silently desyncs the
  # line-count -> cursor-up math used to redraw the live region. Cheap and
  # standard fix (same one Ink/Bubbletea use): never draw into the last column.
  defp draw_width(state), do: max(state.cols - 1, 10)

  defp checklist_lines(state) do
    Enum.map(state.checklist, fn {label, status} ->
      glyph = %{done: "☒", active: "◼", pending: "☐"}[status]
      "  #{glyph} #{label}"
    end)
  end

  defp composer_lines(state) do
    w = draw_width(state)
    inner = w - 4
    top = "╭" <> String.duplicate("─", w - 2) <> "╮"
    bottom = "╰" <> String.duplicate("─", w - 2) <> "╯"

    text_lines =
      state.composer
      |> String.split("\n")
      |> Enum.flat_map(&wrap_plain(&1, inner))

    text_lines = if text_lines == [], do: [""], else: text_lines

    body =
      Enum.map(text_lines, fn line ->
        pad = max(inner - Wcwidth.width(line), 0)
        "│ " <> line <> String.duplicate(" ", pad) <> " │"
      end)

    [top] ++ body ++ [bottom]
  end

  defp footer_lines(state) do
    f = state.footer
    ["  ⏵ #{f.mode} mode · #{f.cost} · #{f.sources} sources            ? for shortcuts"]
  end

  defp permission_lines(state) do
    p = state.permission
    w = draw_width(state)
    inner = w - 4
    top = "╭─ #{p.title} " <> String.duplicate("─", max(w - 6 - String.length(p.title), 0)) <> "╮"
    bottom = "╰" <> String.duplicate("─", w - 2) <> "╯"

    body_lines =
      Enum.map(p.lines, fn line -> "│ " <> pad_to(line, inner) <> " │" end)

    option_lines =
      p.options
      |> Enum.with_index()
      |> Enum.map(fn {opt, i} ->
        marker = if i == p.selected, do: ANSI.green() <> "❯ " <> ANSI.reset(), else: "  "
        "│ #{marker}#{i + 1}. " <> pad_to(opt, inner - 4) <> " │"
      end)

    blank = "│ " <> pad_to("", inner) <> " │"
    [top] ++ body_lines ++ [blank] ++ option_lines ++ [bottom]
  end

  defp pad_to(text, width) do
    pad = max(width - Wcwidth.width(text), 0)
    text <> String.duplicate(" ", pad)
  end

  defp wrap_plain(text, width) when width > 0 do
    text
    |> String.graphemes()
    |> Enum.chunk_while(
      {[], 0},
      fn g, {chunk, w} ->
        gw = Wcwidth.grapheme_width(g)

        if w + gw > width and chunk != [] do
          {:cont, chunk |> Enum.reverse() |> Enum.join(), {[g], gw}}
        else
          {:cont, {[g | chunk], w + gw}}
        end
      end,
      fn
        {[], _w} -> {:cont, []}
        {chunk, _w} -> {:cont, chunk |> Enum.reverse() |> Enum.join(), []}
      end
    )
  end

  defp wrap_plain(text, _width), do: [text]

  defp format_k(n) when n >= 1000, do: "#{Float.round(n / 1000, 1)}k"
  defp format_k(n), do: "#{n}"

  defp percentiles([]), do: %{p50: 0, p95: 0, max: 0, count: 0}

  defp percentiles(list) do
    sorted = Enum.sort(list)
    n = length(sorted)
    p95_idx = max(round(n * 0.95) - 1, 0)

    %{
      p50: Enum.at(sorted, div(n, 2)),
      p95: Enum.at(sorted, p95_idx),
      max: List.last(sorted),
      count: n
    }
  end

  defp terminal_size do
    {:ok, cols} = :io.columns()
    {:ok, rows} = :io.rows()
    {cols, rows}
  rescue
    _ -> {80, 24}
  end
end
