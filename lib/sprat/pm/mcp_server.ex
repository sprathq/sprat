defmodule Sprat.PM.MCPServer do
  @moduledoc """
  A minimal MCP server over stdio (newline-delimited JSON-RPC 2.0) exposing
  `Sprat.PM.Tools` to Sprat's own PM runs (`claude -p --mcp-config …`).

  Started as `sprat mcp` (release) or `mix sprat.mcp` (dev). It needs no
  running Sprat: every tool reads files or runs commands directly, so it does
  not start the application (no store, no UI).
  """

  @protocol "2025-06-18"

  @doc "Runs the server loop on stdin/stdout until stdin closes."
  def main(opts \\ []) do
    :io.setopts(:standard_io, binary: true, encoding: :latin1)
    loop(opts)
  end

  defp loop(opts) do
    case IO.binread(:stdio, :line) do
      :eof ->
        :ok

      {:error, _} ->
        :ok

      line ->
        line = String.trim(line)

        if line != "" do
          case handle_line(line, opts) do
            nil -> :ok
            reply -> IO.binwrite(:stdio, JSON.encode!(reply) <> "\n")
          end
        end

        loop(opts)
    end
  end

  @doc "Handles one JSON-RPC message; returns the reply map or nil for notifications."
  def handle_line(line, opts \\ []) do
    case JSON.decode(line) do
      {:ok, %{"method" => method, "id" => id} = msg} ->
        reply(id, handle(method, msg["params"] || %{}, opts))

      {:ok, %{"method" => _notification}} ->
        nil

      {:ok, _} ->
        nil

      {:error, _} ->
        %{jsonrpc: "2.0", id: nil, error: %{code: -32700, message: "Parse error"}}
    end
  end

  defp reply(id, {:ok, result}), do: %{jsonrpc: "2.0", id: id, result: result}

  defp reply(id, {:error, code, message}),
    do: %{jsonrpc: "2.0", id: id, error: %{code: code, message: message}}

  defp handle("initialize", params, _opts) do
    {:ok,
     %{
       protocolVersion: params["protocolVersion"] || @protocol,
       capabilities: %{tools: %{}},
       serverInfo: %{name: "sprat", version: "4.0.0"}
     }}
  end

  defp handle("ping", _params, _opts), do: {:ok, %{}}
  defp handle("tools/list", _params, _opts), do: {:ok, %{tools: Sprat.PM.Tools.definitions()}}

  defp handle("tools/call", %{"name" => name} = params, opts) do
    result =
      try do
        Sprat.PM.Tools.call(name, params["arguments"] || %{}, opts)
      rescue
        e -> {:error, "Tool crashed: " <> Exception.message(e)}
      end

    case result do
      {:ok, text} -> {:ok, %{content: [%{type: "text", text: text}], isError: false}}
      {:error, text} -> {:ok, %{content: [%{type: "text", text: text}], isError: true}}
    end
  end

  defp handle(method, _params, _opts), do: {:error, -32601, "Method not found: #{method}"}
end
