defmodule Sprat.Agent.Tools.WriteFile do
  @moduledoc """
  `write_file` tool (docs/spec-v2.md §7/§9): writes a build task's changes,
  confined to that task's worktree.

  `context` required keys:

    * `:worktree_root` — the task's `Sprat.Workspace` root. Every write is
      checked against exactly this root, via
      `Sprat.Agent.Tools.Files.safe_path/2`'s symlink-resolution and
      deny-pattern checks (§7: "the same symlink and deny-pattern checks
      `Files.safe_path/2` uses"), never the user's own checkout.
    * `:granted` — `%{workspace_write: boolean}`. Missing the grant is
      `{:needs_approval, ...}` (the session layer's job to ask, once per
      mission, per docs/spec-v2.md §9); a path that escapes the worktree
      is always a hard `{:error, ...}`, **never** a prompt — there is
      nothing to approve about a path outside the granted root.

  Optional: `:store`, `:session_id`, `:mission_id`, `:task_id`, `:secrets`
  — when `:session_id` is present, every successful write is recorded as
  an event carrying a diff summary (lines added/removed, byte counts), not
  the full before/after content.
  """

  @behaviour Sprat.Agent.Tool

  alias Sprat.Agent.Tools.Files
  alias Sprat.Store.Events

  @impl true
  def name, do: "write_file"

  @impl true
  def spec do
    %{
      "type" => "function",
      "function" => %{
        "name" => "write_file",
        "description" => "Write a file's full contents, confined to the task's worktree.",
        "parameters" => %{
          "type" => "object",
          "properties" => %{
            "path" => %{"type" => "string"},
            "content" => %{"type" => "string"}
          },
          "required" => ["path", "content"]
        }
      }
    }
  end

  @impl true
  def call(%{"path" => path, "content" => content}, context) do
    with :ok <- check_grant(context),
         {:ok, real} <- Files.safe_path(worktree_root(context), path),
         :ok <- reject_directory(real) do
      before_bytes =
        case File.read(real) do
          {:ok, content} -> content
          {:error, _} -> ""
        end

      File.mkdir_p!(Path.dirname(real))
      File.write!(real, content)

      record_write(context, path, before_bytes, content)
      {:ok, %{"path" => path, "bytes_written" => byte_size(content)}}
    else
      {:error, reason} when reason in [:path_escapes_root, :denied_pattern, :invalid_path] ->
        {:error, %{"kind" => "path_denied", "message" => "refused: #{path} (#{reason})"}}

      {:error, %{"kind" => _} = error} ->
        {:error, error}

      {:error, reason} ->
        {:error, %{"kind" => "write_failed", "message" => inspect(reason)}}

      other ->
        other
    end
  end

  def call(_args, _context), do: {:error, "expected {\"path\": ..., \"content\": ...}"}

  defp check_grant(context) do
    if get_in(context, [:granted, :workspace_write]) do
      :ok
    else
      {:needs_approval, %{action: "workspace_write", reason: :grant_not_yet_given}}
    end
  end

  defp worktree_root(context), do: Map.fetch!(context, :worktree_root)

  defp reject_directory(real) do
    if File.dir?(real),
      do: {:error, %{"kind" => "path_is_directory", "message" => "#{real} is a directory"}},
      else: :ok
  end

  defp record_write(context, path, before, after_content) do
    with session_id when is_binary(session_id) <- Map.get(context, :session_id) do
      Events.append(
        Map.get(context, :store, Sprat.Store),
        session_id,
        "tool.write_file",
        %{
          mission_id: Map.get(context, :mission_id),
          task_id: Map.get(context, :task_id),
          payload: diff_summary(path, before, after_content)
        },
        Map.get(context, :secrets, [])
      )
    end

    :ok
  end

  defp diff_summary(path, before, after_content) do
    before_lines = String.split(before, "\n")
    after_lines = String.split(after_content, "\n")

    %{
      "path" => path,
      "bytes_before" => byte_size(before),
      "bytes_after" => byte_size(after_content),
      "lines_before" => length(before_lines),
      "lines_after" => length(after_lines)
    }
  end
end
