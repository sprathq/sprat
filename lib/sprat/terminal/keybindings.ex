defmodule Sprat.Terminal.Keybindings do
  @moduledoc """
  Global keybinding dispatch (spec §10 "Keybindings" table). Pure reducer:
  given a parsed key event, the current UI context, and the current time, it
  returns the intent that event means — `:interrupt`, `:exit`,
  `{:mode, :cycle}`, `:toggle_verbose`, and so on — or `nil` when the event
  isn't a global shortcut and should fall through to the composer.

  This layer only *names* intents; it never implements what they do — that
  is orchestration (Phase 2+), out of scope here. The caller (the renderer)
  is responsible for acting on the returned intent.
  """

  defstruct last_esc_at: nil, last_ctrl_c_at: nil

  @type t :: %__MODULE__{}
  @type context :: %{composer_empty?: boolean(), menu_open?: boolean()}
  @esc_esc_window_ms 500
  @ctrl_c_exit_window_ms 2_000

  def new, do: %__MODULE__{}

  @doc "now_ms: caller-supplied monotonic clock, so this stays pure and testable."
  @spec dispatch(t(), Sprat.Terminal.Keys.event(), context(), integer()) ::
          {atom() | tuple() | nil, t()}
  def dispatch(%__MODULE__{} = state, event, context, now_ms) do
    case event do
      :esc -> handle_esc(state, context, now_ms)
      :ctrl_c -> handle_ctrl_c(state, context, now_ms)
      :ctrl_d -> if context.composer_empty?, do: {:exit, state}, else: {nil, state}
      :shift_tab -> {{:mode, :cycle}, state}
      {:ctrl, "o"} -> {:toggle_verbose, state}
      {:ctrl, "t"} -> {:toggle_checklist, state}
      {:ctrl, "l"} -> {:redraw, state}
      {:char, "?"} -> if context.composer_empty?, do: {:help, state}, else: {nil, state}
      _ -> {nil, state}
    end
  end

  defp handle_esc(state, context, now_ms) do
    cond do
      context.menu_open? ->
        {:close_menu, %{state | last_esc_at: nil}}

      state.last_esc_at && now_ms - state.last_esc_at < @esc_esc_window_ms ->
        {:edit_earlier_message, %{state | last_esc_at: nil}}

      true ->
        {:interrupt, %{state | last_esc_at: now_ms}}
    end
  end

  defp handle_ctrl_c(%{last_ctrl_c_at: last} = state, %{composer_empty?: true}, now_ms) do
    if last && now_ms - last < @ctrl_c_exit_window_ms do
      {:exit, %{state | last_ctrl_c_at: nil}}
    else
      {:interrupt, %{state | last_ctrl_c_at: now_ms}}
    end
  end

  defp handle_ctrl_c(state, %{composer_empty?: false}, _now_ms) do
    {:clear_composer, %{state | last_ctrl_c_at: nil}}
  end
end
