defmodule Sprat.Store.Redact do
  @moduledoc """
  Scrubs secret values out of anything before it is written to the
  database or the blob store (docs/spec-v1.md §11: "API keys and any
  value loaded from the credential store are redacted before any write or
  render").

  This is deliberately *not* a helper callers can forget: `Sprat.Store.Events`
  and `Sprat.Store.Blob` call `scrub/2` themselves on every payload they
  write, so there is no write path that bypasses it. The secret set comes
  from `Sprat.Secrets` at runtime (not built yet — callers pass it in
  explicitly); this module has no knowledge of *where* secrets come from,
  only how to remove them from a term.
  """

  @marker "[REDACTED]"

  @doc """
  Walks `payload` (a string, or a map/list/tuple tree of strings), replacing
  every occurrence of any string in `secrets` with a marker. Returns
  `{scrubbed_payload, redacted?}`. Secrets shorter than 4 characters are
  skipped to avoid nuking common words if a short/empty value ever ends up
  in the secret set.
  """
  def scrub(payload, secrets) when is_list(secrets) do
    secrets = secrets |> Enum.filter(&(is_binary(&1) and byte_size(&1) >= 4)) |> Enum.uniq()

    if secrets == [] do
      {payload, false}
    else
      {scrubbed, found?} = walk(payload, secrets, false)
      {scrubbed, found?}
    end
  end

  defp walk(value, secrets, found?) when is_binary(value) do
    scrubbed = Enum.reduce(secrets, value, &String.replace(&2, &1, @marker))
    {scrubbed, found? or scrubbed != value}
  end

  defp walk(value, secrets, found?) when is_map(value) do
    Enum.reduce(value, {%{}, found?}, fn {k, v}, {acc, f} ->
      {v2, f2} = walk(v, secrets, f)
      {Map.put(acc, k, v2), f2}
    end)
  end

  defp walk(value, secrets, found?) when is_list(value) do
    Enum.reduce(value, {[], found?}, fn item, {acc, f} ->
      {v2, f2} = walk(item, secrets, f)
      {[v2 | acc], f2}
    end)
    |> then(fn {acc, f} -> {Enum.reverse(acc), f} end)
  end

  defp walk(value, secrets, found?) when is_tuple(value) do
    {list, f} = walk(Tuple.to_list(value), secrets, found?)
    {List.to_tuple(list), f}
  end

  defp walk(value, _secrets, found?), do: {value, found?}
end
