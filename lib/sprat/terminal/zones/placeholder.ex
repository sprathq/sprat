defmodule Sprat.Terminal.Zones.Placeholder do
  @moduledoc """
  A trivial `Terminal.Zone`: a title and a scrollable text buffer, nothing
  else. Ships so the zoned core (`Screen`, `Layout`, `Focus`, `Scrollback`,
  `Theme`, `Animate`) is demonstrable — `mix sprat.demo --zones` — before
  the five real content zones (stage 2) exist. `Terminal.ZonedRenderer`
  uses one instance per non-Composer zone slot by default; a zone's *slot*
  (`:mission`, `:agents`, ...) is the map key in `ZonedRenderer`'s zone
  table, passed in at `init/1` as `:name` — this module's `id/0` is a
  generic `:placeholder`, not the slot, since one module fills several
  slots.

  Also doubles as the pattern stage 2 zones follow: state holds a
  `Terminal.Scrollback`, `render/4` reads it via `viewport/2` and turns
  lines into cells with `Screen.text_cells/3`, and `handle_key/2` maps
  scroll keys onto `Scrollback` movement — copy this file's shape for
  Mission/Agents/Inspector/Detail.
  """

  @behaviour Sprat.Terminal.Zone

  alias Sprat.Terminal.{Scrollback, Screen}

  defstruct [:name, :scrollback]

  @impl true
  def id, do: :placeholder

  @impl true
  def title(%__MODULE__{name: name}), do: name

  @impl true
  def min_size, do: {12, 3}

  @impl true
  def overlay_capable?, do: true

  @impl true
  def init(opts) do
    lines = Keyword.get(opts, :lines, lorem())

    %__MODULE__{
      name: Keyword.fetch!(opts, :name),
      scrollback: Scrollback.new() |> Scrollback.append(lines)
    }
  end

  @doc "Replaces the buffer content wholesale (used by `ZonedRenderer` to project `set_live/2` view models onto Mission in stage 1)."
  def set_text(%__MODULE__{} = state, text) when is_binary(text) do
    %{state | scrollback: Scrollback.new() |> Scrollback.append(String.split(text, "\n"))}
  end

  @impl true
  def render(%__MODULE__{} = state, rect, focused?, _frame) do
    style =
      if focused?,
        do: %{fg: :cyan, bg: nil, attrs: [:bright]},
        else: %{fg: nil, bg: nil, attrs: []}

    header = Screen.text_cells(" #{state.name} ", rect.w, style)

    body_style = Screen.default_style()

    body =
      state.scrollback
      |> Scrollback.viewport(max(rect.h - 1, 0))
      |> Enum.map(&Screen.text_cells(&1, rect.w, body_style))

    [header | body]
  end

  @impl true
  def handle_key(%__MODULE__{} = state, event) do
    case event do
      :up -> {scroll(state, &Scrollback.line_up/1), []}
      :down -> {scroll(state, &Scrollback.line_down/1), []}
      :page_up -> {scroll(state, &Scrollback.page_up(&1, 10)), []}
      :page_down -> {scroll(state, &Scrollback.page_down(&1, 10)), []}
      :top -> {scroll(state, &Scrollback.top/1), []}
      :bottom -> {scroll(state, &Scrollback.bottom/1), []}
      _other -> {state, []}
    end
  end

  defp scroll(state, fun), do: %{state | scrollback: fun.(state.scrollback)}

  defp lorem do
    [
      "Lorem ipsum dolor sit amet, consectetur adipiscing elit.",
      "Sed do eiusmod tempor incididunt ut labore et dolore magna aliqua.",
      "Ut enim ad minim veniam, quis nostrud exercitation ullamco.",
      "Duis aute irure dolor in reprehenderit in voluptate velit esse.",
      "Excepteur sint occaecat cupidatat non proident, sunt in culpa.",
      "Qui officia deserunt mollit anim id est laborum."
    ]
    |> List.duplicate(4)
    |> List.flatten()
    |> Enum.with_index(1)
    |> Enum.map(fn {line, i} -> "#{i}. #{line}" end)
  end
end
