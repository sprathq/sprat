defmodule Sprat.Observer.Transcript do
  @moduledoc """
  Claude Code transcripts (spec §4.2): `<config>/projects/<slug>/<session_id>.jsonl`.

  `parse_line/2` turns one JSON record into zero or more `%Event{}`s, keeping
  only the record types in `00-spikes.md` §1 and ignoring every other type and
  field. `read_from/3` tails a file from a byte offset, streaming in chunks and
  never consuming a trailing incomplete line.
  """

  alias Sprat.Observer.Model.Event
  alias Sprat.Observer.UsageLimit

  @chunk 1_048_576
  @max_text 2_000

  # Tags whose whole block is harness chatter, not the owner's words.
  @harness_tags ~w(system-reminder command-name command-message command-args command-contents
                   local-command-stdout local-command-stderr local-command-caveat task-notification
                   user-prompt-submit-hook)

  @harness_re Regex.compile!(
                "<(" <> Enum.join(@harness_tags, "|") <> ")(?:\\s[^>]*)?>.*?</\\1>",
                "s"
              )

  @doc "The transcript path for a session, or nil."
  @spec locate(String.t(), String.t()) :: String.t() | nil
  def locate(config_dir, session_id) do
    config_dir
    |> Path.join("projects/*/#{session_id}.jsonl")
    |> Path.wildcard()
    |> List.first()
  end

  @doc """
  Copies a session's transcript (and its `<session_id>/` folder of subagent
  transcripts, when there is one) into another account's config dir, under
  the same project folder name, so `claude --resume` works there with the
  whole conversation. Accounts keep separate `projects/` folders unless they
  share one through a symlink. Returns the copy's path; an existing copy is
  left alone.
  """
  @spec carry(String.t(), String.t(), (term() -> any())) :: {:ok, String.t()} | {:error, term()}
  def carry(source_path, config_dir, progress \\ fn _ -> :ok end) do
    folder = source_path |> Path.dirname() |> Path.basename()
    sid = Path.basename(source_path, ".jsonl")
    dest_dir = Path.join([config_dir, "projects", folder])
    dest = Path.join(dest_dir, sid <> ".jsonl")
    side = Path.join(Path.dirname(source_path), sid)

    cond do
      File.exists?(dest) ->
        {:ok, dest}

      not File.regular?(source_path) ->
        {:error, :no_transcript}

      true ->
        with :ok <- File.mkdir_p(dest_dir),
             :ok <- copy_reporting(source_path, dest, progress),
             :ok <- carry_side(side, Path.join(dest_dir, sid), progress) do
          {:ok, dest}
        end
    end
  end

  @chunk 4 * 1_048_576

  # Copies in chunks, reporting `{:bytes, done, total}` about every 5%, into
  # a temporary name renamed at the end: a copy cut short never looks like a
  # whole conversation to `claude --resume`.
  defp copy_reporting(src, dest, progress) do
    total = File.stat!(src).size
    tmp = dest <> ".part"
    progress.({:bytes, 0, total})

    result =
      File.open(src, [:read, :raw, :binary], fn input ->
        File.open(tmp, [:write, :raw, :binary], fn output ->
          copy_chunks(input, output, 0, total, 0, progress)
        end)
      end)

    case result do
      {:ok, {:ok, :ok}} ->
        File.rename(tmp, dest)

      {:ok, {:ok, error}} ->
        File.rm(tmp)
        error

      {:ok, error} ->
        File.rm(tmp)
        error

      error ->
        File.rm(tmp)
        error
    end
  end

  defp copy_chunks(input, output, done, total, last, progress) do
    case IO.binread(input, @chunk) do
      :eof ->
        progress.({:bytes, done, total})
        :ok

      {:error, _} = e ->
        e

      data ->
        :ok = IO.binwrite(output, data)
        done = done + byte_size(data)

        last =
          if total > 0 and (done - last) * 20 >= total do
            progress.({:bytes, done, total})
            done
          else
            last
          end

        copy_chunks(input, output, done, total, last, progress)
    end
  end

  defp carry_side(side, dest, progress) do
    if File.dir?(side) and not File.exists?(dest) do
      progress.({:files, side |> Path.join("**/*") |> Path.wildcard() |> length()})

      case File.cp_r(side, dest) do
        {:ok, _} -> :ok
        {:error, reason, _} -> {:error, reason}
      end
    else
      :ok
    end
  end

  @doc """
  Reads complete lines from `offset`. Returns the events, the offset just past
  the last complete line, and the next line number. A trailing line without a
  newline is left for the next call.
  """
  @spec read_from(String.t(), non_neg_integer(), pos_integer()) ::
          {[Event.t()], non_neg_integer(), pos_integer()}
  def read_from(path, offset, next_line) do
    case File.open(path, [:read, :binary, :raw]) do
      {:ok, io} ->
        try do
          {:ok, _} = :file.position(io, offset)
          {events, consumed, line} = loop(io, "", [], 0, next_line)
          {events |> Enum.reverse() |> List.flatten(), offset + consumed, line}
        after
          File.close(io)
        end

      {:error, _} ->
        {[], offset, next_line}
    end
  end

  defp loop(io, carry, acc, consumed, line) do
    case :file.read(io, @chunk) do
      {:ok, data} ->
        buf = carry <> data
        {lines, rest} = split_complete(buf)

        {acc, line} =
          Enum.reduce(lines, {acc, line}, fn l, {acc, n} ->
            case parse_line(l, n) do
              [] -> {acc, n + 1}
              evs -> {[evs | acc], n + 1}
            end
          end)

        loop(io, rest, acc, consumed + byte_size(buf) - byte_size(rest), line)

      :eof ->
        {acc, consumed, line}

      {:error, _} ->
        {acc, consumed, line}
    end
  end

  defp split_complete(buf) do
    case :binary.matches(buf, "\n") do
      [] ->
        {[], buf}

      matches ->
        {pos, _} = List.last(matches)
        complete = binary_part(buf, 0, pos)
        rest = binary_part(buf, pos + 1, byte_size(buf) - pos - 1)
        {:binary.split(complete, "\n", [:global]), rest}
    end
  end

  @doc "Parses one JSONL record. Never raises; unknown or bad records give `[]`."
  @spec parse_line(binary(), pos_integer()) :: [Event.t()]
  def parse_line(bin, line_no) do
    case decode(bin) do
      {:ok, %{"type" => type} = r} -> record(type, r, line_no)
      _ -> []
    end
  rescue
    _ -> []
  end

  defp decode(bin) do
    case String.trim(bin) do
      "" -> :error
      t -> JSON.decode(t)
    end
  end

  defp record("user", %{"isMeta" => true}, _), do: []
  defp record("user", %{"isCompactSummary" => true}, _), do: []

  defp record("user", %{"message" => %{"content" => content}} = r, n) do
    content
    |> blocks()
    |> Enum.flat_map(fn
      %{"type" => "text", "text" => t} ->
        agent_limits(t, r, n) ++
          case clean_user_text(t) do
            nil -> []
            text -> [event(:user_text, r, n, %{text: text})]
          end

      %{"type" => "tool_result"} = b ->
        [
          event(:tool_result, r, n, %{
            tool_use_id: b["tool_use_id"],
            is_error: b["is_error"] == true,
            text: result_text(b["content"])
          })
        ]

      _ ->
        []
    end)
  end

  defp record("assistant", %{"isApiErrorMessage" => true} = r, n) do
    text = r |> get_in(["message", "content"]) |> blocks() |> texts() |> Enum.join("\n")
    at = timestamp(r)
    limit? = r["error"] == "rate_limit" or UsageLimit.limit_text?(text)

    limit =
      if limit? do
        case UsageLimit.parse(text, at || DateTime.utc_now()) do
          {:ok, l} -> l
          :error -> quota_limit(r["quotaLimits"], text)
        end
      end

    [
      event(:api_error, r, n, %{
        status: r["apiErrorStatus"],
        error: r["error"],
        text: text,
        limit?: limit?,
        limit: limit
      })
    ]
  end

  defp record("assistant", %{"message" => %{"content" => content}} = r, n) do
    content
    |> blocks()
    |> Enum.flat_map(fn
      %{"type" => "text", "text" => t} when is_binary(t) ->
        if String.trim(t) == "", do: [], else: [event(:assistant_text, r, n, %{text: t})]

      %{"type" => "tool_use"} = b ->
        [event(:tool_use, r, n, %{id: b["id"], name: b["name"], input: b["input"] || %{}})]

      _ ->
        []
    end)
  end

  defp record("ai-title", %{"aiTitle" => t} = r, n) when is_binary(t),
    do: [event(:title, r, n, %{title: t})]

  defp record("cost-state", %{"totalCostUSD" => c} = r, n) when is_number(c),
    do: [
      event(:cost, r, n, %{
        total_usd: c,
        lines_added: r["totalLinesAdded"],
        lines_removed: r["totalLinesRemoved"]
      })
    ]

  defp record("pr-link", r, n),
    do: [
      event(:pr, r, n, %{number: r["prNumber"], url: r["prUrl"], repository: r["prRepository"]})
    ]

  defp record("system", %{"compactMetadata" => meta} = r, n) when is_map(meta),
    do: [event(:compact, r, n, %{trigger: meta["trigger"], pre_tokens: meta["preTokens"]})]

  defp record(_, _, _), do: []

  # A background agent that died on a usage limit only says so in the
  # task-notification Claude Code hands the main thread:
  #   <status>failed</status> <summary>Agent "…" failed: … You've hit your
  #   weekly limit · resets Nov 24 at 5pm (Europe/London) …</summary>
  defp agent_limits(text, r, n) when is_binary(text) do
    if String.contains?(text, "<task-notification>") do
      at = timestamp(r) || DateTime.utc_now()

      ~r/<task-notification>(.*?)<\/task-notification>/s
      |> Regex.scan(text, capture: :all_but_first)
      |> Enum.flat_map(fn [body] ->
        with false <- completed_agent?(body),
             true <- String.contains?(body, "<status>failed</status>"),
             true <- UsageLimit.limit_text?(body),
             {:ok, l} <- UsageLimit.parse(body, at) do
          [event(:agent_limit, r, n, %{limit: %{l | text: limit_sentence(l.text)}})]
        else
          # An agent that finished means agents run again: an older agents'
          # limit no longer holds.
          true -> [event(:agent_ok, r, n, %{})]
          _ -> []
        end
      end)
    else
      []
    end
  end

  defp completed_agent?(body), do: String.contains?(body, "<status>completed</status>")

  defp limit_sentence(text) do
    case Regex.run(~r/You've hit your[^(]*\([^)]+\)/, text) do
      [sentence] -> sentence
      _ -> String.slice(text, 0, 200)
    end
  end

  defp event(kind, r, n, data) do
    %Event{
      kind: kind,
      line: n,
      at: timestamp(r),
      data: data,
      branch: if(is_binary(r["gitBranch"]), do: r["gitBranch"]),
      sidechain?: r["isSidechain"] == true
    }
  end

  defp blocks(s) when is_binary(s), do: [%{"type" => "text", "text" => s}]
  defp blocks(l) when is_list(l), do: Enum.filter(l, &is_map/1)
  defp blocks(_), do: []

  defp texts(blocks), do: for(%{"type" => "text", "text" => t} when is_binary(t) <- blocks, do: t)

  defp result_text(c) when is_binary(c), do: truncate(c)

  defp result_text(l) when is_list(l),
    do: l |> blocks() |> texts() |> Enum.join("\n") |> truncate()

  defp result_text(_), do: ""

  defp truncate(s) when byte_size(s) > @max_text, do: binary_part(s, 0, @max_text) |> scrub()
  defp truncate(s), do: s

  # binary_part can split a UTF-8 sequence; drop a trailing partial char.
  defp scrub(s) do
    if String.valid?(s), do: s, else: scrub(binary_part(s, 0, byte_size(s) - 1))
  end

  @doc false
  def clean_user_text(t) when is_binary(t) do
    cleaned = @harness_re |> Regex.replace(t, "") |> String.trim()
    if cleaned == "", do: nil, else: cleaned
  end

  def clean_user_text(_), do: nil

  defp timestamp(%{"timestamp" => ts}) when is_binary(ts) do
    case DateTime.from_iso8601(ts) do
      {:ok, dt, _} -> dt
      _ -> nil
    end
  end

  defp timestamp(_), do: nil

  # Older or reworded messages: fall back to the structured quota data.
  defp quota_limit(%{"resetsAt" => secs} = q, text) when is_integer(secs) do
    %{
      kind: UsageLimit.kind_from_type(q["rateLimitType"]),
      reset_at: DateTime.from_unix!(secs),
      text: text,
      zone: "Etc/UTC",
      zone_fallback?: false
    }
  end

  defp quota_limit(_, _), do: nil
end
