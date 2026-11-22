defmodule Sprat.PM.Runner do
  @moduledoc """
  One PM run (spec-v4 §8.1): a `claude -p` agent session in the project's
  directory, under the project's account (`CLAUDE_CONFIG_DIR`), with
  read-only code tools, web research, and Sprat's own MCP tools
  (`Sprat.PM.Tools`), ending in one structured `Decision`.

  The model never gets Edit/Write or a general shell. Its decision is an
  input: `Sprat.PM.Policy` decides what is actually done with it.
  """

  alias Sprat.Observer.Model.{Decision, Finding, Project, Session, SessionState}

  @actions ~w(unblock answer reassign resume wait escalate)

  @schema %{
    type: "object",
    additionalProperties: false,
    required: ~w(action obstacle tried message confidence evidence_used owner_needed),
    properties: %{
      action: %{type: "string", enum: @actions},
      obstacle: %{type: "string", description: "One sentence: what is actually in the way."},
      tried: %{
        type: "array",
        items: %{type: "string"},
        description: "What you checked and what each source said, with the source."
      },
      message: %{
        type: "string",
        description:
          "The message to put into the agent's session (≤150 words, plain text, no markdown headings). Empty for wait/escalate."
      },
      owner_note: %{
        type: "string",
        description: "The one thing only the owner can do, if any. Empty otherwise."
      },
      done_items: %{
        type: "array",
        items: %{type: "string"},
        description:
          "Roadmap item ids you verified are already done although unticked: only with a commit AND a passing run_check (or the commit alone when no check applies) cited in evidence_used. Empty otherwise."
      },
      blocked_item: %{
        type: "string",
        description: "Roadmap item id to mark blocked (reassign only)."
      },
      blocked_reason: %{type: "string"},
      next_item: %{
        type: "string",
        description: "Roadmap item id to hand the agent instead (reassign only)."
      },
      answer_source: %{
        type: "string",
        description:
          "For answer: the written decision that answers the question, as path + section + quote. Required for answer."
      },
      confidence: %{type: "string", enum: ~w(high medium low)},
      evidence_used: %{
        type: "array",
        items: %{type: "string"},
        description:
          "Evidence ids you relied on: transcript:<sid>:<line>, commit:<sha>, file:<path>, url:<url>, roadmap:<id>, fleet:<project>/<session>:<line>, memory:<query>."
      },
      owner_needed: %{type: "boolean"}
    }
  }

  @doc """
  Runs a PM investigation. `ctx` carries `%{finding, project, session, state,
  excerpt, account}`. Options: `:resume` (a previous PM session id for this
  project today), `:budget_usd` (default 0.50), `:model`, `:timeout_ms`,
  `:cmd` (injectable runner returning `{stdout, exit_code}`).
  """
  @spec run(map(), keyword()) ::
          {:ok, Decision.t(),
           %{cost_usd: float() | nil, turns: integer() | nil, session_id: String.t() | nil}}
          | {:error, term(), map()}
  def run(ctx, opts \\ []) do
    %{project: %Project{root: root}} = ctx
    prompt = prompt(ctx)
    mcp_path = write_mcp_config()

    args =
      [
        "-p",
        prompt,
        "--output-format",
        "json",
        "--json-schema",
        JSON.encode!(@schema),
        "--max-budget-usd",
        to_string(Keyword.get(opts, :budget_usd, 0.5)),
        "--mcp-config",
        mcp_path,
        # Only Sprat's tools: the owner's other MCP servers add ~50k tokens of
        # tool definitions to every run (measured 23 Nov: $0.39 → $0.05 for
        # a trivial run). MemPalace is reachable through `memory_search`.
        "--strict-mcp-config",
        "--allowedTools",
        Enum.join(allowed_tools(), " "),
        "--disallowedTools",
        "Edit Write MultiEdit NotebookEdit",
        "--append-system-prompt",
        system_prompt()
      ] ++
        if(r = opts[:resume], do: ["--resume", r], else: []) ++
        ["--model", opts[:model] || "sonnet"]

    env =
      case ctx[:account] do
        nil -> []
        dir -> [{"CLAUDE_CONFIG_DIR", dir}]
      end

    started = System.monotonic_time(:millisecond)
    cmd = Keyword.get(opts, :cmd, &default_cmd/3)

    result =
      cmd.(claude_bin(), args,
        cd: root,
        env: env,
        timeout_ms: Keyword.get(opts, :timeout_ms, 600_000)
      )

    File.rm(mcp_path)
    elapsed = System.monotonic_time(:millisecond) - started

    parse_result(result, elapsed)
  end

  @doc false
  def parse_result({out, _code}, elapsed) do
    case extract_json(out) do
      {:ok, %{"structured_output" => so} = res} when is_map(so) ->
        meta = meta(res, elapsed)

        case decision(so) do
          {:ok, d} -> {:ok, d, meta}
          {:error, reason} -> {:error, reason, meta}
        end

      {:ok, %{"is_error" => true} = res} ->
        {:error, {:claude, res["subtype"], res["result"]}, meta(res, elapsed)}

      {:ok, res} ->
        {:error, {:no_structured_output, res["subtype"]}, meta(res, elapsed)}

      :error ->
        {:error, {:unparsable, String.slice(out, 0, 400)},
         %{cost_usd: nil, turns: nil, session_id: nil, ms: elapsed}}
    end
  end

  @doc "Converts the structured output into a `Decision`, rejecting decisions with no evidence."
  def decision(so) do
    action = so["action"]

    cond do
      action not in @actions ->
        {:error, {:bad_action, action}}

      (so["evidence_used"] || []) == [] ->
        {:error, :no_evidence}

      true ->
        {:ok,
         %Decision{
           action: String.to_existing_atom(action),
           obstacle: blank_nil(so["obstacle"]),
           tried: so["tried"] || [],
           message: blank_nil(so["message"]),
           owner_note: blank_nil(so["owner_note"]),
           done_items: so["done_items"] || [],
           blocked_item: blank_nil(so["blocked_item"]),
           blocked_reason: blank_nil(so["blocked_reason"]),
           next_item: blank_nil(so["next_item"]),
           answer_source: blank_nil(so["answer_source"]),
           confidence: confidence(so["confidence"]),
           evidence_used: so["evidence_used"] || [],
           owner_needed?: so["owner_needed"] == true
         }}
    end
  end

  # -- prompt -------------------------------------------------------------------

  @doc "The user prompt for one finding. Pure."
  def prompt(ctx) do
    %{finding: %Finding{} = f, project: %Project{} = p} = ctx
    session = ctx[:session]
    state = ctx[:state]

    """
    A Claude Code agent working on the project #{p.name} (#{p.root}) needs its product manager.

    ## What Sprat detected
    Rule #{f.rule} (#{f.kind}): #{f.summary}
    Evidence ids: #{Enum.join(f.evidence, ", ")}
    #{rule_data(f)}
    ## The session
    #{session_block(session, state)}

    ## The roadmap
    #{roadmap_block(p)}

    ## What the agent has been doing (condensed transcript, newest last)
    #{ctx[:excerpt] || "(no transcript available)"}

    ## Your job
    Find out why the agent is stuck and get it moving toward the roadmap item, the way a good
    product manager would. Use, roughly in this order: the evidence above; the roadmap
    (`roadmap_get`, `roadmap_unblocked`) and the decisions written in the project's specs,
    plans, docs/PAUSE.md and CLAUDE.md (Read/Grep); the owner's memory (`memory_search`);
    how the same problem was solved in other projects (`fleet_search` with the distinctive
    part of the error); the code and git history (read-only); the web (WebSearch/WebFetch)
    for docs, issues and known fixes; `run_check` to verify a claim with the project's tests.
    Stop investigating as soon as you know enough to decide.

    Then decide ONE action:
    - unblock: you found the fix or the missing fact. `message` tells the agent the fact,
      where it came from, and the next step.
    - answer: the agent asked the owner a question that an existing WRITTEN decision
      already answers. Quote it in `answer_source` (path, section, quote). If nothing
      written covers it, do not answer: escalate with your suggestion in `owner_note`.
    - reassign: the item is blocked on something nobody can fix today. Set `blocked_item`,
      `blocked_reason`, and `next_item` (from roadmap_unblocked, same phase only), and
      `message` hands the agent the next item. Put what the owner must do in `owner_note`.
    - resume: the project has no live session and should continue; `message` is the prompt
      a new session should start from.
    - wait: the agent is actually making progress; the rule misread it. Say why in `obstacle`.
    With any action, list in `done_items` roadmap items you verified are already done but
    unticked (a matching commit, plus a passing `run_check` where a test applies).
    - escalate: only the owner can resolve this. `owner_note` says exactly what they must do.

    Never ask the agent to push, deploy, publish, delete data, run migrations on shared
    databases, handle credentials, or spend money, and never add or reorder roadmap items.
    Those belong to the owner: escalate instead. The message must start by naming the
    problem concretely, never "try harder" or "keep going".
    """
  end

  defp system_prompt do
    "You are Sprat, the product manager for the owner's coding agents. You investigate and decide; you never edit files. " <>
      "Be concrete, cite sources, and keep messages short. Your final answer must be the structured decision."
  end

  defp rule_data(%Finding{data: data}) when map_size(data) > 0,
    do: "Details: " <> (data |> Enum.map_join(", ", fn {k, v} -> "#{k}=#{fmt(v)}" end)) <> "\n"

  defp rule_data(_), do: ""

  defp session_block(nil, _), do: "No live session (the project is stalled)."

  defp session_block(%Session{} = s, state) do
    q =
      case state do
        %SessionState{asks_user?: true, pending_question: q} when is_binary(q) ->
          "\nIt asked the owner: \"#{q}\""

        _ ->
          ""
      end

    "Session #{s.name || s.session_id} (#{s.session_id}), branch #{s.branch || "?"}, status #{s.status}, cwd #{s.cwd}.#{q}"
  end

  defp roadmap_block(%Project{roadmap: nil}), do: "No roadmap found."

  defp roadmap_block(%Project{roadmap: r, position: pos}) do
    pos_line =
      case pos do
        nil ->
          ""

        pos ->
          "Position: phase #{pos.phase_id} #{pos.phase_title}, #{pos.done}/#{pos.total}, current item #{pos.item_id} #{pos.item_text}\n"
      end

    pos_line <> "Sources: #{Enum.join(r.sources, ", ")}\nUse roadmap_get for the full roadmap."
  end

  defp fmt(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp fmt(v) when is_binary(v), do: v
  defp fmt(v), do: inspect(v)

  # -- process & config -------------------------------------------------------------

  defp allowed_tools do
    ~w(Read Glob Grep WebSearch WebFetch) ++
      [
        "Bash(git log *)",
        "Bash(git show *)",
        "Bash(git diff *)",
        "Bash(git status *)",
        "Bash(git branch *)"
      ] ++
      Enum.map(Sprat.PM.Tools.definitions(), &"mcp__sprat__#{&1.name}")
  end

  @doc "Writes a temporary MCP config pointing at Sprat's own tool server; returns its path."
  def write_mcp_config do
    {command, args} = mcp_command()
    path = Path.join(System.tmp_dir!(), "sprat-mcp-#{System.unique_integer([:positive])}.json")

    File.write!(
      path,
      JSON.encode!(%{mcpServers: %{sprat: %{type: "stdio", command: command, args: args}}})
    )

    path
  end

  @doc """
  How to start the MCP tool server: the release's `sprat_rt eval` when running
  from a release, otherwise `mix run` in this checkout.
  """
  def mcp_command do
    case System.get_env("RELEASE_ROOT") do
      nil ->
        root = Application.get_env(:sprat, :source_root) || File.cwd!()

        {"sh",
         [
           "-c",
           "cd #{shell_quote(root)} && MIX_ENV=dev exec mix run --no-start --no-compile -e 'Sprat.PM.MCPServer.main()' 2>/dev/null"
         ]}

      rel ->
        {Path.join([rel, "bin", "sprat_rt"]), ["eval", "Sprat.PM.MCPServer.main()"]}
    end
  end

  defp shell_quote(s), do: "'" <> String.replace(s, "'", "'\\''") <> "'"

  defp claude_bin do
    System.get_env("SPRAT_CLAUDE_BIN") || System.find_executable("claude") ||
      Path.expand("~/.local/bin/claude")
  end

  defp default_cmd(bin, args, opts) do
    # stdin closed: `claude -p` otherwise waits 3s for piped input.
    task =
      Task.async(fn ->
        System.cmd("sh", ["-c", "exec \"$0\" \"$@\" < /dev/null", bin | args],
          cd: opts[:cd],
          env: opts[:env] || [],
          stderr_to_stdout: false
        )
      end)

    case Task.yield(task, opts[:timeout_ms] || 600_000) || Task.shutdown(task, :brutal_kill) do
      {:ok, res} -> res
      nil -> {"", :timeout}
    end
  end

  # `--output-format json` prints one result object, unless the account's
  # settings.json has `"verbose": true`: then it prints a JSON array of every
  # message, the result last. Stream-json (one object per line) is accepted
  # too.
  defp extract_json(out) do
    case JSON.decode(String.trim(out)) do
      {:ok, %{"type" => "result"} = m} -> {:ok, m}
      {:ok, list} when is_list(list) -> last_result(list)
      _ -> extract_lines(out)
    end
  rescue
    _ -> extract_lines(out)
  end

  defp last_result(list) do
    case list |> Enum.reverse() |> Enum.find(&match?(%{"type" => "result"}, &1)) do
      nil -> :error
      m -> {:ok, m}
    end
  end

  defp extract_lines(out) do
    out
    |> String.split("\n", trim: true)
    |> Enum.reverse()
    |> Enum.find_value(:error, fn line ->
      case JSON.decode(line) do
        {:ok, %{"type" => "result"} = m} -> {:ok, m}
        _ -> nil
      end
    end)
  end

  defp meta(res, elapsed),
    do: %{
      cost_usd: res["total_cost_usd"],
      turns: res["num_turns"],
      session_id: res["session_id"],
      ms: elapsed
    }

  defp confidence("high"), do: :high
  defp confidence("low"), do: :low
  defp confidence(_), do: :medium

  defp blank_nil(nil), do: nil
  defp blank_nil(s) when is_binary(s), do: if(String.trim(s) == "", do: nil, else: s)
end
