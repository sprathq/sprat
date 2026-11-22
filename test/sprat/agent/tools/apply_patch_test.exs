defmodule Sprat.Agent.Tools.ApplyPatchTest do
  use Sprat.StoreCase, async: true

  alias Sprat.Agent.Tools.ApplyPatch

  setup %{tmp_dir: tmp_dir} do
    worktree = Path.join(tmp_dir, "worktree")
    File.mkdir_p!(worktree)
    {:ok, worktree: worktree}
  end

  defp context(worktree, extra \\ %{}) do
    Map.merge(%{worktree_root: worktree, granted: %{workspace_write: true}}, extra)
  end

  @original """
  line one
  line two
  line three
  """

  @good_diff """
  --- a/f.txt
  +++ b/f.txt
  @@ -1,3 +1,3 @@
   line one
  -line two
  +line TWO
   line three
  """

  describe "call/2" do
    test "applies a matching patch after verifying the precondition hash", %{worktree: worktree} do
      path = Path.join(worktree, "f.txt")
      File.write!(path, @original)
      hash = ApplyPatch.content_hash(@original)

      assert {:ok, %{"path" => "f.txt"}} =
               ApplyPatch.call(
                 %{"path" => "f.txt", "diff" => @good_diff, "expected_hash" => hash},
                 context(worktree)
               )

      assert File.read!(path) == "line one\nline TWO\nline three\n"
    end

    test "refuses when the precondition hash does not match the current file", %{
      worktree: worktree
    } do
      path = Path.join(worktree, "f.txt")
      File.write!(path, @original)

      assert {:error, %{"kind" => "precondition_mismatch"}} =
               ApplyPatch.call(
                 %{"path" => "f.txt", "diff" => @good_diff, "expected_hash" => "0000"},
                 context(worktree)
               )

      # file untouched
      assert File.read!(path) == @original
    end

    test "refuses a patch whose context doesn't match, rather than fuzzing it", %{
      worktree: worktree
    } do
      path = Path.join(worktree, "f.txt")
      stale_original = "line one\nDIFFERENT SECOND LINE\nline three\n"
      File.write!(path, stale_original)
      hash = ApplyPatch.content_hash(stale_original)

      assert {:error, %{"kind" => "context_mismatch"}} =
               ApplyPatch.call(
                 %{"path" => "f.txt", "diff" => @good_diff, "expected_hash" => hash},
                 context(worktree)
               )

      assert File.read!(path) == stale_original
    end

    test "refuses without the workspace_write grant", %{worktree: worktree} do
      path = Path.join(worktree, "f.txt")
      File.write!(path, @original)
      hash = ApplyPatch.content_hash(@original)
      ctx = %{worktree_root: worktree, granted: %{workspace_write: false}}

      assert {:needs_approval, %{action: "workspace_write"}} =
               ApplyPatch.call(
                 %{"path" => "f.txt", "diff" => @good_diff, "expected_hash" => hash},
                 ctx
               )
    end

    test "refuses a path escaping the worktree", %{worktree: worktree} do
      assert {:error, %{"kind" => "path_denied"}} =
               ApplyPatch.call(
                 %{"path" => "../../etc/passwd", "diff" => @good_diff, "expected_hash" => "x"},
                 context(worktree)
               )
    end
  end

  describe "apply_unified_diff/2 (multi-hunk)" do
    test "applies two separate hunks in one file" do
      original = "a\nb\nc\nd\ne\nf\ng\n"

      diff = """
      @@ -1,2 +1,2 @@
       a
      -b
      +B
      @@ -6,2 +6,2 @@
       f
      -g
      +G
      """

      assert {:ok, result} = ApplyPatch.apply_unified_diff(original, diff)
      assert result == "a\nB\nc\nd\ne\nf\nG\n"
    end

    test "an addition-only hunk inserts without consuming a line" do
      original = "a\nb\n"

      diff = """
      @@ -1,1 +1,2 @@
       a
      +NEW
      """

      assert {:ok, result} = ApplyPatch.apply_unified_diff(original, diff)
      assert result == "a\nNEW\nb\n"
    end
  end
end
