defmodule Sprat.Spike.Input do
  @moduledoc """
  Point 1 + 2: raw byte reader and key/escape-sequence parser, including
  bracketed-paste and Esc-vs-escape-sequence disambiguation via a short
  timeout (a plain Esc byte with nothing following it within @esc_timeout_ms
  is not distinguishable from the *start* of a sequence any other way).

  One GenServer owns the parser state; a linked reader process feeds it raw
  bytes one at a time so the parser can `receive ... after` for the Esc
  timeout without blocking the blocking `IO.binread/2` call.
  """

  use GenServer

  @esc_timeout_ms 40
  # ponytail: composer decides the display text; we just tell it how big the
  # paste was so it can render "[Pasted text #1 +N lines]".
  @paste_start ~c"\e[200~"
  @paste_end ~c"\e[201~"

  defstruct subscriber: nil, mode: :normal, buf: [], paste_acc: [], esc_timer: nil

  def start_link(subscriber), do: GenServer.start_link(__MODULE__, subscriber)

  @impl true
  def init(subscriber) do
    parser = self()
    spawn_link(fn -> read_loop(parser) end)
    {:ok, %__MODULE__{subscriber: subscriber}}
  end

  # Deliberately NOT `IO.binread(:stdio, 1)`: :standard_io is a text-mode
  # (unicode-decoding) io device, so reading one byte at a time errors out
  # (looks like EOF) the instant a multi-byte UTF-8 sequence starts, because
  # the io server tries to decode each single byte as a whole codepoint.
  # Opening /dev/stdin in :raw + :binary mode reads the fd directly,
  # bypassing that text layer entirely -- exact bytes in, no surprises.
  # We do our own UTF-8 assembly afterwards (see feed/2 below).
  defp read_loop(parser) do
    {:ok, fd} = File.open("/dev/stdin", [:read, :raw, :binary])
    raw_read_loop(parser, fd)
  end

  defp raw_read_loop(parser, fd) do
    case :file.read(fd, 1) do
      :eof -> send(parser, :input_closed)
      {:error, _} -> send(parser, :input_closed)
      {:ok, <<byte>>} -> send(parser, {:raw_byte, byte}) && raw_read_loop(parser, fd)
    end
  end

  @impl true
  def handle_info({:raw_byte, byte}, state), do: {:noreply, feed(state, byte)}

  def handle_info(:esc_timeout, %{mode: :escape, buf: [0x1B]} = state) do
    {:noreply, state |> emit(:esc) |> reset()}
  end

  def handle_info(:esc_timeout, %{mode: :escape} = state) do
    # buffered bytes never matched a known sequence -> drop them.
    {:noreply, reset(state)}
  end

  def handle_info(:esc_timeout, state), do: {:noreply, state}

  def handle_info(:input_closed, state) do
    emit(state, :input_closed)
    {:noreply, state}
  end

  # -- byte feeding --------------------------------------------------------

  defp feed(%{mode: :paste} = state, byte) do
    # paste_acc is built by prepending, so its most-recent bytes are at the
    # head — compare the head (reversed back to chronological order) against
    # the end marker, not the tail.
    acc = [byte | state.paste_acc]
    len = length(@paste_end)

    if length(acc) >= len and acc |> Enum.take(len) |> Enum.reverse() == @paste_end do
      content = acc |> Enum.reverse() |> Enum.drop(-len) |> :binary.list_to_bin()
      state |> emit({:paste, content}) |> reset()
    else
      %{state | paste_acc: acc}
    end
  end

  defp feed(%{mode: :escape} = state, byte) do
    buf = state.buf ++ [byte]

    case classify_escape(buf) do
      {:complete, event} ->
        state |> emit(event) |> reset()

      :paste_start ->
        cancel_timer(state)
        %{state | mode: :paste, buf: [], paste_acc: []}

      :incomplete when length(buf) < 8 ->
        %{state | buf: buf}

      _unmatched ->
        # give up on this sequence, but don't lose the byte that broke it
        reset(%{state | buf: buf})
    end
  end

  defp feed(%{mode: :normal} = state, 0x1B) do
    timer = Process.send_after(self(), :esc_timeout, @esc_timeout_ms)
    %{state | mode: :escape, buf: [0x1B], esc_timer: timer}
  end

  defp feed(%{mode: :normal} = state, byte) when byte in [0x0D, 0x0A], do: emit(state, :enter)
  defp feed(%{mode: :normal} = state, 0x7F), do: emit(state, :backspace)
  defp feed(%{mode: :normal} = state, 0x08), do: emit(state, :backspace)
  defp feed(%{mode: :normal} = state, 0x03), do: emit(state, :ctrl_c)
  defp feed(%{mode: :normal} = state, 0x04), do: emit(state, :ctrl_d)
  defp feed(%{mode: :normal} = state, 0x09), do: emit(state, :tab)

  defp feed(%{mode: :normal} = state, byte) when byte in 0x01..0x1A do
    emit(state, {:ctrl, <<byte + ?a - 1>>})
  end

  defp feed(%{mode: :normal} = state, byte) when byte < 0x80 do
    emit(state, {:char, <<byte>>})
  end

  # UTF-8 lead byte: buffer until we can decode a full codepoint.
  defp feed(%{mode: :normal} = state, byte) when byte >= 0x80 do
    %{state | mode: :utf8, buf: [byte]}
  end

  defp feed(%{mode: :utf8} = state, byte) do
    buf = state.buf ++ [byte]
    # buf holds raw bytes, not codepoints -- must decode as a binary, not a
    # charlist, or Erlang treats each byte as an already-decoded codepoint.
    case :unicode.characters_to_binary(:binary.list_to_bin(buf), :utf8, :utf8) do
      bin when is_binary(bin) -> state |> emit({:char, bin}) |> reset()
      {:incomplete, _, _} when length(buf) < 4 -> %{state | buf: buf}
      _ -> reset(state)
    end
  end

  defp classify_escape(~c"\e[A"), do: {:complete, :up}
  defp classify_escape(~c"\e[B"), do: {:complete, :down}
  defp classify_escape(~c"\e[C"), do: {:complete, :right}
  defp classify_escape(~c"\e[D"), do: {:complete, :left}
  defp classify_escape(~c"\e[Z"), do: {:complete, :shift_tab}
  defp classify_escape([0x1B, 0x0D]), do: {:complete, :alt_enter}

  defp classify_escape(buf) do
    cond do
      list_ends_with?(buf, @paste_start) -> :paste_start
      true -> :incomplete
    end
  end

  defp list_ends_with?(list, suffix) do
    n = length(suffix)
    length(list) >= n and Enum.take(list, -n) == suffix
  end

  defp emit(state, event) do
    send(state.subscriber, {:input_event, event})
    state
  end

  defp cancel_timer(%{esc_timer: nil} = state), do: state

  defp cancel_timer(state) do
    Process.cancel_timer(state.esc_timer)
    state
  end

  defp reset(state), do: %{cancel_timer(state) | mode: :normal, buf: [], esc_timer: nil}
end
