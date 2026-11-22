defmodule Sprat.Terminal.Animate do
  @moduledoc """
  Frame clock and easing (`docs/design/tui-zones.md` "Animation"): spinners
  tick at 10fps, repaint coalescing caps at 30fps, and every animation is a
  pure function of `(state, frame)` — `Terminal.Zone.render/4`'s last
  argument is exactly this module's frame counter, so tests assert frames,
  never sleeps.

  `Terminal.ZonedRenderer` is the only place that turns `spinner_interval_ms/0`
  into an actual `:timer` — this module never starts one itself. The hard
  rule ("all timers stop when nothing is running, under `--plain`,
  `NO_COLOR`, a non-TTY, or below 80x24") is `enabled?/1`: the renderer
  calls it before arming the spinner timer and again on every resize/mode
  change, and cancels the timer the moment it goes false or `running?`
  drops to false — see `ZonedRenderer`'s `maybe_arm_animation/1`.
  """

  alias Sprat.Terminal.Glyphs

  defstruct frame: 0, running?: false

  @type t :: %__MODULE__{frame: non_neg_integer(), running?: boolean()}

  @spinner_fps 10
  @repaint_fps_cap 30
  @spinner_frames ~w(⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏)
  @ascii_spinner_frames ~w(| / - \\)

  def new, do: %__MODULE__{}

  def spinner_interval_ms, do: div(1000, @spinner_fps)
  def repaint_interval_ms, do: div(1000, @repaint_fps_cap)

  @doc "Marks the clock running (a spinner/stream/pulse is active); resets nothing."
  def start(%__MODULE__{} = state), do: %{state | running?: true}

  @doc "Marks the clock idle. `frame` is left as-is (harmless: nothing reads it while idle)."
  def stop(%__MODULE__{} = state), do: %{state | running?: false}

  @doc "Advances the frame counter — a no-op while `running?` is false, so a stray tick after stop/1 costs nothing."
  def tick(%__MODULE__{running?: false} = state), do: state
  def tick(%__MODULE__{} = state), do: %{state | frame: state.frame + 1}

  @doc """
  Whether any animation may run at all, given the environment — checked
  before arming any timer. `opts`: `:plain?`, `:tty?` (default true),
  `:size` (`{cols, rows}`, default `{80, 24}`), plus whatever
  `Terminal.Glyphs.color?/1` reads (`:color` or `NO_COLOR`).
  """
  def enabled?(opts \\ []) do
    plain? = Keyword.get(opts, :plain?, false)
    tty? = Keyword.get(opts, :tty?, true)
    {cols, rows} = Keyword.get(opts, :size, {80, 24})
    not plain? and Glyphs.color?(opts) and tty? and cols >= 80 and rows >= 24
  end

  @doc "The spinner glyph for `frame`, ASCII-swapped per `Terminal.Glyphs.ascii?/1`."
  def spinner_frame(frame, opts \\ []) when is_integer(frame) do
    frames = if Glyphs.ascii?(opts), do: @ascii_spinner_frames, else: @spinner_frames
    Enum.at(frames, rem(frame, length(frames)))
  end

  @doc "0.0..1.0 progress of a `duration_ms`-long animation that started at `start_ms`, evaluated at `now_ms`."
  def progress(start_ms, duration_ms, now_ms) when duration_ms > 0 do
    clamp((now_ms - start_ms) / duration_ms)
  end

  def ease_linear(t), do: clamp(t)

  def ease_out(t) do
    t = clamp(t)
    1 - :math.pow(1 - t, 2)
  end

  def ease_in_out(t) do
    t = clamp(t)
    if t < 0.5, do: 2 * t * t, else: 1 - :math.pow(-2 * t + 2, 2) / 2
  end

  defp clamp(t), do: t |> max(0.0) |> min(1.0)
end
