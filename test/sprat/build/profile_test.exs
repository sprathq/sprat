defmodule Sprat.Build.ProfileTest do
  use ExUnit.Case, async: true

  alias Sprat.Build.Profile

  test "ships elixir-phoenix first and node-next second" do
    assert Profile.names() == ["elixir-phoenix", "node-next"]
  end

  test "every profile's commands are an executable plus an argument array, never a string" do
    for profile <- Profile.all() do
      for command <- [profile.scaffold, profile.install, profile.test, profile.run] do
        assert is_binary(command.executable)
        assert is_list(command.args)
        assert Enum.all?(command.args, &is_binary/1)
      end
    end
  end

  test "fetch/1 finds a shipped profile by name, or nil for an unsupported one" do
    assert %Profile{name: "elixir-phoenix"} = Profile.fetch("elixir-phoenix")
    assert Profile.fetch("python-django") == nil
  end

  test "scaffold_command/2 substitutes the app name, never touching the executable" do
    profile = Profile.fetch("elixir-phoenix")
    command = Profile.scaffold_command(profile, "app_gym_booking")

    assert command.executable == "mix"
    assert "app_gym_booking" in command.args
    refute Enum.any?(command.args, &String.contains?(&1, "{{"))
  end

  test "run_command/2 substitutes the port where the profile's run command takes one" do
    node = Profile.fetch("node-next")
    command = Profile.run_command(node, 54321)
    assert "54321" in command.args

    # elixir-phoenix's run command takes no CLI port flag — its
    # generated config/runtime.exs reads the PORT env var
    # unconditionally instead (Sprat.Build.Scaffold sets it), so its run
    # command is unchanged by a port substitution.
    phoenix = Profile.fetch("elixir-phoenix")
    assert Profile.run_command(phoenix, 54321) == phoenix.run
  end
end
