defmodule Sprat.PM.RunnerTest do
  use ExUnit.Case, async: true

  alias Sprat.PM.Runner
  alias Sprat.Observer.Model.{Decision, Finding, Project}

  @result ~s({"type":"result","subtype":"success","is_error":false,"total_cost_usd":0.31,"num_turns":11,"session_id":"pm-1","structured_output":{"action":"reassign","obstacle":"cert missing","tried":["fleet_search: fixed by owner on 2 Oct"],"message":"Stop retrying; move to B.5.","owner_note":"Import the cert.","blocked_item":"B.7","blocked_reason":"needs cert","next_item":"B.5","answer_source":"","confidence":"high","evidence_used":["transcript:s:1822"],"owner_needed":false}})

  test "parses a structured decision with its cost" do
    assert {:ok,
            %Decision{
              action: :reassign,
              blocked_item: "B.7",
              next_item: "B.5",
              confidence: :high,
              answer_source: nil
            }, %{cost_usd: 0.31, turns: 11, session_id: "pm-1"}} =
             Runner.parse_result({@result, 0}, 5)
  end

  test "parses the array printed when the account's settings have verbose on" do
    out =
      ~s([{"type":"system","subtype":"init"},{"type":"assistant","message":{}},) <> @result <> "]"

    assert {:ok, %Decision{action: :reassign}, %{cost_usd: 0.31}} =
             Runner.parse_result({out, 0}, 5)
  end

  test "a decision without evidence is rejected" do
    bad =
      String.replace(@result, ~s("evidence_used":["transcript:s:1822"]), ~s("evidence_used":[]))

    assert {:error, :no_evidence, _} = Runner.parse_result({bad, 0}, 5)
  end

  test "errors from claude are surfaced" do
    out =
      ~s({"type":"result","subtype":"error_max_budget_usd","is_error":true,"result":"budget","total_cost_usd":0.5})

    assert {:error, {:claude, "error_max_budget_usd", _}, %{cost_usd: 0.5}} =
             Runner.parse_result({out, 1}, 5)

    assert {:error, {:unparsable, _}, _} = Runner.parse_result({"garbage", 1}, 5)
  end

  test "run passes the account, cwd, schema and read-only tools to claude" do
    parent = self()

    cmd = fn bin, args, opts ->
      send(parent, {:ran, bin, args, opts})
      {@result, 0}
    end

    ctx = %{
      finding: %Finding{
        id: "f",
        rule: "L1",
        kind: :stuck,
        project_root: "/p",
        summary: "error loop",
        evidence: ["transcript:s:1"]
      },
      project: %Project{root: "/p", name: "p"},
      account: "/Users/x/.claude-other"
    }

    assert {:ok, %Decision{}, _} = Runner.run(ctx, cmd: cmd, resume: "pm-0")
    assert_received {:ran, _bin, args, opts}
    assert opts[:cd] == "/p"
    assert {"CLAUDE_CONFIG_DIR", "/Users/x/.claude-other"} in opts[:env]
    assert "--json-schema" in args and "--resume" in args
    tools = Enum.at(args, Enum.find_index(args, &(&1 == "--allowedTools")) + 1)
    assert tools =~ "mcp__sprat__fleet_search"
    refute tools =~ "Edit"
  end
end
