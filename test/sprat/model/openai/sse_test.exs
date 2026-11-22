defmodule Sprat.Model.OpenAI.SSETest do
  use ExUnit.Case, async: true

  alias Sprat.Model.OpenAI.SSE

  test "parses a single complete frame" do
    {events, buffer} = SSE.feed("", ~s(data: {"a":1}\n\n))
    assert events == [%{"a" => 1}]
    assert buffer == ""
  end

  test "parses several frames arriving in one chunk" do
    {events, ""} = SSE.feed("", ~s(data: {"a":1}\n\ndata: {"a":2}\n\n))
    assert events == [%{"a" => 1}, %{"a" => 2}]
  end

  test "buffers a frame split across chunks" do
    {events, buffer} = SSE.feed("", ~s(data: {"a"))
    assert events == []
    {events2, buffer2} = SSE.feed(buffer, ~s(:1}\n\n))
    assert events2 == [%{"a" => 1}]
    assert buffer2 == ""
  end

  test "buffers a split right at the frame boundary" do
    {events, buffer} = SSE.feed("", ~s(data: {"a":1}\n))
    assert events == []
    {events2, ""} = SSE.feed(buffer, "\n")
    assert events2 == [%{"a" => 1}]
  end

  test "[DONE] sentinel decodes to :done" do
    {events, ""} = SSE.feed("", "data: [DONE]\n\n")
    assert events == [:done]
  end

  test "malformed JSON in a frame is skipped, not raised" do
    {events, ""} = SSE.feed("", ~s(data: {not json}\n\n))
    assert events == [:malformed]
  end

  test "ignores non-data lines (comments, event: lines)" do
    {events, ""} = SSE.feed("", ~s(event: message\ndata: {"a":1}\n\n))
    assert events == [%{"a" => 1}]
  end
end
