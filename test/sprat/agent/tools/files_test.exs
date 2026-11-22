defmodule Sprat.Agent.Tools.FilesTest do
  use ExUnit.Case, async: true

  alias Sprat.Agent.Tools.Files

  setup do
    root = Path.join(System.tmp_dir!(), "sprat-files-test-#{System.unique_integer([:positive])}")

    outside =
      Path.join(
        System.tmp_dir!(),
        "sprat-files-test-outside-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(root)
    File.mkdir_p!(outside)

    File.write!(Path.join(root, "readme.md"), "hello world\nsecond line with SECRET\n")
    File.mkdir_p!(Path.join(root, "sub"))
    File.write!(Path.join(root, "sub/nested.txt"), "nested content\n")
    File.write!(Path.join(root, ".env"), "OPENAI_API_KEY=sk-should-not-be-readable\n")
    File.write!(Path.join(outside, "secret.txt"), "outside content\n")

    on_exit(fn ->
      File.rm_rf(root)
      File.rm_rf(outside)
    end)

    {:ok, root: root, outside: outside}
  end

  test "reads a plain file inside root", %{root: root} do
    assert {:ok, content} = Files.read_file(root, "readme.md")
    assert content =~ "hello world"
  end

  test "reads a nested file", %{root: root} do
    assert {:ok, "nested content\n"} = Files.read_file(root, "sub/nested.txt")
  end

  test "blocks path traversal with ..", %{root: root} do
    assert {:error, _} = Files.read_file(root, "../../../../etc/passwd")
  end

  test "blocks an absolute path escape disguised as relative", %{root: root, outside: outside} do
    assert {:error, _} =
             Files.read_file(root, Path.join(["..", Path.basename(outside), "secret.txt"]))
  end

  test "blocks .env by deny pattern even though it's inside root", %{root: root} do
    assert {:error, :denied_pattern} = Files.read_file(root, ".env")
  end

  test "blocks a symlink inside root that points outside root", %{root: root, outside: outside} do
    link = Path.join(root, "escape_link")
    File.ln_s!(outside, link)
    assert {:error, :path_escapes_root} = Files.read_file(root, "escape_link/secret.txt")
  end

  test "allows a symlink that stays inside root", %{root: root} do
    link = Path.join(root, "sub_link")
    File.ln_s!(Path.join(root, "sub"), link)
    assert {:ok, "nested content\n"} = Files.read_file(root, "sub_link/nested.txt")
  end

  test "glob lists files under root and excludes denied ones", %{root: root} do
    assert {:ok, paths} = Files.glob(root, "**/*")
    assert "readme.md" in paths
    assert "sub/nested.txt" in paths
    refute ".env" in paths
  end

  test "grep finds matching lines with path/line/text", %{root: root} do
    assert {:ok, [%{path: "readme.md", line: 2, text: text}]} = Files.grep(root, "SECRET")
    assert text =~ "SECRET"
  end

  test "grep never surfaces content from a denied file", %{root: root} do
    assert {:ok, matches} = Files.grep(root, "OPENAI_API_KEY")
    assert matches == []
  end
end
