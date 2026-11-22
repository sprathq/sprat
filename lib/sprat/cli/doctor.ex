defmodule Sprat.CLI.Doctor do
  @moduledoc """
  Shared implementation of `sprat doctor` and the `/doctor` slash command
  (docs/spec-v1.md §13 CLI, §10 slash commands table: "Same checks as
  `sprat doctor`"): OTP/Elixir versions, the data dir and its permissions,
  database health and schema version, terminal capabilities, and the
  OpenAI key/model/budget status `Sprat.Mission` actually uses (§7, §12).
  """

  alias Sprat.Store.{Migrations, Paths}
  alias Sprat.Terminal.Mode
  alias Sprat.{Config, Secrets}

  @doc "A list of plain report lines. `project` defaults to the cwd (overridable in tests without touching the process's real cwd)."
  def report(store \\ Sprat.Store, project \\ File.cwd!()) do
    [
      "Sprat doctor",
      "",
      "Runtime",
      "  Elixir: #{System.version()}",
      "  OTP: #{:erlang.system_info(:otp_release)}",
      "",
      "Data directory"
      | data_dir_lines()
    ] ++
      ["", "Database" | database_lines(store)] ++
      ["", "Terminal" | terminal_lines()] ++
      ["", "Model backend" | model_lines(project)]
  end

  defp model_lines(project) do
    {key_line, dotenv_lines} =
      case Secrets.resolve(project) do
        {:ok, key, source} ->
          line =
            "  OpenAI key: set, from #{Secrets.describe_source(source)} (…#{Secrets.last4(key)})"

          {line, dotenv_safety_lines(source)}

        :error ->
          {"  OpenAI key: not set (OPENAI_API_KEY, .env, or the OS credential store)", []}
      end

    model = Config.model(project) || "not picked yet — first mission (or /model) picks one"
    budget = Config.budget_usd(project)
    budget_line = if budget, do: "$#{budget}", else: "not confirmed yet — first mission asks"

    [key_line | dotenv_lines] ++
      ["  Model for #{project}: #{model}", "  Budget for #{project}: #{budget_line}"]
  end

  # Only a `.env`-sourced key has a file whose permissions/git-ignore
  # status are worth checking (env var and OS credential store have
  # neither) — see `Secrets.dotenv_safety/1`'s own doc, which this was
  # written for ("used by `sprat doctor`") but nothing called it until now.
  defp dotenv_safety_lines({:dotenv, path}) do
    case Secrets.dotenv_safety(path) do
      :ok -> []
      {:warn, warnings} -> Enum.map(warnings, &"  warning: #{&1}")
    end
  end

  defp dotenv_safety_lines(_source), do: []

  defp data_dir_lines do
    {dir, reason} = Paths.data_dir_with_reason()
    mode = dir |> File.stat!() |> Map.fetch!(:mode) |> Integer.to_string(8) |> String.slice(-3, 3)
    ["  #{dir} (#{reason})", "  permissions: #{mode} (expected 700)"]
  end

  defp database_lines(store) do
    case Sprat.Store.fetch_one(store, "SELECT 1 AS ok") do
      %{"ok" => 1} ->
        [
          "  #{Paths.db_path()}",
          "  reachable: yes",
          "  schema version: #{schema_version(store)} (latest known: #{Migrations.latest_version()})"
        ]

      _ ->
        ["  #{Paths.db_path()}", "  reachable: no"]
    end
  rescue
    error -> ["  #{Paths.db_path()}", "  reachable: no (#{Exception.message(error)})"]
  end

  defp schema_version(store) do
    case Sprat.Store.fetch_one(store, "SELECT MAX(version) AS v FROM schema_migrations") do
      %{"v" => v} when is_integer(v) -> v
      _ -> 0
    end
  end

  defp terminal_lines do
    [
      "  tty: #{Mode.tty?()}",
      "  NO_COLOR: #{env_set?("NO_COLOR")}",
      "  SPRAT_ASCII: #{env_set?("SPRAT_ASCII")}"
    ]
  end

  defp env_set?(name), do: if(System.get_env(name), do: "set", else: "not set")
end
