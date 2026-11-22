defmodule Sprat.Terminal.InputTest do
  use ExUnit.Case, async: true

  alias Sprat.Terminal.Input

  test "feeds bytes from the injected reader through Keys and emits events to the subscriber" do
    reader = fn parser ->
      send(parser, {:raw_bytes, "hi"})
      send(parser, {:raw_bytes, <<0x0D>>})
    end

    {:ok, _pid} = Input.start_link(self(), reader: reader)

    assert_receive {:input_event, {:char, "h"}}, 200
    assert_receive {:input_event, {:char, "i"}}, 200
    assert_receive {:input_event, :enter}, 200
  end

  test "a bare Esc is emitted after the disambiguation timeout" do
    reader = fn parser -> send(parser, {:raw_bytes, <<0x1B>>}) end
    {:ok, _pid} = Input.start_link(self(), reader: reader)
    assert_receive {:input_event, :esc}, 300
  end

  test "input_closed is forwarded when the reader signals EOF" do
    reader = fn parser -> send(parser, :input_closed) end
    {:ok, _pid} = Input.start_link(self(), reader: reader)
    assert_receive {:input_event, :input_closed}, 200
  end
end
