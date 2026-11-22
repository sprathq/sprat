defmodule Sprat.Terminal.Theme do
  @moduledoc """
  Role and state palettes (`docs/design/tui-zones.md` "Colour and icons"):
  colour + intensity + glyph + word for every agent role and every agent
  state, built on `Terminal.Glyphs`'s existing `NO_COLOR`/`SPRAT_ASCII`
  detection.

  Colour is never the only signal: `role/2` and `state/2` always return a
  `glyph` and a `word` alongside `color`, and `color` is simply `nil` under
  `NO_COLOR` (or when `color: false` is passed for a test) — every glyph
  and word stays, so the state is still legible. `test/sprat/terminal/theme_test.exs`
  asserts every state is distinguishable by `{glyph, word}` alone.
  """

  alias Sprat.Terminal.Glyphs

  @roles %{
    orchestrator: %{color: :light_black, glyph: "⌁", ascii_glyph: "*", word: "Orchestrator"},
    pm: %{color: :blue, glyph: "◆", ascii_glyph: "o", word: "PM"},
    researcher: %{color: :green, glyph: "◉", ascii_glyph: "o", word: "Researcher"},
    analyst: %{color: :yellow, glyph: "▲", ascii_glyph: "^", word: "Analyst"},
    swe: %{color: :cyan, glyph: "■", ascii_glyph: "#", word: "SWE"}
  }

  @states %{
    idle: %{color: :light_black, intensity: :dim, glyph: "⏸", ascii_glyph: "[-]", word: "idle"},
    receiving: %{
      color: :cyan,
      intensity: :bright_reversed,
      glyph: "✉",
      ascii_glyph: "[>]",
      word: "receiving"
    },
    active: %{
      color: :role,
      intensity: :bright,
      glyph: :spinner,
      ascii_glyph: :spinner,
      word: "active"
    },
    running: %{
      color: :cyan,
      intensity: :bright,
      glyph: :spinner,
      ascii_glyph: :spinner,
      word: "running"
    },
    waiting_on_tool: %{
      color: :role,
      intensity: :normal,
      glyph: "⋯",
      ascii_glyph: "...",
      word: "waiting on a tool"
    },
    waiting_on_user: %{
      color: :cyan,
      intensity: :bright,
      glyph: "?",
      ascii_glyph: "?",
      word: "waiting on you"
    },
    blocked: %{color: :red, intensity: :bright, glyph: "!", ascii_glyph: "(!)", word: "blocked"},
    failed: %{color: :red, intensity: :bright, glyph: "!", ascii_glyph: "(!)", word: "failed"},
    done: %{color: :green, intensity: :normal, glyph: "✓", ascii_glyph: "[x]", word: "done"},
    skipped: %{
      color: :yellow,
      intensity: :dim,
      glyph: "⊘",
      ascii_glyph: "(-)",
      word: "skipped"
    },
    queued: %{color: :light_black, intensity: :dim, glyph: "○", ascii_glyph: "o", word: "queued"},
    paused: %{
      color: :light_black,
      intensity: :dim,
      glyph: "⏸",
      ascii_glyph: "[-]",
      word: "paused"
    }
  }

  @doc "All known role names."
  def roles, do: Map.keys(@roles)

  @doc "All known state names."
  def states, do: Map.keys(@states)

  @doc """
  `%{word:, glyph:, color:}` for a role. `glyph` is already the ASCII
  fallback under `SPRAT_ASCII`/a non-UTF-8 locale; `color` is `nil` when
  `Glyphs.color?/1` is false (`NO_COLOR`, or `color: false` in `opts`).
  """
  def role(name, opts \\ []) when is_map_key(@roles, name) do
    entry = Map.fetch!(@roles, name)
    %{word: entry.word, glyph: pick_glyph(entry, opts), color: maybe_color(entry.color, opts)}
  end

  @doc """
  `%{word:, glyph:, color:, intensity:}` for a state. `glyph` may be the
  atom `:spinner` (the caller resolves the current frame via
  `Terminal.Animate.spinner_frame/2`); `color` may be the atom `:role`,
  meaning "use the card's own role colour" (per the design's state table)
  — resolved by the caller, not here, since this module doesn't know the
  role.
  """
  def state(name, opts \\ []) when is_map_key(@states, name) do
    entry = Map.fetch!(@states, name)

    %{
      word: entry.word,
      glyph: pick_glyph(entry, opts),
      color: maybe_color(entry.color, opts),
      intensity: entry.intensity
    }
  end

  defp pick_glyph(%{glyph: :spinner}, _opts), do: :spinner

  defp pick_glyph(entry, opts) do
    if Glyphs.ascii?(opts), do: entry.ascii_glyph, else: entry.glyph
  end

  defp maybe_color(color, opts), do: if(Glyphs.color?(opts), do: color, else: nil)
end
