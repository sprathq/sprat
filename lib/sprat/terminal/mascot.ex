defmodule Sprat.Terminal.Mascot do
  @moduledoc """
  Sprat's mascot: a little fish `><>` that lives at the right end of the
  footer. Pure — `render/4` maps state and the animation frame to the text
  for a track of `width` columns, so it is tested by asserting frames, never
  by sleeping (`docs/design/tui-zones.md`, Animation).

  States, in the order `state_of/1` resolves them:

    * `:waiting_input` — a question or permission prompt is up. The fish
      turns to face the user and blinks: `<><` / `<•<`, about twice a
      second. It stays put, so motion means "look here", not "busy".
    * `:working` — something is running. The fish swims the track, bouncing
      at each end, facing the way it swims: `><>` right, `<><` left.
    * `:idle` — nothing running. A still `><>`, no timers, no motion
      (the design's hard rule: idle Sprat animates nothing).

  ASCII mode keeps the fish (it is already ASCII) but swaps the blink dot
  for `o`, so nothing depends on a Unicode bullet rendering.
  """

  @right "><>"
  @left "<><"
  @body_width 3

  # 10 fps clock: swim a column every 2 frames, blink every 5.
  @frames_per_swim 2
  @frames_per_blink 5

  @type state :: :idle | :working | :waiting_input

  @doc """
  Picks the mascot state from what the renderer knows: a pending prompt
  wins over activity, and no animation clock means idle.
  """
  @spec state_of(%{optional(:permission) => term(), optional(:animating?) => boolean()}) ::
          state()
  def state_of(%{permission: permission}) when not is_nil(permission), do: :waiting_input
  def state_of(%{animating?: true}), do: :working
  def state_of(_), do: :idle

  @doc """
  The mascot's row of `width` columns for `frame`. `width` is the space the
  footer can spare; under `#{@body_width}` columns the mascot is dropped
  entirely (returns `""`), because a clipped fish is just noise.
  """
  @spec render(state(), non_neg_integer(), non_neg_integer(), keyword()) :: String.t()
  def render(state, frame, width, opts \\ [])

  def render(_state, _frame, width, _opts) when width < @body_width, do: ""

  def render(:idle, _frame, width, _opts), do: pad(@right, 0, width)

  def render(:waiting_input, frame, width, opts) do
    body = if blink?(frame), do: blinking(opts), else: @left
    pad(body, 0, width)
  end

  def render(:working, frame, width, _opts) do
    span = width - @body_width

    if span <= 0 do
      pad(@right, 0, width)
    else
      {offset, facing} = swim(frame, span)
      pad(facing, offset, width)
    end
  end

  # Bounce along the track: 0..span then back, so the fish turns around
  # rather than teleporting to the start.
  defp swim(frame, span) do
    step = div(frame, @frames_per_swim)
    cycle = rem(step, span * 2)

    if cycle <= span, do: {cycle, @right}, else: {span * 2 - cycle, @left}
  end

  defp blink?(frame), do: rem(div(frame, @frames_per_blink), 2) == 1

  defp blinking(opts) do
    if Keyword.get(opts, :ascii?, false), do: "<o<", else: "<•<"
  end

  defp pad(body, offset, width) do
    String.duplicate(" ", offset) <> body <> String.duplicate(" ", width - offset - @body_width)
  end
end
