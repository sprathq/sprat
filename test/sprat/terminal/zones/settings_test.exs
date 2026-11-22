defmodule Sprat.Terminal.Zones.SettingsTest do
  use ExUnit.Case, async: true

  alias Sprat.Terminal.Zones.Settings
  import Sprat.Test.CellText, only: [rows_to_text: 1]

  @widths [{60, 20}, {40, 12}, {20, 8}]

  test "render/4 always returns exactly rect.h rows of exactly rect.w cells" do
    state = Settings.init([])

    for {w, h} <- @widths do
      rows = Settings.render(state, %{x: 0, y: 0, w: w, h: h}, true, 0)
      assert length(rows) == h
      assert Enum.all?(rows, &(length(&1) == w))
    end
  end

  test "an unloaded overlay says so honestly, not a fake table" do
    state = Settings.init([])
    text = Settings.render(state, %{x: 0, y: 0, w: 60, h: 15}, true, 0) |> rows_to_text()
    assert text =~ "No settings loaded yet"
  end

  test "shows the effective value and its source for every entry" do
    entries = [
      %{key: "model", label: "Model", value: "gpt-5-nano", source: :project, note: nil},
      %{
        key: "budget_usd",
        label: "Budget cap",
        value: Decimal.new("5.00"),
        source: :user,
        note: nil
      }
    ]

    state = Settings.init([]) |> Settings.handle_view_update(%{entries: entries})
    text = Settings.render(state, %{x: 0, y: 0, w: 60, h: 15}, true, 0) |> rows_to_text()

    assert text =~ "gpt-5-nano"
    assert text =~ "(project)"
    assert text =~ "$5.00"
    assert text =~ "(user)"
  end

  test "never renders the API key itself — only the source and last 4 characters" do
    key_status = %{present: true, source: :env, last4: "wxyz"}
    state = Settings.init([]) |> Settings.handle_view_update(%{key_status: key_status})
    text = Settings.render(state, %{x: 0, y: 0, w: 90, h: 15}, true, 0) |> rows_to_text()

    assert text =~ "…wxyz"
    refute text =~ "sk-"
    # last4 is the *only* fragment of any real key ever exercised here —
    # asserting the surrounding words are present pins the display shape,
    # not a real secret.
    assert text =~ "environment variable"
  end

  test "the data directory row is marked read-only and Enter on it is a no-op" do
    entries = [
      %{key: "data_dir", label: "Data directory", value: "/tmp/x", source: :computed, note: nil}
    ]

    state = Settings.init([]) |> Settings.handle_view_update(%{entries: entries})
    text = Settings.render(state, %{x: 0, y: 0, w: 60, h: 15}, true, 0) |> rows_to_text()
    assert text =~ "[read-only]"

    {_new_state, intents} = Settings.handle_key(state, :enter)
    assert intents == []
  end

  test "Enter on an editable row emits {:settings_edit, key}" do
    entries = [
      %{key: "warn_percent", label: "Warn percentage", value: 80, source: :default, note: nil}
    ]

    state = Settings.init([]) |> Settings.handle_view_update(%{entries: entries})
    {_state, intents} = Settings.handle_key(state, :enter)
    assert intents == [{:settings_edit, "warn_percent"}]
  end
end
