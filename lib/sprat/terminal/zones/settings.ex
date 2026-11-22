defmodule Sprat.Terminal.Zones.Settings do
  @moduledoc """
  The `Alt+s`/`s` Settings overlay (`docs/design/tui-zones.md`-style
  full-screen overlay, same shape as `Zones.Flow`'s `Alt+f`/`f`): effective
  values and where each came from (`Sprat.Config.effective/1`, per
  docs/spec-v1.md §13), plus the API key's source and last 4 characters
  only (`Sprat.Secrets`, never the key itself).

  Purely a renderer of whatever `Terminal.ZonedRenderer` pushes via
  `handle_view_update/2` (`%{entries:, key_status:}`, refreshed by the
  renderer every time the overlay opens — see its moduledoc) — this
  module does no config I/O itself, keeping `render/4` pure like every
  other zone. Editing a row (`Enter`, unless it's read-only) returns the
  `{:settings_edit, key}` intent; `Sprat.Session.Shell` runs the actual
  numbered-prompt editor (mirrors `Sprat.Mission.pick_model/2`'s existing
  pattern) and `Sprat.Config`'s write path enforces that a project can
  never raise a user-level budget cap or touch the credential source.
  """

  @behaviour Sprat.Terminal.Zone

  alias Sprat.Terminal.ZoneFrame

  @read_only ["data_dir"]

  defstruct name: "Settings", entries: [], key_status: nil, selected: 0

  @impl true
  def id, do: :settings

  @impl true
  def title(%__MODULE__{name: name}), do: name

  @impl true
  def min_size, do: {40, 10}

  @impl true
  def overlay_capable?, do: true

  @impl true
  def init(opts), do: %__MODULE__{name: Keyword.get(opts, :name, "Settings")}

  @impl true
  def handle_view_update(%__MODULE__{} = state, view_model) when is_map(view_model) do
    %{
      state
      | entries: Map.get(view_model, :entries, state.entries),
        key_status: Map.get(view_model, :key_status, state.key_status),
        selected: 0
    }
  end

  @impl true
  def render(%__MODULE__{} = state, rect, _focused?, _frame) do
    lines =
      key_lines(state.key_status) ++
        [""] ++
        entry_lines(state) ++
        [""] ++
        ["Enter edit a row (read-only rows say so) · Esc/Alt+s close"]

    ZoneFrame.wrap("Settings — effective values", true, rect, lines)
  end

  defp key_lines(nil),
    do: ["API key: not connected to a session yet — reopen with Alt+s once one is running."]

  defp key_lines(%{present: false}),
    do: ["API key: not set (OPENAI_API_KEY, .env, or the OS credential store)."]

  defp key_lines(%{present: true, source: source, last4: last4}),
    do: ["API key: set, from #{Sprat.Secrets.describe_source(source)} (…#{last4})"]

  defp entry_lines(%__MODULE__{entries: []}),
    do: ["No settings loaded yet — reopen Alt+s once a project session is running."]

  defp entry_lines(state) do
    state.entries
    |> Enum.with_index()
    |> Enum.map(fn {entry, idx} ->
      marker = if idx == state.selected, do: "▸ ", else: "  "
      marker <> entry_line(entry)
    end)
  end

  defp entry_line(entry) do
    label = String.pad_trailing(entry.label, 24)
    value = value_text(entry)
    source = "(#{entry.source})"
    ro = if entry.key in @read_only, do: "  [read-only]", else: ""
    note = if entry.note, do: "  — #{entry.note}", else: ""
    "#{label} #{value}  #{source}#{ro}#{note}"
  end

  defp value_text(%{value: nil}), do: "unset"
  defp value_text(%{key: "budget_usd", value: %Decimal{} = d}), do: "$#{Decimal.round(d, 2)}"
  defp value_text(%{value: value}), do: to_string(value)

  @impl true
  def handle_key(%__MODULE__{} = state, event) do
    n = length(state.entries)

    case event do
      :up -> {%{state | selected: clamp(state.selected - 1, n)}, []}
      :down -> {%{state | selected: clamp(state.selected + 1, n)}, []}
      :enter -> edit_selected(state)
      _other -> {state, []}
    end
  end

  defp edit_selected(%__MODULE__{entries: []} = state), do: {state, []}

  defp edit_selected(state) do
    entry = Enum.at(state.entries, state.selected)

    if entry.key in @read_only do
      {state, []}
    else
      {state, [{:settings_edit, entry.key}]}
    end
  end

  defp clamp(_index, 0), do: 0
  defp clamp(index, count), do: index |> max(0) |> min(count - 1)
end
