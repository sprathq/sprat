defmodule Sprat.Terminal.Input do
  @moduledoc """
  Reads raw bytes from the controlling tty, feeds them through
  `Sprat.Terminal.Keys`, and sends parsed key events to a subscriber pid as
  `{:input_event, event}`.

  Input is read via a raw, binary-mode file descriptor on `/dev/stdin`, not
  `IO.binread(:stdio, ...)`: the default `:standard_io` device is a
  unicode-decoding text-mode io server, so a 1-byte read fails the instant a
  multi-byte UTF-8 sequence starts (spike finding,
  `docs/phase0/03-terminal-spike.md`). This bypasses that layer entirely and
  does its own UTF-8 assembly in `Keys`.
  """

  use GenServer

  alias Sprat.Terminal.Keys

  @esc_timeout_ms 40

  defstruct subscriber: nil, keys: nil, esc_timer: nil

  def start_link(subscriber, opts \\ []), do: GenServer.start_link(__MODULE__, {subscriber, opts})

  @impl true
  def init({subscriber, opts}) do
    parser = self()
    reader = Keyword.get(opts, :reader, &default_reader/1)
    spawn_link(fn -> reader.(parser) end)
    {:ok, %__MODULE__{subscriber: subscriber, keys: Keys.new()}}
  end

  defp default_reader(parser) do
    {:ok, fd} = File.open("/dev/stdin", [:read, :raw, :binary])
    read_loop(parser, fd)
  end

  defp read_loop(parser, fd) do
    case :file.read(fd, 1) do
      :eof -> send(parser, :input_closed)
      {:error, _} -> send(parser, :input_closed)
      {:ok, byte} -> send(parser, {:raw_bytes, byte}) && read_loop(parser, fd)
    end
  end

  @impl true
  def handle_info({:raw_bytes, bytes}, state), do: {:noreply, feed(state, bytes)}

  def handle_info(:esc_timeout, state) do
    {events, keys} = Keys.timeout(state.keys)
    Enum.each(events, &emit(state, &1))
    {:noreply, %{state | keys: keys, esc_timer: nil}}
  end

  def handle_info(:input_closed, state) do
    emit(state, :input_closed)
    {:noreply, state}
  end

  defp feed(state, bytes) do
    {events, keys} = Keys.feed(state.keys, bytes)
    Enum.each(events, &emit(state, &1))
    state = %{state | keys: keys}

    if Keys.awaiting_esc_timeout?(keys) do
      arm_esc_timer(state)
    else
      cancel_esc_timer(state)
    end
  end

  defp arm_esc_timer(%{esc_timer: nil} = state) do
    %{state | esc_timer: Process.send_after(self(), :esc_timeout, @esc_timeout_ms)}
  end

  defp arm_esc_timer(state), do: state

  defp cancel_esc_timer(%{esc_timer: nil} = state), do: state

  defp cancel_esc_timer(state) do
    Process.cancel_timer(state.esc_timer)
    %{state | esc_timer: nil}
  end

  defp emit(state, event), do: send(state.subscriber, {:input_event, event})
end
