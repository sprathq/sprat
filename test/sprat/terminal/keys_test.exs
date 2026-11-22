defmodule Sprat.Terminal.KeysTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Sprat.Terminal.Keys

  defp feed_all(state, bytes) do
    {events, state} = Keys.feed(state, bytes)
    {events, state}
  end

  test "printable ASCII characters" do
    {events, _} = feed_all(Keys.new(), "aZ9")
    assert events == [{:char, "a"}, {:char, "Z"}, {:char, "9"}]
  end

  test "enter, backspace, tab" do
    {events, _} = feed_all(Keys.new(), <<0x0D, 0x7F, 0x09>>)
    assert events == [:enter, :backspace, :tab]
  end

  test "ctrl+a..z" do
    {events, _} = feed_all(Keys.new(), <<1, 5, 23>>)
    assert events == [{:ctrl, "a"}, {:ctrl, "e"}, {:ctrl, "w"}]
  end

  test "ctrl_c and ctrl_d" do
    {events, _} = feed_all(Keys.new(), <<0x03, 0x04>>)
    assert events == [:ctrl_c, :ctrl_d]
  end

  test "arrow keys" do
    {events, _} = feed_all(Keys.new(), "\e[A\e[B\e[C\e[D")
    assert events == [:up, :down, :right, :left]
  end

  test "shift+tab" do
    {events, _} = feed_all(Keys.new(), "\e[Z")
    assert events == [:shift_tab]
  end

  test "page up/down" do
    {events, _} = feed_all(Keys.new(), "\e[5~\e[6~")
    assert events == [:page_up, :page_down]
  end

  test "Alt+<char> chords (Terminal.Focus's Alt+1..6/n/p/[/]/f/v/V)" do
    {events, _} = feed_all(Keys.new(), "\e1\en\ep\ef\eV")
    assert events == [{:alt, "1"}, {:alt, "n"}, {:alt, "p"}, {:alt, "f"}, {:alt, "V"}]
  end

  test "Alt+<char> does not swallow a real CSI sequence that starts with the same Esc" do
    {events, _} = feed_all(Keys.new(), "\e[A")
    assert events == [:up]
  end

  test "alt+enter" do
    {events, _} = feed_all(Keys.new(), <<0x1B, 0x0D>>)
    assert events == [:alt_enter]
  end

  test "modified arrow keys" do
    {events, _} = feed_all(Keys.new(), "\e[1;5C")
    assert events == [{:right, [:ctrl]}]

    {events, _} = feed_all(Keys.new(), "\e[1;2A")
    assert events == [{:up, [:shift]}]
  end

  test "kitty-protocol shift+enter and alt+enter" do
    {events, _} = feed_all(Keys.new(), "\e[13;2u")
    assert events == [:shift_enter]

    {events, _} = feed_all(Keys.new(), "\e[13;3u")
    assert events == [:alt_enter]
  end

  test "UTF-8 characters decode as single events" do
    {events, _} = feed_all(Keys.new(), "中文😀")
    assert events == [{:char, "中"}, {:char, "文"}, {:char, "😀"}]
  end

  test "UTF-8 sequence split across separate feed calls still decodes" do
    bytes = :unicode.characters_to_binary("😀", :utf8, :utf8)
    <<a, b, c, d>> = bytes

    {e1, s} = Keys.feed(Keys.new(), <<a>>)
    {e2, s} = Keys.feed(s, <<b>>)
    {e3, s} = Keys.feed(s, <<c>>)
    {e4, _s} = Keys.feed(s, <<d>>)

    assert e1 == []
    assert e2 == []
    assert e3 == []
    assert e4 == [{:char, "😀"}]
  end

  test "bracketed paste start/end markers collapse to one paste event" do
    {events, _} = feed_all(Keys.new(), "\e[200~line1\nline2\e[201~")
    assert events == [{:paste, "line1\nline2"}]
  end

  test "escape-sequence bytes never leak through a paste body" do
    {events, _} = feed_all(Keys.new(), "\e[200~a\e[Bb\e[201~")
    assert events == [{:paste, "a\e[Bb"}]
  end

  # Bug: `tmux paste-buffer -p` — the real bracketed-paste path, not this
  # test file's own `\n`-only fixtures — sends `\r` for pasted newlines.
  # Left as raw `\r`, downstream line-counting only ever split on `\n`,
  # so a real multi-line paste was seen as one line (no placeholder) and
  # the raw `\r` bytes, once rendered, made the *real terminal* itself
  # overwrite earlier text on redraw ("gamma" over "alpha" read back as
  # "gammalpha"). `\r`, `\n`, and `\r\n` must all normalize to `\n`.
  describe "bracketed paste: line-ending normalization" do
    test "a CR-terminated paste (tmux paste-buffer's real wire format) normalizes to \\n" do
      {events, _} = feed_all(Keys.new(), "\e[200~alpha\rbeta\rgamma\e[201~")
      assert events == [{:paste, "alpha\nbeta\ngamma"}]
    end

    test "a CRLF-terminated paste normalizes to \\n, not \\n\\n" do
      {events, _} = feed_all(Keys.new(), "\e[200~alpha\r\nbeta\r\ngamma\e[201~")
      assert events == [{:paste, "alpha\nbeta\ngamma"}]
    end

    test "an LF-terminated paste is unaffected" do
      {events, _} = feed_all(Keys.new(), "\e[200~alpha\nbeta\ngamma\e[201~")
      assert events == [{:paste, "alpha\nbeta\ngamma"}]
    end

    test "mixed CR/LF/CRLF within one paste all normalize the same way" do
      {events, _} = feed_all(Keys.new(), "\e[200~a\rb\nc\r\nd\e[201~")
      assert events == [{:paste, "a\nb\nc\nd"}]
    end

    # A CRLF split right down the middle across two reads is the case
    # naive per-byte normalization gets wrong (turning it into two line
    # breaks instead of one) — the whole paste is reassembled into one
    # binary before normalization runs, so this can't happen regardless
    # of where the chunk boundary falls.
    test "a CRLF split across chunk boundaries is still one line break" do
      state = Keys.new()
      {[], state} = Keys.feed(state, "\e[200~alpha\r")
      {events, _state} = Keys.feed(state, "\nbeta\e[201~")
      assert events == [{:paste, "alpha\nbeta"}]
    end

    test "a 50-line CR-terminated paste is 50 lines, not one" do
      body = Enum.map_join(1..50, "\r", &"line #{&1}")
      {events, _} = feed_all(Keys.new(), "\e[200~#{body}\e[201~")
      assert [{:paste, content}] = events
      assert content |> String.split("\n") |> length() == 50
    end
  end

  describe "bracketed paste: chunk boundaries inside the content, not just at the markers" do
    test "an escape sequence inside the pasted content, split mid-sequence across reads, survives verbatim" do
      state = Keys.new()
      {[], state} = Keys.feed(state, "\e[200~a\e[")
      {[], state} = Keys.feed(state, "B")
      {events, _state} = Keys.feed(state, "b\e[201~")
      assert events == [{:paste, "a\e[Bb"}]
    end

    test "a multi-byte UTF-8 character inside the pasted content, split mid-character across reads, survives verbatim" do
      emoji = :unicode.characters_to_binary("😀", :utf8, :utf8)
      <<a, b, c, d>> = emoji
      state = Keys.new()
      {[], state} = Keys.feed(state, "\e[200~hi ")
      {[], state} = Keys.feed(state, <<a, b>>)
      {[], state} = Keys.feed(state, <<c>>)
      {events, _state} = Keys.feed(state, <<d>> <> "\e[201~")
      assert events == [{:paste, "hi " <> emoji}]
    end

    test "the end marker itself split across every possible byte boundary is still recognized" do
      marker = "\e[201~"

      for split <- 1..(byte_size(marker) - 1) do
        <<first::binary-size(split), rest::binary>> = marker
        state = Keys.new()
        {[], state} = Keys.feed(state, "\e[200~content" <> first)
        {events, _state} = Keys.feed(state, rest)
        assert events == [{:paste, "content"}], "failed for split at byte #{split}"
      end
    end
  end

  test "bare Esc is only emitted after the disambiguation timeout" do
    {events, state} = feed_all(Keys.new(), <<0x1B>>)
    assert events == []
    assert Keys.awaiting_esc_timeout?(state)

    {events, state} = Keys.timeout(state)
    assert events == [:esc]
    refute Keys.awaiting_esc_timeout?(state)
  end

  test "an unmatched escape sequence is dropped on timeout, not emitted as esc" do
    {_events, state} = feed_all(Keys.new(), "\e[9")
    {events, _state} = Keys.timeout(state)
    assert events == []
  end

  property "arbitrary chunking of the same byte stream yields the same events" do
    sequences = [
      "hello",
      <<0x0D, 0x7F, 1, 5, 0x03, 0x04>>,
      "\e[A\e[B\e[C\e[D\e[Z",
      "中文😀 mixed ascii",
      "\e[200~pasted content here\e[201~",
      "\e[200~alpha\rbeta\r\ngamma\ndelta\e[201~",
      "\e[1;5C\e[1;2A"
    ]

    check all(
            bytes <- StreamData.member_of(sequences),
            chunk_sizes <-
              StreamData.list_of(StreamData.integer(1..3), min_length: 1, max_length: 40)
          ) do
      whole = elem(Keys.feed(Keys.new(), bytes), 0)
      chunked = feed_in_chunks(bytes, chunk_sizes)
      assert whole == chunked
    end
  end

  defp feed_in_chunks(bytes, chunk_sizes) do
    {events, _state} = do_feed_in_chunks(bytes, chunk_sizes, Keys.new(), [])
    events
  end

  defp do_feed_in_chunks(<<>>, _sizes, state, acc), do: {Enum.concat(Enum.reverse(acc)), state}

  defp do_feed_in_chunks(bytes, [], state, acc) do
    {events, state} = Keys.feed(state, bytes)
    {Enum.concat(Enum.reverse([events | acc])), state}
  end

  defp do_feed_in_chunks(bytes, [size | rest], state, acc) do
    take = min(size, byte_size(bytes))
    <<chunk::binary-size(take), remainder::binary>> = bytes
    {events, state} = Keys.feed(state, chunk)
    do_feed_in_chunks(remainder, rest, state, [events | acc])
  end
end
