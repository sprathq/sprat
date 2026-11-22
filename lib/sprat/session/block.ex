defmodule Sprat.Session.Block do
  @moduledoc """
  The vocabulary of a displayed transcript block (docs/spec-v1.md §10
  "Transcript blocks" table) as a plain, JSON-round-trippable map — the
  shared shape between what `Sprat.Session` keeps in memory, what it
  persists as one `messages` row (`Sprat.Store.Messages`), and what
  `Sprat.Session.Render` turns into `Sprat.Terminal.Transcript` lines.
  Keeping it a tagged map (not one struct per kind) means replay equality
  is plain `==` on the reconstructed list, which is exactly what the
  replay-equivalence property test in `test/sprat/session/session_test.exs`
  checks.
  """

  @kinds ~w(user_message agent_message tool_call tool_result stage_change
            artifact_written error gate_result system)a

  @doc "Every known block kind — used to validate before encoding."
  def kinds, do: @kinds

  @doc """
  The `messages.role` column value for a block: `"user"` for a user
  message, otherwise the block's own `:role` field when it has one (an
  agent/role name), else `"system"`.
  """
  def role_column(%{kind: :user_message}), do: "user"
  def role_column(%{role: role}) when is_binary(role), do: role
  def role_column(_block), do: "system"

  @doc "Encodes a block to the JSON string stored in `messages.content`."
  def encode(%{kind: kind} = block) when kind in @kinds do
    block |> Map.delete(:kind) |> Map.put("kind", to_string(kind)) |> JSON.encode!()
  end

  @doc """
  Decodes a `messages.content` JSON string back into a block map with atom
  keys. `String.to_atom/1` is safe here (not `to_existing_atom/1`,
  ponytail: bounded, self-written vocabulary, not attacker input) because
  every row was written by `encode/1` from this same fixed key set —
  never from arbitrary user- or model-supplied field names.

  Never raises. A row a build this old can no longer interpret — a bare
  string from before the JSON envelope existed (`content` used to just be
  the raw text; found in a real database from an old build), JSON with no
  `"kind"` field, or a `"kind"` this build has since dropped from
  `@kinds` — decodes to a `:system` placeholder block instead of crashing
  `Session.init/1`'s replay and taking the whole session down with it
  (`sprat --resume`'s only way to show *anything* for that session).
  """
  def decode(content) when is_binary(content) do
    with {:ok, raw} when is_map(raw) <- JSON.decode(content),
         map <- Map.new(raw, fn {k, v} -> {String.to_atom(k), v} end),
         {:ok, kind_str} <- Map.fetch(map, :kind),
         {:ok, kind} <- known_kind(kind_str) do
      Map.put(map, :kind, kind)
    else
      _ -> unreadable_block(content)
    end
  end

  defp known_kind(kind_str) when is_binary(kind_str) do
    kind = String.to_existing_atom(kind_str)
    if kind in @kinds, do: {:ok, kind}, else: :error
  rescue
    ArgumentError -> :error
  end

  defp known_kind(_kind_str), do: :error

  defp unreadable_block(_content) do
    %{kind: :system, text: "(a message from an older Sprat build could not be read)"}
  end
end
