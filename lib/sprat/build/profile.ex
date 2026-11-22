defmodule Sprat.Build.Profile do
  @moduledoc """
  Stack profiles (docs/spec-v2.md §4): "Data, not code" — a shipped,
  versioned data file (`priv/build/profiles.json`), loaded the same way
  `Sprat.Model.Pricing` loads the model allowlist. A profile declares
  every command the build workflow ever runs as an executable plus an
  explicit argument array, ready for `Sprat.Agent.Tools.Shell` — never a
  string a shell would have to split.

  `elixir-phoenix` ships first, `node-next` second (§4/§15 Phase A: "one
  profile, native execution"). A mission whose brief needs a stack
  outside `names/0` is refused by name at the design gate
  (`Sprat.Workflow.Gate`), never improvised.
  """

  defmodule Command do
    @moduledoc "One shell-ready command: a bare executable plus an argument array."
    defstruct [:executable, :args]
    @type t :: %__MODULE__{executable: String.t(), args: [String.t()]}
  end

  defmodule HealthCheck do
    @moduledoc "How the scaffold stage proves the run command actually started."
    defstruct [:path, :expect_status_min, :expect_status_max, :timeout_ms, :poll_interval_ms]

    @type t :: %__MODULE__{
            path: String.t(),
            expect_status_min: integer(),
            expect_status_max: integer(),
            timeout_ms: integer(),
            poll_interval_ms: integer()
          }
  end

  defstruct [
    :name,
    :label,
    :stack,
    :run_target,
    :allowed_executables,
    :scaffold,
    :install,
    :test,
    :run,
    :lint,
    :format,
    :health_check,
    :layout_conventions
  ]

  @type t :: %__MODULE__{name: String.t()}

  @doc "Path to the shipped profiles file."
  def default_path, do: Application.app_dir(:sprat, "priv/build/profiles.json")

  @doc "Loads and parses the shipped profiles file (or `path`, mainly for tests)."
  def load(path \\ default_path()) do
    data = path |> File.read!() |> JSON.decode!()
    %{version: data["version"], profiles: Enum.map(data["profiles"], &parse_profile/1)}
  end

  @doc "Every shipped profile."
  def all, do: load().profiles

  @doc "Every shipped profile's `name` — the set the design gate checks against."
  def names, do: Enum.map(all(), & &1.name)

  @doc "Fetches a profile by name, or `nil`."
  def fetch(name), do: Enum.find(all(), &(&1.name == name))

  @doc "`scaffold`'s command with `{{APP_NAME}}` substituted."
  def scaffold_command(%__MODULE__{} = profile, app_name),
    do: interpolate(profile.scaffold, %{"APP_NAME" => app_name})

  @doc """
  `run`'s command with `{{PORT}}` substituted in its argument array, for
  a profile whose run command takes a CLI port flag (`node-next`). The
  scaffold stage also sets a `PORT` env var unconditionally when it
  starts this command (build brief item 4: "pick a free port rather than
  assuming the default is free") — `mix phx.new`'s own generated
  `config/runtime.exs` reads exactly that, unconditionally, so
  `elixir-phoenix`'s run command needs no substitution here at all.
  """
  def run_command(%__MODULE__{} = profile, port),
    do: interpolate(profile.run, %{"PORT" => to_string(port)})

  defp interpolate(%Command{args: args} = command, subs) do
    %{command | args: Enum.map(args, &substitute(&1, subs))}
  end

  defp substitute(arg, subs) do
    Enum.reduce(subs, arg, fn {token, value}, acc ->
      String.replace(acc, "{{#{token}}}", value)
    end)
  end

  defp parse_profile(p) do
    %__MODULE__{
      name: p["name"],
      label: p["label"],
      stack: p["stack"],
      run_target: p["run_target"],
      allowed_executables: p["allowed_executables"],
      scaffold: parse_command(p["scaffold"]),
      install: parse_command(p["install"]),
      test: parse_command(p["test"]),
      run: parse_command(p["run"]),
      lint: parse_command(p["lint"]),
      format: parse_command(p["format"]),
      health_check: parse_health_check(p["health_check"]),
      layout_conventions: p["layout_conventions"]
    }
  end

  defp parse_command(%{"executable" => executable, "args" => args}),
    do: %Command{executable: executable, args: args}

  defp parse_health_check(%{} = hc) do
    %HealthCheck{
      path: hc["path"],
      expect_status_min: hc["expect_status_min"],
      expect_status_max: hc["expect_status_max"],
      timeout_ms: hc["timeout_ms"],
      poll_interval_ms: hc["poll_interval_ms"]
    }
  end
end
