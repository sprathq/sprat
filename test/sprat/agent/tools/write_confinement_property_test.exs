defmodule Sprat.Agent.Tools.WriteConfinementPropertyTest do
  @moduledoc """
  Property: for arbitrary path-shaped input, neither `write_file` nor
  `apply_patch` can ever produce a file outside the granted worktree root
  (docs/spec-v2.md §7 write-scope rule).
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Sprat.Agent.Tools.{ApplyPatch, WriteFile}

  setup do
    tmp = Path.join(System.tmp_dir!(), "sprat-confine-#{System.unique_integer([:positive])}")
    worktree = Path.join(tmp, "worktree")
    outside = Path.join(tmp, "outside")
    File.mkdir_p!(worktree)
    File.mkdir_p!(outside)

    on_exit(fn -> File.rm_rf(tmp) end)

    {:ok, worktree: worktree, outside: outside, tmp: tmp}
  end

  # A generator biased toward the shapes that actually try to escape:
  # "..", absolute paths, and paths through an existing symlink — plain
  # StreamData.string/1 would spend almost all its budget on paths that
  # trivially stay inside root and prove nothing.
  defp escape_ish_path_segment do
    StreamData.one_of([
      StreamData.constant(".."),
      StreamData.constant("."),
      StreamData.string(:alphanumeric, min_length: 1, max_length: 8),
      StreamData.constant(""),
      StreamData.constant("etc"),
      StreamData.constant("escape_link")
    ])
  end

  defp escape_ish_path do
    StreamData.list_of(escape_ish_path_segment(), min_length: 1, max_length: 6)
    |> StreamData.map(&Enum.join(&1, "/"))
    |> StreamData.bind(fn rel ->
      StreamData.one_of([
        StreamData.constant(rel),
        StreamData.constant("/" <> rel)
      ])
    end)
  end

  property "write_file never writes outside worktree_root, for arbitrary path input", %{
    worktree: worktree,
    outside: outside
  } do
    link = Path.join(worktree, "escape_link")
    unless File.exists?(link), do: File.ln_s!(outside, link)

    check all(path <- escape_ish_path(), max_runs: 200) do
      before_outside = list_all_files(outside)

      _ = WriteFile.call(%{"path" => path, "content" => "x"}, base_context(worktree))

      after_outside = list_all_files(outside)

      assert before_outside == after_outside,
             "write_file wrote into #{outside} via #{inspect(path)}"

      assert every_file_under?(worktree)
    end
  end

  property "apply_patch never writes outside worktree_root, for arbitrary path input", %{
    worktree: worktree,
    outside: outside
  } do
    link = Path.join(worktree, "escape_link")
    unless File.exists?(link), do: File.ln_s!(outside, link)

    diff = """
    --- a/f
    +++ b/f
    @@ -1,1 +1,1 @@
    -x
    +y
    """

    check all(path <- escape_ish_path(), max_runs: 200) do
      before_outside = list_all_files(outside)

      _ =
        ApplyPatch.call(
          %{"path" => path, "diff" => diff, "expected_hash" => "0000000000"},
          base_context(worktree)
        )

      after_outside = list_all_files(outside)

      assert before_outside == after_outside,
             "apply_patch wrote into #{outside} via #{inspect(path)}"
    end
  end

  defp base_context(worktree), do: %{worktree_root: worktree, granted: %{workspace_write: true}}

  defp list_all_files(root) do
    root
    |> Path.join("**/*")
    |> Path.wildcard(match_dot: true)
    |> Enum.filter(&File.regular?/1)
    |> Enum.map(&{&1, File.stat!(&1).size})
    |> Enum.sort()
  end

  defp every_file_under?(worktree) do
    real_root = worktree |> Path.expand()

    worktree
    |> Path.join("**/*")
    |> Path.wildcard(match_dot: true)
    |> Enum.filter(&File.regular?/1)
    |> Enum.all?(&String.starts_with?(Path.expand(&1), real_root))
  end
end
