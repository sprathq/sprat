defmodule Sprat.ConfigTest do
  use ExUnit.Case, async: false

  alias Sprat.Config

  setup do
    project_dir =
      Path.join(System.tmp_dir!(), "sprat-config-project-#{System.unique_integer([:positive])}")

    user_dir =
      Path.join(System.tmp_dir!(), "sprat-config-user-#{System.unique_integer([:positive])}")

    File.mkdir_p!(project_dir)
    File.mkdir_p!(user_dir)
    Application.put_env(:sprat, :user_config_dir, user_dir)

    on_exit(fn ->
      Application.delete_env(:sprat, :user_config_dir)
      File.rm_rf(project_dir)
      File.rm_rf(user_dir)
    end)

    {:ok, project: project_dir}
  end

  describe "effective/1" do
    test "reports :default with an honest note when nothing was ever set", %{project: project} do
      entries = Config.effective(project)
      model = Enum.find(entries, &(&1.key == "model"))
      budget = Enum.find(entries, &(&1.key == "budget_usd"))

      assert model.value == nil
      assert model.source == :default
      assert model.note =~ "not picked yet"

      assert budget.value == nil
      assert budget.source == :default
      assert budget.note =~ "not confirmed yet"
    end

    test "lists notify_bell and notify_desktop, on by default", %{project: project} do
      entries = Config.effective(project)
      bell = Enum.find(entries, &(&1.key == "notify_bell"))
      desktop = Enum.find(entries, &(&1.key == "notify_desktop"))

      assert bell.value == true
      assert bell.source == :default
      assert desktop.value == true
      assert desktop.source == :default
    end

    test "user scope is reported when project has nothing set", %{project: project} do
      Config.put_user("warn_percent", 90)
      entry = Config.effective(project) |> Enum.find(&(&1.key == "warn_percent"))
      assert entry.value == 90
      assert entry.source == :user
    end

    test "project scope overrides user scope", %{project: project} do
      Config.put_user("research_depth", "deep")
      Config.put_research_depth(project, "quick")

      entry = Config.effective(project) |> Enum.find(&(&1.key == "research_depth"))
      assert entry.value == "quick"
      assert entry.source == :project
    end

    test "falls back to the shipped default when neither scope sets it", %{project: project} do
      entry = Config.effective(project) |> Enum.find(&(&1.key == "permission_mode"))
      assert entry.value == "normal"
      assert entry.source == :default
    end

    test "data directory is always reported read-only, computed", %{project: project} do
      entry = Config.effective(project) |> Enum.find(&(&1.key == "data_dir"))
      assert entry.source == :computed
      assert is_binary(entry.value)
    end

    test "NO_COLOR overrides project/user color_mode as :env", %{project: project} do
      Config.put_color_mode(project, "color")
      System.put_env("NO_COLOR", "1")

      entry = Config.effective(project) |> Enum.find(&(&1.key == "color_mode"))
      assert entry.source == :env
    after
      System.delete_env("NO_COLOR")
    end
  end

  describe "enforce_project_budget/2 (pure write-path guard)" do
    test "no user cap set: anything is allowed" do
      assert Config.enforce_project_budget(Decimal.new("999"), nil) == {:ok, Decimal.new("999")}
    end

    test "project cap below the user cap is allowed" do
      assert Config.enforce_project_budget(Decimal.new("5"), Decimal.new("10")) ==
               {:ok, Decimal.new("5")}
    end

    test "project cap equal to the user cap is allowed" do
      assert Config.enforce_project_budget(Decimal.new("10"), Decimal.new("10")) ==
               {:ok, Decimal.new("10")}
    end

    test "project cap above the user cap is rejected" do
      assert Config.enforce_project_budget(Decimal.new("11"), Decimal.new("10")) ==
               {:error, :exceeds_user_cap}
    end
  end

  describe "put_budget_usd/2 (the real write path)" do
    test "persists when there is no user cap", %{project: project} do
      assert :ok = Config.put_budget_usd(project, Decimal.new("20"))
      assert Decimal.equal?(Config.budget_usd(project), Decimal.new("20"))
    end

    test "refuses to persist a project cap above the user cap, and does not write it", %{
      project: project
    } do
      Config.put_user("budget_usd", Decimal.new("5"))

      assert {:error, :exceeds_user_cap} = Config.put_budget_usd(project, Decimal.new("50"))
      assert Config.budget_usd(project) == nil
    end

    test "allows narrowing the user cap", %{project: project} do
      Config.put_user("budget_usd", Decimal.new("50"))
      assert :ok = Config.put_budget_usd(project, Decimal.new("5"))
      assert Decimal.equal?(Config.budget_usd(project), Decimal.new("5"))
    end
  end

  describe "put_project/3" do
    test "there is no credential-source key to set — put_project rejects any unknown key", %{
      project: project
    } do
      assert {:error, {:unknown_or_forbidden_key, "credential_source"}} =
               Config.put_project(project, "credential_source", "somewhere else")

      assert {:error, {:unknown_or_forbidden_key, "api_key"}} =
               Config.put_project(project, "api_key", "sk-fake")
    end

    test "dispatches known keys to their typed setters", %{project: project} do
      assert :ok = Config.put_project(project, "warn_percent", 60)
      assert Config.warn_percent(project) == 60
    end

    # Seam test: the Settings zone editor (Sprat.Session.Commands) writes
    # every editable field through this one generic dispatcher rather than
    # calling `put_search_provider/2`/`put_search_model/2` directly — every
    # key in `@project_keys` must have a matching `case` clause here, or
    # editing that field from the UI raises a CaseClauseError instead of
    # saving. This would fail if either clause were removed again, even
    # though `put_search_provider/2`/`put_search_model/2` themselves stay
    # correct in isolation.
    test "dispatches search_provider and search_model, the two fields the UI can also set", %{
      project: project
    } do
      assert :ok = Config.put_project(project, "search_provider", "openai")
      assert Config.search_provider(project) == "openai"

      assert :ok = Config.put_project(project, "search_model", "gpt-5.6-luna")
      assert Config.search_model(project) == "gpt-5.6-luna"
    end

    test "dispatches notify_bell and notify_desktop, on by default and switchable", %{
      project: project
    } do
      assert Config.notify_bell(project) == true
      assert Config.notify_desktop(project) == true

      assert :ok = Config.put_project(project, "notify_bell", false)
      assert Config.notify_bell(project) == false

      assert :ok = Config.put_project(project, "notify_desktop", false)
      assert Config.notify_desktop(project) == false
    end
  end

  describe "put_user/2" do
    test "there is no credential-source key at user scope either" do
      assert {:error, {:unknown_or_forbidden_key, "credential_source"}} =
               Config.put_user("credential_source", "keychain")
    end
  end
end
