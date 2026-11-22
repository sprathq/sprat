defmodule Experiment.Sources do
  @moduledoc "Fetches every cited source URL to verify it's real (§6 / post-processing step 2)."

  alias Experiment.Pure

  @bot_wall_markers [
    "just a moment",
    "attention required",
    "verify you are human",
    "enable javascript and cookies",
    "captcha",
    "access denied",
    "request unsuccessful"
  ]

  @doc """
  Verify every source in `sources` (a merged/deduped list from
  `Pure.merge_and_dedup_sources/1`). Stores a text snapshot per source
  under `snapshots_dir`. Returns the sources list with `verification`
  merged into each entry.
  """
  def verify_all(sources, snapshots_dir) do
    File.mkdir_p!(snapshots_dir)

    sources
    |> Task.async_stream(&verify_one(&1, snapshots_dir),
      timeout: 15_000,
      max_concurrency: 5,
      on_timeout: :kill_task
    )
    |> Enum.map(fn
      {:ok, result} -> result
      {:exit, _} -> nil
    end)
    |> Enum.zip(sources)
    |> Enum.map(fn
      {nil, source} -> Map.put(source, "verification", timeout_verification())
      {result, source} -> Map.put(source, "verification", result)
    end)
  end

  defp verify_one(source, snapshots_dir) do
    url = source["url"]

    case Req.get(url, receive_timeout: 10_000, retry: false, redirect: true) do
      {:ok, %Req.Response{status: status, body: body, headers: headers}} ->
        text = to_text(body)
        title = extract_title(text)
        hash = :crypto.hash(:sha256, text) |> Base.encode16(case: :lower)
        final_url = final_url_from_headers(headers, url)

        snapshot_path = Path.join(snapshots_dir, hash <> ".txt")
        File.write!(snapshot_path, text)

        %{
          "status" => status,
          "final_url" => final_url,
          "title" => title,
          "content_hash" => hash,
          "snapshot_path" => Path.relative_to(snapshot_path, Path.dirname(snapshots_dir)),
          "classification" => classify(status, text)
        }

      {:error, reason} ->
        %{
          "status" => nil,
          "final_url" => url,
          "title" => nil,
          "content_hash" => nil,
          "snapshot_path" => nil,
          "classification" => "unreachable",
          "error" => inspect(reason)
        }
    end
  end

  defp timeout_verification do
    %{
      "status" => nil,
      "final_url" => nil,
      "title" => nil,
      "content_hash" => nil,
      "snapshot_path" => nil,
      "classification" => "unreachable",
      "error" => "timeout"
    }
  end

  defp classify(status, _text) when status in [401, 403, 429], do: "blocked"

  defp classify(status, text) when status in 200..299 do
    if bot_wall?(text), do: "blocked", else: "verified"
  end

  defp classify(_status, _text), do: "unreachable"

  defp bot_wall?(text) do
    lower = String.downcase(text)
    Enum.any?(@bot_wall_markers, &String.contains?(lower, &1))
  end

  defp to_text(body) when is_binary(body), do: body
  defp to_text(body), do: inspect(body)

  defp extract_title(text) do
    case Regex.run(~r/<title[^>]*>(.*?)<\/title>/si, text) do
      [_, title] -> title |> String.trim() |> String.slice(0, 300)
      nil -> nil
    end
  end

  defp final_url_from_headers(_headers, url), do: Pure.normalize_url(url)
end
