defmodule Sprat.Observer.TranscriptTest do
  use ExUnit.Case, async: true

  alias Sprat.Observer.Model.Event
  alias Sprat.Observer.Transcript

  @golden Path.expand("../../fixtures/v4/transcripts/golden.jsonl", __DIR__)

  defp golden_events do
    {events, _, _} = Transcript.read_from(@golden, 0, 1)
    events
  end

  test "golden transcript: kinds in order with line numbers" do
    kinds = Enum.map(golden_events(), &{&1.line, &1.kind})

    assert kinds == [
             {2, :user_text},
             {6, :assistant_text},
             {6, :tool_use},
             {7, :tool_result},
             {8, :tool_use},
             {9, :tool_result},
             {10, :tool_use},
             {11, :tool_result},
             {12, :title},
             {13, :cost},
             {14, :pr},
             {15, :compact},
             {16, :assistant_text},
             {17, :api_error},
             {20, :assistant_text},
             {21, :tool_use}
           ]
  end

  test "golden transcript: event data" do
    ev = golden_events()
    by_line = fn n, k -> Enum.find(ev, &(&1.line == n and &1.kind == k)) end

    assert %Event{
             data: %{text: "Fix the login bug please"},
             branch: "main",
             at: ~U[2026-11-23 10:00:01.000Z]
           } =
             by_line.(2, :user_text)

    assert %{
             data: %{
               id: "toolu_1",
               name: "Bash",
               input: %{"command" => "mix test test/foo_test.exs"}
             }
           } =
             by_line.(6, :tool_use)

    assert %{data: %{tool_use_id: "toolu_1", is_error: true, text: "Exit code 2" <> _}} =
             by_line.(7, :tool_result)

    assert %{data: %{is_error: false, text: "The file " <> _}} = by_line.(9, :tool_result)
    assert %{data: %{title: "Fix the login bug"}} = by_line.(12, :title)
    assert %{data: %{total_usd: 1.25, lines_added: 10}} = by_line.(13, :cost)

    assert %{data: %{number: 42, url: "https://github.com/example/alpha/pull/42"}} =
             by_line.(14, :pr)

    assert %{data: %{trigger: "auto"}} = by_line.(15, :compact)
    assert %{sidechain?: true} = by_line.(16, :assistant_text)

    assert %{
             data: %{
               status: 429,
               limit?: true,
               limit: %{kind: :weekly, reset_at: ~U[2026-11-24 17:00:00Z]}
             }
           } = by_line.(17, :api_error)
  end

  test "parse_line never crashes" do
    for bad <- [
          "",
          "   ",
          "{",
          "[]",
          "null",
          "42",
          ~s({"type":"user"}),
          ~s({"type":"assistant","message":null}),
          ~s({"type":"user","message":{"content":[1,null,"x",{"type":"tool_result"}]}}),
          <<0xFF, 0xFE>>
        ] do
      assert is_list(Transcript.parse_line(bad, 1))
    end
  end

  test "non-limit api errors" do
    line =
      JSON.encode!(%{
        type: "assistant",
        isApiErrorMessage: true,
        error: "authentication_failed",
        timestamp: "2026-11-20T22:12:58.873Z",
        message: %{
          content: [%{type: "text", text: "Login reached its time limit · Please run /login"}]
        }
      })

    assert [
             %Event{
               kind: :api_error,
               data: %{limit?: false, limit: nil, error: "authentication_failed"}
             }
           ] =
             Transcript.parse_line(line, 3)
  end

  test "a limit without a reset time falls back to quotaLimits" do
    line =
      JSON.encode!(%{
        type: "assistant",
        isApiErrorMessage: true,
        error: "rate_limit",
        apiErrorStatus: 429,
        quotaLimits: %{resetsAt: 1_795_539_600, rateLimitType: "five_hour"},
        message: %{content: [%{type: "text", text: "You've hit your limit"}]}
      })

    assert [%Event{data: %{limit?: true, limit: %{kind: :five_hour, reset_at: reset}}}] =
             Transcript.parse_line(line, 1)

    assert reset == DateTime.from_unix!(1_795_539_600)
  end

  test "harness tags are stripped from user text, owner text kept" do
    line =
      JSON.encode!(%{
        type: "user",
        message: %{content: "<system-reminder>x</system-reminder>\nplease continue"}
      })

    assert [%Event{kind: :user_text, data: %{text: "please continue"}}] =
             Transcript.parse_line(line, 1)

    note =
      JSON.encode!(%{
        type: "user",
        message: %{content: "<task-notification>\n<task-id>a</task-id>\n</task-notification>"}
      })

    assert [] = Transcript.parse_line(note, 1)
  end

  describe "read_from" do
    @describetag :tmp_dir

    test "does not consume a trailing incomplete line, then resumes", %{tmp_dir: dir} do
      path = Path.join(dir, "t.jsonl")
      [l1, l2 | _] = File.read!(@golden) |> String.split("\n")
      partial = binary_part(l2, 0, 20)
      File.write!(path, l1 <> "\n" <> partial)

      assert {[], off, 2} = Transcript.read_from(path, 0, 1)
      assert off == byte_size(l1) + 1

      File.write!(path, binary_part(l2, 20, byte_size(l2) - 20) <> "\n", [:append])
      assert {[%Event{kind: :user_text, line: 2}], off2, 3} = Transcript.read_from(path, off, 2)
      assert off2 == File.stat!(path).size

      assert {[], ^off2, 3} = Transcript.read_from(path, off2, 3)
    end

    test "incremental reads equal one full read", %{tmp_dir: dir} do
      path = Path.join(dir, "t.jsonl")
      lines = File.read!(@golden) |> String.split("\n", trim: true)

      {acc, _, _} =
        Enum.reduce(lines, {[], 0, 1}, fn l, {acc, off, n} ->
          File.write!(path, l <> "\n", [:append])
          {evs, off, n} = Transcript.read_from(path, off, n)
          {acc ++ evs, off, n}
        end)

      assert acc == golden_events()
    end

    test "streams large files across chunk boundaries", %{tmp_dir: dir} do
      path = Path.join(dir, "big.jsonl")
      pad = String.duplicate("x", 3_000)

      line = fn i ->
        JSON.encode!(%{type: "user", message: %{content: "msg #{i} #{pad}"}}) <> "\n"
      end

      File.write!(path, Enum.map(1..1_000, line))
      size = File.stat!(path).size
      assert size > 2_000_000

      {events, ^size, 1001} = Transcript.read_from(path, 0, 1)
      assert length(events) == 1_000
      assert List.last(events).data.text =~ "msg 1000 "
      assert Enum.map(events, & &1.line) == Enum.to_list(1..1_000)
    end

    test "missing file", %{tmp_dir: dir} do
      assert {[], 7, 3} = Transcript.read_from(Path.join(dir, "nope"), 7, 3)
    end
  end

  @tag :tmp_dir
  test "locate", %{tmp_dir: dir} do
    p = Path.join(dir, "projects/-tmp-alpha/abc.jsonl")
    File.mkdir_p!(Path.dirname(p))
    File.write!(p, "")
    assert Transcript.locate(dir, "abc") == p
    assert Transcript.locate(dir, "zzz") == nil
  end

  test "a background agent that failed on a usage limit gives an :agent_limit event" do
    note =
      "<task-notification>\n<task-id>a1</task-id>\n<status>failed</status>\n" <>
        "<summary>Agent \"Write the plan\" failed: Agent terminated early due to an API error: " <>
        "You've hit your weekly limit · resets Nov 24 at 5pm (Europe/London) (error type rate_limit, " <>
        "HTTP 429)</summary>\n</task-notification>"

    line =
      JSON.encode!(%{
        "type" => "user",
        "timestamp" => "2026-11-21T19:23:15.723Z",
        "message" => %{"role" => "user", "content" => note}
      })

    assert [%{kind: :agent_limit, data: %{limit: limit}}] = Transcript.parse_line(line, 3)
    assert limit.kind == :weekly
    assert limit.reset_at == ~U[2026-11-24 17:00:00Z]
    assert limit.text == "You've hit your weekly limit · resets Nov 24 at 5pm (Europe/London)"

    ok = String.replace(note, "<status>failed</status>", "<status>completed</status>")

    ok_line =
      JSON.encode!(%{"type" => "user", "message" => %{"role" => "user", "content" => ok}})

    assert [%{kind: :agent_ok}] = Transcript.parse_line(ok_line, 4)

    # A later agent that finished clears the older agents' limit.
    st =
      Sprat.Observer.SessionState.fold(
        Transcript.parse_line(line, 3) ++ Transcript.parse_line(ok_line, 4)
      )

    assert st.agent_limit == nil
    assert Sprat.Observer.SessionState.fold(Transcript.parse_line(line, 3)).agent_limit != nil
  end

  test "carry/2 copies a transcript and its subagent folder into another account, once" do
    base = Path.join(System.tmp_dir!(), "sprat-carry-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(base) end)
    src_dir = Path.join([base, "a", "projects", "-Users-x-proj"])
    File.mkdir_p!(Path.join([src_dir, "s1", "subagents"]))
    File.write!(Path.join(src_dir, "s1.jsonl"), "{\"x\":1}\n")
    File.write!(Path.join([src_dir, "s1", "subagents", "agent-1.jsonl"]), "{}\n")
    other = Path.join(base, "b")

    assert {:ok, dest} = Transcript.carry(Path.join(src_dir, "s1.jsonl"), other)
    assert dest == Path.join([other, "projects", "-Users-x-proj", "s1.jsonl"])
    assert File.read!(dest) == "{\"x\":1}\n"

    assert File.exists?(
             Path.join([other, "projects", "-Users-x-proj", "s1", "subagents", "agent-1.jsonl"])
           )

    assert Transcript.locate(other, "s1") == dest

    # An existing copy is left alone.
    File.write!(dest, "kept")
    assert {:ok, ^dest} = Transcript.carry(Path.join(src_dir, "s1.jsonl"), other)
    assert File.read!(dest) == "kept"

    assert {:error, :no_transcript} = Transcript.carry(Path.join(src_dir, "none.jsonl"), other)
  end
end
