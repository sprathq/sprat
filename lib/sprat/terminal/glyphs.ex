defmodule Sprat.Terminal.Glyphs do
  @moduledoc """
  Shared glyph/color-mode detection for the live-region views and transcript
  formatters: `NO_COLOR` disables ANSI, `SPRAT_ASCII=1` (or a non-UTF-8
  locale) swaps Unicode box/status glyphs for ASCII ones.
  """

  @doc "true unless NO_COLOR is set (any value counts, per no-color.org)."
  def color?(opts \\ []), do: Keyword.get(opts, :color, is_nil(System.get_env("NO_COLOR")))

  @doc "true when ASCII glyphs should be used in place of Unicode ones."
  def ascii?(opts \\ []) do
    Keyword.get(opts, :ascii, System.get_env("SPRAT_ASCII") == "1" or not utf8_locale?())
  end

  @doc "Checklist status marker: done/active/pending."
  def checklist_marker(:done, false), do: "☒"
  def checklist_marker(:active, false), do: "◼"
  def checklist_marker(:pending, false), do: "☐"
  def checklist_marker(:done, true), do: "[x]"
  def checklist_marker(:active, true), do: "[>]"
  def checklist_marker(:pending, true), do: "[ ]"

  @doc "Bullet used in unordered lists / prose."
  def bullet(true), do: "*"
  def bullet(false), do: "•"

  @doc "Transcript block markers."
  def block_marker(true), do: "*"
  def block_marker(false), do: "⏺"

  def result_marker(true), do: "|_"
  def result_marker(false), do: "⎿"

  def selected_marker(true), do: ">"
  def selected_marker(false), do: "❯"

  @doc """
  Focused-zone marker (`docs/design/tui-zones.md` "Focus and keys": "the
  focused one holds focus; it shows a bright border and title" — a
  structural marker on top of that, so focus survives `NO_COLOR` too,
  since colour never carries meaning alone, spec §10 accessibility).
  """
  def focus_marker(true), do: ">"
  def focus_marker(false), do: "▸"

  @doc "Zone frame corner/edge glyphs: `{top_left, top_right, bottom_left, bottom_right, horizontal, vertical}`."
  def box_glyphs(true), do: {"+", "+", "+", "+", "-", "|"}
  def box_glyphs(false), do: {"╭", "╮", "╰", "╯", "─", "│"}

  @doc "Inspector tab-bar bracket glyphs: `{left, right}`."
  def tab_arrows(true), do: {"<", ">"}
  def tab_arrows(false), do: {"‹", "›"}

  @doc "Truncation suffix, for `Terminal.Width.truncate/3`'s `suffix` argument."
  def ellipsis(true), do: "..."
  def ellipsis(false), do: "…"

  @doc """
  Run status marker: glyph and word together, never colour alone
  (docs/spec-v2.md §11 Runs tab — "a failed run must be unmistakable ...
  glyph and word, not colour alone"). `exit_code` is `nil` for a run
  whose process never produced one — today that only happens when
  `Agent.Tools.Shell` kills it on timeout (a run still genuinely in
  flight is never written to `Store.Runs` at all: `record_run/8` only
  runs once the process has already finished one way or another), so
  `nil` reads as "timed out" rather than a fabricated "running" — spec
  §11's "nothing rendered as passing that has no exit code."
  """
  def run_status(nil, true), do: {"(t)", "timed out"}
  def run_status(nil, false), do: {"⏲", "timed out"}
  def run_status(0, true), do: {"[x]", "passed"}
  def run_status(0, false), do: {"✓", "passed"}
  def run_status(_code, true), do: {"(!)", "failed"}
  def run_status(_code, false), do: {"!", "failed"}

  defp utf8_locale? do
    locale =
      (System.get_env("LC_ALL") || System.get_env("LC_CTYPE") || System.get_env("LANG") || "")
      |> String.downcase()

    String.contains?(locale, "utf-8") or String.contains?(locale, "utf8")
  end
end
