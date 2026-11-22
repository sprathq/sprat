defmodule Sprat.Terminal.Keys do
  @moduledoc """
  Pure byte-stream to key-event parser. Function boundary: bytes in, events
  and remaining buffer state out — no I/O, no timers. The Esc-vs-escape-
  sequence disambiguation timeout is exposed as an explicit `timeout/1` call
  so the caller (`Sprat.Terminal.Input`) owns the actual clock.

  Handles: printable UTF-8 split across reads, ANSI escape sequences
  (arrows, with modifiers), Shift+Tab, Alt+Enter, bracketed paste
  start/end markers, and C0 control bytes (Ctrl+A..Z, Enter, Backspace,
  Tab, Ctrl+C, Ctrl+D).

  ## Bracketed paste: verbatim, but not injection-proof by construction

  Everything between `\e[200~` and `\e[201~` is taken as opaque paste
  content — no key semantics (no submit on a bare `\r`, no Ctrl+C/Ctrl+D,
  nothing) apply inside the region, regardless of how the terminal
  chunks the bytes across reads or where a multi-byte UTF-8 character or
  the markers themselves happen to land relative to a chunk boundary; see
  `feed_byte/2`'s `:paste` clause, whose sliding end-marker match is
  chunk-boundary-agnostic by construction (it re-checks the trailing N
  bytes of the accumulator on every single byte fed, never assuming a
  marker arrives whole in one read).

  One limitation is inherent to the bracketed-paste protocol itself, not
  fixable at this layer: a real terminal sends pasted content byte for
  byte, so if the *pasted text itself* happens to literally contain the
  end-marker bytes (`\e[201~`), this parser — like every other bracketed-
  paste consumer (readline, vim, ...) — has no way to tell that apart
  from the terminal's own real end marker, and the paste region closes
  early there. Nothing after that point can be mistaken for a *crash* or
  *raw bytes reaching the app as live keystrokes unexpectedly*, since
  ending the region early just means later paste bytes are parsed as
  ordinary keys, the same as if the user had typed or pasted them
  separately — this is accepted upstream behavior, not something this
  module can close.
  """

  @paste_start ~c"\e[200~"
  @paste_end ~c"\e[201~"

  defstruct mode: :normal, buf: [], paste_acc: []

  @type event ::
          {:char, String.t()}
          | :enter
          | :backspace
          | :tab
          | :shift_tab
          | :alt_enter
          | :shift_enter
          | :up
          | :down
          | :left
          | :right
          | {:up | :down | :left | :right, [:shift | :alt | :ctrl]}
          | {:ctrl, String.t()}
          | :esc
          | :ctrl_c
          | :ctrl_d
          | {:paste, String.t()}

  @type t :: %__MODULE__{}

  @doc "A fresh parser state."
  def new, do: %__MODULE__{}

  @doc "Feed a chunk of raw bytes (any chunk boundary). Returns {events, new_state}."
  def feed(%__MODULE__{} = state, bytes) when is_binary(bytes) do
    :binary.bin_to_list(bytes)
    |> Enum.reduce({[], state}, fn byte, {events, state} ->
      {new_events, state} = feed_byte(state, byte)
      {events ++ new_events, state}
    end)
  end

  @doc """
  Call when the Esc-disambiguation timeout has elapsed with no further
  bytes. Emits a bare `:esc` if the buffer is exactly a lone Esc byte,
  otherwise drops whatever was buffered (it never matched a known
  sequence). No-op outside `:escape` mode.
  """
  def timeout(%__MODULE__{mode: :escape, buf: [0x1B]} = state) do
    {[:esc], reset(state)}
  end

  def timeout(%__MODULE__{mode: :escape} = state), do: {[], reset(state)}
  def timeout(%__MODULE__{} = state), do: {[], state}

  @doc "True while awaiting more bytes to disambiguate a bare Esc (used to arm the timeout)."
  def awaiting_esc_timeout?(%__MODULE__{mode: :escape, buf: [0x1B]}), do: true
  def awaiting_esc_timeout?(%__MODULE__{}), do: false

  # -- byte feeding -----------------------------------------------------------

  defp feed_byte(%{mode: :paste} = state, byte) do
    acc = [byte | state.paste_acc]
    len = length(@paste_end)

    if length(acc) >= len and acc |> Enum.take(len) |> Enum.reverse() == @paste_end do
      content =
        acc |> Enum.reverse() |> Enum.drop(-len) |> :binary.list_to_bin() |> normalize_newlines()

      {[{:paste, content}], reset(state)}
    else
      {[], %{state | paste_acc: acc}}
    end
  end

  defp feed_byte(%{mode: :escape} = state, byte) do
    buf = state.buf ++ [byte]

    case classify_escape(buf) do
      {:complete, event} -> {[event], reset(state)}
      :paste_start -> {[], %{state | mode: :paste, buf: [], paste_acc: []}}
      # Kitty key events run to about 12 bytes (`\e[32;1:3u`).
      :incomplete when length(buf) < 16 -> {[], %{state | buf: buf}}
      _unmatched -> {[], reset(%{state | buf: buf})}
    end
  end

  defp feed_byte(%{mode: :normal} = state, 0x1B), do: {[], %{state | mode: :escape, buf: [0x1B]}}
  defp feed_byte(%{mode: :normal} = state, byte) when byte in [0x0D, 0x0A], do: {[:enter], state}
  defp feed_byte(%{mode: :normal} = state, 0x7F), do: {[:backspace], state}
  defp feed_byte(%{mode: :normal} = state, 0x08), do: {[:backspace], state}
  defp feed_byte(%{mode: :normal} = state, 0x03), do: {[:ctrl_c], state}
  defp feed_byte(%{mode: :normal} = state, 0x04), do: {[:ctrl_d], state}
  defp feed_byte(%{mode: :normal} = state, 0x09), do: {[:tab], state}

  defp feed_byte(%{mode: :normal} = state, byte) when byte in 0x01..0x1A do
    {[{:ctrl, <<byte + ?a - 1>>}], state}
  end

  defp feed_byte(%{mode: :normal} = state, byte) when byte < 0x80,
    do: {[{:char, <<byte>>}], state}

  # UTF-8 lead byte: buffer until a full codepoint decodes.
  defp feed_byte(%{mode: :normal} = state, byte) when byte >= 0x80 do
    {[], %{state | mode: :utf8, buf: [byte]}}
  end

  defp feed_byte(%{mode: :utf8} = state, byte) do
    buf = state.buf ++ [byte]

    case :unicode.characters_to_binary(:binary.list_to_bin(buf), :utf8, :utf8) do
      bin when is_binary(bin) -> {[{:char, bin}], reset(state)}
      {:incomplete, _, _} when length(buf) < 4 -> {[], %{state | buf: buf}}
      _ -> {[], reset(state)}
    end
  end

  defp classify_escape(~c"\e[A"), do: {:complete, :up}
  defp classify_escape(~c"\e[B"), do: {:complete, :down}
  defp classify_escape(~c"\e[C"), do: {:complete, :right}
  defp classify_escape(~c"\e[D"), do: {:complete, :left}
  defp classify_escape(~c"\e[Z"), do: {:complete, :shift_tab}
  defp classify_escape(~c"\e[5~"), do: {:complete, :page_up}
  defp classify_escape(~c"\e[6~"), do: {:complete, :page_down}
  defp classify_escape([0x1B, 0x0D]), do: {:complete, :alt_enter}

  # Alt+<char> (Meta bit sent as a bare `Esc` prefix, the common case for
  # terminals without the Kitty protocol) — added for Terminal.Focus's
  # Alt+1..6 / Alt+n/p / Alt+[ / Alt+] / Alt+f / Alt+v/V chords (design doc
  # `docs/design/tui-zones.md` "Focus and keys"): not covered by the
  # original inline-renderer parser, which had no chord keys to parse.
  # Guarded off `?[` so a real CSI intro (`\e[...`) still falls through to
  # the `:incomplete`/paste-start path below instead of being misread.
  defp classify_escape([0x1B, byte]) when byte != ?[ and byte != 0x0D do
    {:complete, {:alt, <<byte>>}}
  end

  defp classify_escape([0x1B, ?[, ?1, ?; | rest]) when length(rest) >= 2 do
    case rest do
      [mod, dir] when dir in ~c"ABCD" -> {:complete, {arrow(dir), modifiers(mod - ?0)}}
      _ -> :incomplete
    end
  end

  # Kitty keyboard protocol encoding for Enter (keycode 13) with a modifier,
  # e.g. Shift+Enter as `\e[13;2u`, Alt+Enter as `\e[13;3u`. Not every
  # terminal emits this; Alt+Enter also arrives as plain `\e\r` (handled
  # above) on terminals without the Kitty protocol.
  defp classify_escape([0x1B, ?[, ?1, ?3, ?;, mod, ?u]) do
    case modifiers(mod - ?0) do
      mods -> if :shift in mods, do: {:complete, :shift_enter}, else: {:complete, :alt_enter}
    end
  end

  defp classify_escape(buf) do
    cond do
      list_ends_with?(buf, @paste_start) -> :paste_start
      event = kitty_u(buf) -> {:complete, event}
      true -> :incomplete
    end
  end

  # Kitty keyboard protocol (only switched on while Sprat listens to the
  # microphone, to learn when space is let go): `\e[<code>;<mods>:<event>u`
  # is `{:key, code, mods, :press | :repeat | :release}`, and the answer to
  # the support query `\e[?u` is `{:kitty_flags, flags}`.
  defp kitty_u([0x1B, ?[ | rest]) do
    with ?u <- List.last(rest),
         body = rest |> Enum.drop(-1) |> List.to_string() do
      case Regex.run(~r/^(\??)(\d+)(?:;(\d*)(?::(\d))?)?$/, body) do
        [_, "?", flags | _] ->
          {:kitty_flags, String.to_integer(flags)}

        [_, "", code | more] ->
          mods = more |> Enum.at(0, "1") |> blank_to("1") |> String.to_integer()
          event = more |> Enum.at(1, "1") |> blank_to("1")

          {:key, String.to_integer(code), modifiers(mods),
           case event do
             "2" -> :repeat
             "3" -> :release
             _ -> :press
           end}

        _ ->
          nil
      end
    else
      _ -> nil
    end
  end

  defp kitty_u(_), do: nil

  defp blank_to("", default), do: default
  defp blank_to(value, _default), do: value

  defp arrow(?A), do: :up
  defp arrow(?B), do: :down
  defp arrow(?C), do: :right
  defp arrow(?D), do: :left

  # xterm modifier encoding: 2=shift 3=alt 4=shift+alt 5=ctrl 6=shift+ctrl
  # 7=alt+ctrl 8=shift+alt+ctrl
  defp modifiers(code) do
    bits = code - 1

    []
    |> maybe_mod(bits, 1, :shift)
    |> maybe_mod(bits, 2, :alt)
    |> maybe_mod(bits, 4, :ctrl)
  end

  defp maybe_mod(acc, bits, bit, name),
    do: if(Bitwise.band(bits, bit) != 0, do: acc ++ [name], else: acc)

  defp list_ends_with?(list, suffix) do
    n = length(suffix)
    length(list) >= n and Enum.take(list, -n) == suffix
  end

  # A real terminal's bracketed paste sends `\r` (not `\n`) for pasted
  # newlines — confirmed via `tmux load-buffer` + `paste-buffer -p`, the
  # actual protocol path, vs. this module's own tests, which had only
  # ever fed `\n`. Left as raw `\r` bytes, downstream line-counting
  # (`Sprat.Terminal.Composer.insert_paste/1`, which only ever split on
  # `"\n"`) saw a 50-line paste as a *single* line under the placeholder
  # threshold, inserted the raw bytes verbatim, and the real terminal then
  # interpreted the embedded `\r`s itself on redraw — each one moving the
  # cursor back to column 0 and overwriting what was already drawn
  # ("gamma" partially overwriting "alpha" read back as "gammalpha").
  # Normalized once here, on the whole assembled buffer (not byte by
  # byte), so a `\r\n` split across two separate reads is never at risk
  # of being counted as two line breaks — by the time this runs the full
  # paste is already reassembled into one binary regardless of chunking.
  defp normalize_newlines(bin), do: String.replace(bin, ~r/\r\n|\r/, "\n")

  defp reset(state), do: %{state | mode: :normal, buf: [], paste_acc: []}
end
