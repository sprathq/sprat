defmodule Sprat.Verify.AttachTest do
  use ExUnit.Case, async: true

  alias Sprat.Verify.Attach

  @cmd ~s|'/opt/sprat/bin/sprat_rt' eval 'Sprat.Verify.CLI.main(["stop"])'|

  @existing """
  {
    "permissions": {
      "allow": ["Bash(mix test:*)"]
    },
    "hooks": {
      "PostToolUse": [
        {"matcher": "Edit", "hooks": [{"type": "command", "command": "echo edit"}]}
      ],
      "Stop": [
        {"hooks": [{"type": "command", "command": "echo mine", "timeout": 5}]}
      ]
    },
    "model": "opus"
  }
  """

  defp quiet, do: [puts: fn _ -> :ok end, command: @cmd]

  defp settings(dir), do: Path.join([dir, ".claude", "settings.json"])

  defp read_json(dir), do: dir |> settings() |> File.read!() |> JSON.decode!()

  describe "merge/unmerge" do
    test "adds the Stop entry, keeps everything else and key order; idempotent" do
      {:ok, current} = Attach.decode(@existing)
      merged = Attach.merge(current, @cmd)
      assert Attach.merge(merged, @cmd) == merged

      text = Attach.encode(merged)
      assert text =~ ~r/"permissions".*"hooks".*"model"/s
      decoded = JSON.decode!(text)
      assert decoded["model"] == "opus"
      assert decoded["permissions"] == %{"allow" => ["Bash(mix test:*)"]}
      assert [%{"matcher" => "Edit"}] = decoded["hooks"]["PostToolUse"]
      assert [mine, sprat] = decoded["hooks"]["Stop"]

      assert mine == %{
               "hooks" => [%{"type" => "command", "command" => "echo mine", "timeout" => 5}]
             }

      assert [%{"command" => @cmd, "timeout" => 600, "type" => "command"}] = sprat["hooks"]

      assert Attach.unmerge(merged) == current
      assert Attach.unmerge(current) == current
    end

    test "re-attaching from a moved release replaces Sprat's command in place" do
      {:ok, current} = Attach.decode(@existing)
      merged = Attach.merge(current, "old-path eval 'Sprat.Verify.CLI.main([\"stop\"])'")
      again = Attach.merge(merged, @cmd)
      assert [_, sprat] = JSON.decode!(Attach.encode(again))["hooks"]["Stop"]
      assert [%{"command" => @cmd}] = sprat["hooks"]
    end

    test "unmerge of a file Sprat created leaves an empty object" do
      merged = Attach.merge({:obj, []}, @cmd)
      assert Attach.unmerge(merged) == {:obj, []}
      assert Attach.encode({:obj, []}) == "{}\n"
    end
  end

  describe "attach/2 and detach/2 on disk" do
    @tag :tmp_dir
    test "attach, attach again (no change), detach, with existing hooks preserved", %{
      tmp_dir: dir
    } do
      File.mkdir_p!(Path.dirname(settings(dir)))
      File.write!(settings(dir), @existing)
      File.write!(Path.join(dir, "mix.exs"), "")

      assert Attach.attach(dir, quiet() ++ [yes: true]) == :attached
      after_first = File.read!(settings(dir))
      assert [_, _] = read_json(dir)["hooks"]["Stop"]
      assert File.read!(Path.join([dir, ".sprat", "checks"])) =~ ~r/^mix test$/m

      assert Attach.attach(dir, quiet() ++ [yes: true]) == :unchanged
      assert File.read!(settings(dir)) == after_first

      assert Attach.detach(dir, quiet()) == :detached
      assert JSON.decode!(File.read!(settings(dir))) == JSON.decode!(@existing)
      assert Attach.detach(dir, quiet()) == :unchanged
      assert File.exists?(Path.join([dir, ".sprat", "checks"]))
    end

    @tag :tmp_dir
    test "shows the JSON and writes nothing unless confirmed", %{tmp_dir: dir} do
      me = self()
      opts = [puts: &send(me, {:out, &1}), gets: fn _ -> "n\n" end, command: @cmd]
      assert Attach.attach(dir, opts) == :aborted
      refute File.exists?(settings(dir))
      refute File.exists?(Path.join([dir, ".sprat", "checks"]))
      assert_received {:out, shown}
      assert shown =~ "Sprat will merge this Stop hook into #{settings(dir)}"
      assert_received {:out, json}
      assert json =~ "Sprat.Verify.CLI.main"

      opts = Keyword.put(opts, :gets, fn _ -> "y\n" end)
      assert Attach.attach(dir, opts) == :attached
      assert [%{"hooks" => [%{"command" => @cmd}]}] = read_json(dir)["hooks"]["Stop"]
    end

    @tag :tmp_dir
    test "refuses to overwrite a settings file that is not JSON", %{tmp_dir: dir} do
      File.mkdir_p!(Path.dirname(settings(dir)))
      File.write!(settings(dir), "{not json")
      assert {:error, _} = Attach.attach(dir, quiet() ++ [yes: true])
      assert File.read!(settings(dir)) == "{not json"
    end

    @tag :tmp_dir
    test "keeps an existing .sprat/checks", %{tmp_dir: dir} do
      File.mkdir_p!(Path.join(dir, ".sprat"))
      File.write!(Path.join([dir, ".sprat", "checks"]), "make check\n")
      assert Attach.attach(dir, quiet() ++ [yes: true]) == :attached
      assert File.read!(Path.join([dir, ".sprat", "checks"])) == "make check\n"
    end
  end

  describe "hook_command/0" do
    test "dev: an absolute mix run in this source checkout" do
      cmd = Attach.hook_command()
      assert cmd =~ ~s|run --no-start --no-compile -e 'Sprat.Verify.CLI.main(["stop"])'|
      assert cmd =~ ~r/^cd '\//
    end
  end

  describe "detect_default/1" do
    @tag :tmp_dir
    test "per stack", %{tmp_dir: dir} do
      at = fn files ->
        d = Path.join(dir, "p#{System.unique_integer([:positive])}")
        File.mkdir_p!(d)
        Enum.each(files, fn {f, body} -> File.write!(Path.join(d, f), body) end)
        Attach.detect_default(d)
      end

      assert at.([]) == nil
      assert at.([{"mix.exs", ""}]) == "mix test"
      assert at.([{"package.json", ~s({"scripts": {"test": "vitest"}})}]) == "npm test"

      assert at.([
               {"package.json",
                ~s({"scripts": {"test": "echo \\"Error: no test specified\\" && exit 1"}})}
             ]) ==
               nil

      assert at.([{"package.json", ~s({"name": "x"})}]) == nil
      assert at.([{"pubspec.yaml", ""}]) == "flutter test"
      assert at.([{"Cargo.toml", ""}]) == "cargo test"
      assert at.([{"go.mod", ""}]) == "go test ./..."
      assert at.([{"pyproject.toml", "[tool.pytest.ini_options]\n"}]) == "pytest"
      assert at.([{"pytest.ini", ""}]) == "pytest"
      assert at.([{"pyproject.toml", "[tool.black]\n"}]) == nil
    end

    test "template comments out a missing default" do
      assert Sprat.Verify.parse_checks(Attach.checks_template(nil)) == []
      assert Sprat.Verify.parse_checks(Attach.checks_template("cargo test")) == ["cargo test"]
    end
  end
end
