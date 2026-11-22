defmodule Sprat.Config do
  @moduledoc """
  Two config scopes, both JSON (see the note below on why, not TOML):

    * **project** — `<project>/.sprat/config.json`, the per-project model
      pick and confirmed mission budget cap this module has always
      persisted (docs/spec-v1.md §12/§7).
    * **user** — `~/.config/sprat/config.json` (overridable via the
      `:sprat, :user_config_dir` app env, mainly for tests), a ceiling and
      a set of defaults the project scope can narrow but never widen.

  `effective/1` reports, for every setting the Settings surface shows,
  which of `:user`, `:project` or `:default` produced the value actually
  in effect — §13's "Precedence: user config → project config → mission
  options... `/doctor` shows effective values and where each came from."
  Only `color_mode` reads an environment override on top of that chain
  (`NO_COLOR`/`SPRAT_ASCII`, `Sprat.Terminal.Glyphs`'s existing detection)
  — the spec's precedence table doesn't call out env for the general
  settings, but the real color/ASCII code already gives env the final say,
  so `effective/1` reports that honestly rather than hiding it.

  §13's storage layout names `.sprat/config.toml`, but this build has no
  `toml` dependency in `mix.exs` (ponytail: "no new deps without strong
  justification" for a handful of settings) — JSON, already used
  everywhere else here, covers the same need without adding one.

  ## Enforcement (write path, not just the UI)

  `put_project_budget_usd/2` is the *only* way project scope's budget cap
  is written, and it always checks `enforce_project_budget/2` first: a
  project can lower a user-level cap, never raise it. There is no project
  config key for the credential source at all — `Sprat.Secrets`'s
  resolution order (env → `.env` → OS credential store) is fixed code, not
  a config value, so there is nothing in this module's schema a project
  file could set to change it; `reject_credential_key!/1` exists as a
  belt-and-braces guard for the one generic setter (`put_project/3`) so
  that stays true even if a key list grows later.
  """

  @dir ".sprat"
  @filename "config.json"

  @default_warn_percent 80
  @default_permission_mode "normal"
  @default_research_depth "standard"
  @default_color_mode "auto"

  @project_keys ~w(model budget_usd warn_percent permission_mode research_depth color_mode
                   search_provider search_model notify_bell notify_desktop)

  # design doc web-search-options.md §7: only backend actually built.
  @default_search_provider "openai"
  # The only model this doc's live tests ran `web_search` against
  # (design doc §3.1/§3.2/§7) — pinned separately from the researcher's
  # own model (§9 open question #3), never picked per-role.
  @default_search_model "gpt-5.6-luna"

  # -- project scope (existing API, unchanged shape) -----------------------

  @doc "The config file path for `project_path` (`nil` if there is no project path)."
  def path(nil), do: nil
  def path(project_path), do: Path.join([project_path, @dir, @filename])

  @doc "Loads `project_path`'s config as a string-keyed map. `%{}` if there is none yet."
  def load(nil), do: %{}
  def load(project_path), do: read(path(project_path))

  @doc "The persisted model id, or `nil`."
  def model(project_path), do: Map.get(load(project_path), "model")

  @doc "Persists the chosen model id."
  def put_model(project_path, model_id) when is_binary(model_id),
    do: save(project_path, Map.put(load(project_path), "model", model_id))

  @doc "The persisted budget cap as a `Decimal`, or `nil` if never confirmed."
  def budget_usd(project_path), do: decimal(Map.get(load(project_path), "budget_usd"))

  @doc """
  Persists the confirmed mission budget cap, enforcing that a project
  cannot raise a user-level cap (see moduledoc). Returns `:ok` or
  `{:error, :exceeds_user_cap}` — callers that only ever offered fixed
  options below any realistic user cap (`Sprat.Mission`'s $5/$15 confirm)
  can reasonably ignore the error; the Settings surface, where a user
  types an arbitrary amount, must not.
  """
  def put_budget_usd(project_path, %Decimal{} = cap) do
    case enforce_project_budget(cap, budget_usd_user()) do
      {:ok, cap} ->
        save(project_path, Map.put(load(project_path), "budget_usd", Decimal.to_string(cap)))
        :ok

      {:error, _} = error ->
        error
    end
  end

  @doc "Pure write-path guard, unit-testable with no disk I/O: `cap` may narrow `user_cap` but never exceed it. `user_cap: nil` means no user ceiling is set."
  def enforce_project_budget(%Decimal{} = cap, nil), do: {:ok, cap}

  def enforce_project_budget(%Decimal{} = cap, %Decimal{} = user_cap) do
    if Decimal.compare(cap, user_cap) == :gt,
      do: {:error, :exceeds_user_cap},
      else: {:ok, cap}
  end

  @doc "Warn-percent, permission-mode default, research-depth default and color-mode overrides — project scope, each falling back to the shipped default (see `effective/1` for full precedence)."
  def warn_percent(project_path),
    do: Map.get(load(project_path), "warn_percent", @default_warn_percent)

  def put_warn_percent(project_path, n) when is_integer(n) and n > 0 and n <= 100,
    do: save(project_path, Map.put(load(project_path), "warn_percent", n))

  def permission_mode(project_path),
    do: Map.get(load(project_path), "permission_mode", @default_permission_mode)

  def put_permission_mode(project_path, mode) when mode in ~w(normal auto plan),
    do: save(project_path, Map.put(load(project_path), "permission_mode", mode))

  def research_depth(project_path),
    do: Map.get(load(project_path), "research_depth", @default_research_depth)

  def put_research_depth(project_path, depth) when depth in ~w(quick standard deep),
    do: save(project_path, Map.put(load(project_path), "research_depth", depth))

  @doc "`\"color\"`, `\"ascii\"` or `\"auto\"` (auto = defer to `NO_COLOR`/`SPRAT_ASCII`/locale detection)."
  def color_mode(project_path),
    do: Map.get(load(project_path), "color_mode", @default_color_mode)

  @doc "The `web_search` backend (`\"openai\"` — only one implemented; see docs/design/web-search-options.md §7)."
  def search_provider(project_path),
    do: Map.get(load(project_path), "search_provider", @default_search_provider)

  def put_search_provider(project_path, provider) when is_binary(provider),
    do: save(project_path, Map.put(load(project_path), "search_provider", provider))

  @doc "The model pinned for the `web_search` sub-call — deliberately separate from the researcher's own model (docs/design/web-search-options.md §9 open question #3)."
  def search_model(project_path),
    do: Map.get(load(project_path), "search_model", @default_search_model)

  def put_search_model(project_path, model_id) when is_binary(model_id),
    do: save(project_path, Map.put(load(project_path), "search_model", model_id))

  def put_color_mode(project_path, mode) when mode in ~w(color ascii auto),
    do: save(project_path, Map.put(load(project_path), "color_mode", mode))

  @doc "Terminal bell on pause/mission-finish (`Sprat.Notify`) — on by default."
  def notify_bell(project_path), do: Map.get(load(project_path), "notify_bell", true)

  def put_notify_bell(project_path, on?) when is_boolean(on?),
    do: save(project_path, Map.put(load(project_path), "notify_bell", on?))

  @doc "OS desktop notification on pause/mission-finish (`Sprat.Notify`) — on by default."
  def notify_desktop(project_path), do: Map.get(load(project_path), "notify_desktop", true)

  def put_notify_desktop(project_path, on?) when is_boolean(on?),
    do: save(project_path, Map.put(load(project_path), "notify_desktop", on?))

  @doc """
  Generic project-scope setter used by the Settings zone's editor so it
  doesn't need a `case` per field. Rejects any key outside the known
  schema (`@project_keys`) — nothing here can ever accept a credential
  key, because none exists in the schema (see moduledoc).
  """
  def put_project(project_path, key, value) when key in @project_keys do
    case key do
      "model" -> put_model(project_path, value)
      "budget_usd" -> put_budget_usd(project_path, value)
      "warn_percent" -> put_warn_percent(project_path, value)
      "permission_mode" -> put_permission_mode(project_path, value)
      "research_depth" -> put_research_depth(project_path, value)
      "color_mode" -> put_color_mode(project_path, value)
      "search_provider" -> put_search_provider(project_path, value)
      "search_model" -> put_search_model(project_path, value)
      "notify_bell" -> put_notify_bell(project_path, value)
      "notify_desktop" -> put_notify_desktop(project_path, value)
    end
  end

  def put_project(_project_path, key, _value), do: reject_credential_key!(key)

  defp reject_credential_key!(key),
    do: {:error, {:unknown_or_forbidden_key, key}}

  # -- user scope ------------------------------------------------------------

  @doc "The user config file path (`~/.config/sprat/config.json`, or `:sprat, :user_config_dir` app env for tests)."
  def user_path do
    dir =
      Application.get_env(:sprat, :user_config_dir) ||
        Path.join(System.user_home!(), ".config/sprat")

    Path.join(dir, @filename)
  end

  @doc "Loads the user config as a string-keyed map. `%{}` if there is none yet."
  def load_user, do: read(user_path())

  def model_user, do: Map.get(load_user(), "model")
  def budget_usd_user, do: decimal(Map.get(load_user(), "budget_usd"))
  def warn_percent_user, do: Map.get(load_user(), "warn_percent")
  def permission_mode_user, do: Map.get(load_user(), "permission_mode")
  def research_depth_user, do: Map.get(load_user(), "research_depth")
  def color_mode_user, do: Map.get(load_user(), "color_mode")

  @doc "Persists a user-scope setting. There is deliberately no `put_user(:credential_source, ...)` — see moduledoc."
  def put_user(key, value) when key in @project_keys do
    data = Map.put(load_user(), key, encode_value(value))
    save_user(data)
  end

  def put_user(key, _value), do: reject_credential_key!(key)

  defp encode_value(%Decimal{} = d), do: Decimal.to_string(d)
  defp encode_value(v), do: v

  defp save_user(data) do
    dir = Path.dirname(user_path())
    File.mkdir_p!(dir)
    File.write!(user_path(), JSON.encode!(data))
    :ok
  end

  # -- effective values, with source (docs/spec-v1.md §13) -------------------

  @doc """
  The Settings surface's effective-value table for `project_path`: one
  entry per editable setting plus the read-only data directory, each
  `%{key:, label:, value:, source:, note:}`. `source` is `:user`,
  `:project`, `:env` (color only) or `:default`. `value` is `nil` where
  nothing has ever set it (model not picked yet, budget not confirmed) —
  `note` carries the same honest language `sprat doctor` already uses
  rather than a fabricated default.
  """
  def effective(project_path) do
    user = load_user()
    project = load(project_path)

    [
      model_entry(user, project),
      budget_entry(user, project),
      simple_entry("warn_percent", "Warn percentage", user, project, @default_warn_percent),
      simple_entry(
        "permission_mode",
        "Permission mode default",
        user,
        project,
        @default_permission_mode
      ),
      simple_entry(
        "research_depth",
        "Research depth default",
        user,
        project,
        @default_research_depth
      ),
      color_entry(user, project),
      simple_entry("search_provider", "Search backend", user, project, @default_search_provider),
      simple_entry("search_model", "Search model", user, project, @default_search_model),
      simple_entry("notify_bell", "Terminal bell on pause/finish", user, project, true),
      simple_entry("notify_desktop", "Desktop notification on pause/finish", user, project, true),
      %{
        key: "data_dir",
        label: "Data directory",
        value: Sprat.Store.Paths.data_dir(),
        source: :computed,
        note: "read-only — see docs/spec-v1.md §13 storage layout"
      }
    ]
  end

  defp model_entry(user, project) do
    case pick(user, project, "model") do
      {nil, :default} ->
        %{
          key: "model",
          label: "Model",
          value: nil,
          source: :default,
          note: "not picked yet — first mission (or /model) picks one"
        }

      {value, source} ->
        %{key: "model", label: "Model", value: value, source: source, note: nil}
    end
  end

  defp budget_entry(user, project) do
    case pick(user, project, "budget_usd") do
      {nil, :default} ->
        %{
          key: "budget_usd",
          label: "Budget cap",
          value: nil,
          source: :default,
          note: "not confirmed yet — first mission asks"
        }

      {value, source} ->
        %{
          key: "budget_usd",
          label: "Budget cap",
          value: decimal(value),
          source: source,
          note: nil
        }
    end
  end

  defp simple_entry(key, label, user, project, default) do
    {value, source} = pick(user, project, key, default)
    %{key: key, label: label, value: value, source: source, note: nil}
  end

  # color_mode: env (NO_COLOR/SPRAT_ASCII) beats project beats user beats
  # the shipped default — see moduledoc for why this one key differs.
  defp color_entry(user, project) do
    cond do
      System.get_env("NO_COLOR") ->
        %{
          key: "color_mode",
          label: "Colour / ASCII",
          value: "ascii-or-plain (NO_COLOR set)",
          source: :env,
          note: "NO_COLOR environment variable overrides everything"
        }

      System.get_env("SPRAT_ASCII") == "1" ->
        %{
          key: "color_mode",
          label: "Colour / ASCII",
          value: "ascii",
          source: :env,
          note: "SPRAT_ASCII=1 overrides everything"
        }

      true ->
        simple_entry("color_mode", "Colour / ASCII", user, project, @default_color_mode)
    end
  end

  defp pick(user, project, key, default \\ nil) do
    cond do
      Map.has_key?(project, key) -> {Map.get(project, key), :project}
      Map.has_key?(user, key) -> {Map.get(user, key), :user}
      true -> {default, :default}
    end
  end

  # -- shared --------------------------------------------------------------

  defp read(nil), do: %{}

  defp read(file_path) do
    case File.read(file_path) do
      {:ok, content} -> JSON.decode!(content)
      {:error, _} -> %{}
    end
  rescue
    _ -> %{}
  end

  defp decimal(nil), do: nil
  defp decimal(%Decimal{} = d), do: d
  defp decimal(value), do: Decimal.new(value)

  defp save(nil, _data), do: :ok

  defp save(project_path, data) do
    dir = Path.join(project_path, @dir)
    File.mkdir_p!(dir)
    File.write!(path(project_path), JSON.encode!(data))
    :ok
  end
end
