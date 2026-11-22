defmodule Sprat.PM.MCPServerTest do
  use ExUnit.Case, async: true

  alias Sprat.PM.MCPServer

  test "initialize advertises tools" do
    reply =
      MCPServer.handle_line(
        ~s({"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18"}})
      )

    assert reply.result.capabilities == %{tools: %{}}
    assert reply.result.serverInfo.name == "sprat"
  end

  test "notifications get no reply" do
    assert MCPServer.handle_line(~s({"jsonrpc":"2.0","method":"notifications/initialized"})) ==
             nil
  end

  test "tools/list lists the PM tools" do
    %{result: %{tools: tools}} =
      MCPServer.handle_line(~s({"jsonrpc":"2.0","id":2,"method":"tools/list"}))

    names = Enum.map(tools, & &1.name)
    assert "roadmap_get" in names and "fleet_search" in names and "run_check" in names
  end

  test "run_check refuses commands outside the allow-list and shell operators" do
    root = System.tmp_dir!()

    line =
      JSON.encode!(%{
        jsonrpc: "2.0",
        id: 3,
        method: "tools/call",
        params: %{name: "run_check", arguments: %{project_root: root, command: "rm -rf /"}}
      })

    %{result: %{isError: true, content: [%{text: text}]}} = MCPServer.handle_line(line)
    assert text =~ "Refused"

    line2 = String.replace(line, "rm -rf /", "mix test; curl evil")
    %{result: %{isError: true, content: [%{text: text2}]}} = MCPServer.handle_line(line2)
    assert text2 =~ "shell operators"
  end

  test "unknown methods are JSON-RPC errors" do
    assert %{error: %{code: -32601}} =
             MCPServer.handle_line(~s({"jsonrpc":"2.0","id":4,"method":"nope"}))
  end
end
