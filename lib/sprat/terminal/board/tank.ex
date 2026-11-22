defmodule Sprat.Terminal.Board.Tank do
  @moduledoc """
  The processes screen's tank: every live Claude session as a fish. Sprat
  is a fish too, so its sessions swim.

  How a fish swims says how its session is doing: a working one is big and
  quick; an idle one small and slow; one that needs you hangs at the
  surface; one that finished its turn rests on the sand. When a session's
  watcher has just read something new, bubbles rise from its fish. Each fish
  carries its session's name behind it.

  Pure: `render/2` turns a spec and a size into rows of styled segments.
  Positions come from the frame alone, so reduced motion holds them still.
  """

  alias Sprat.Terminal.Board.Style

  @typedoc "`fish`: `[%{name, state, fresh?}]`, in a fixed order."
  @type spec :: %{fish: list()}

  @doc "Rows of `{text, style}` segments, `w` columns by `h` rows."
  def render(spec, %{width: w, height: h} = ctx) do
    frame = if ctx.reduced_motion?, do: 0, else: ctx.frame
    tank_h = max(h - 1, 6)
    geo = %{w: w, h: tank_h, floor: tank_h - 1}

    canvas =
      %{}
      |> surface(geo, frame, ctx)
      |> floor(geo, ctx)
      |> weed(geo, frame, ctx)
      |> fishes(spec.fish, geo, frame, ctx)

    rows(canvas, geo, ctx) ++ [legend(ctx, w)]
  end

  # -- the water -------------------------------------------------------------------

  defp surface(canvas, geo, frame, ctx) do
    wave = if ctx.ascii?, do: "~", else: "～"
    step = if ctx.ascii?, do: 1, else: 2

    Enum.reduce(0..(geo.w - 1)//step, canvas, fn x, acc ->
      if rem(x + div(frame, 3) * step, 3 * step) < 2 * step,
        do: put(acc, {x, 0}, wave, :rule, ctx),
        else: acc
    end)
  end

  @sand ~w(▁ ▂ ▁ ▁ ▃ ▁ ▂ ▁)

  defp floor(canvas, geo, ctx) do
    Enum.reduce(0..(geo.w - 1), canvas, fn x, acc ->
      g = if ctx.ascii?, do: "_", else: Enum.at(@sand, rem(x * 7 + div(x, 3), length(@sand)))
      Map.put(acc, {x, geo.floor}, {g, :rule})
    end)
  end

  # A few strands of weed on the sand, swaying.
  defp weed(canvas, geo, frame, _ctx) do
    for at <- [0.07, 0.38, 0.71, 0.93],
        x = round(geo.w * at),
        tall = 2 + rem(x, 3),
        r <- 1..tall,
        y = geo.floor - r,
        y > 1,
        reduce: canvas do
      acc ->
        g = if rem(r + div(frame, 7), 2) == 0, do: "(", else: ")"
        Map.put(acc, {x, y}, {g, :progress})
    end
  end

  # -- the fish --------------------------------------------------------------------

  # Rows by state: the ones that need you at the surface, the finished on
  # the sand, the rest between, working above idle. A zone with more fish
  # than rows shares them.
  defp rows_for(fish, geo) do
    middle = Enum.to_list(3..max(geo.floor - 2, 3))
    top = [1, 2]
    bottom = [geo.floor - 1]

    {up, rest} = Enum.split_with(fish, &(&1.state in [:waiting, :stuck]))
    {down, mid} = Enum.split_with(rest, &(&1.state == :finished))
    {busy, idle} = Enum.split_with(mid, &(&1.state == :busy))

    # Spread through the zone's rows, rather than packed at its top.
    place = fn list, rows ->
      n = length(list)
      r = length(rows)

      list
      |> Enum.with_index()
      |> Enum.map(fn {f, i} ->
        at = if n <= r, do: round(i * (r - 1) / max(n - 1, 1)), else: rem(i, r)
        {f, Enum.at(rows, at)}
      end)
    end

    place.(up, top) ++ place.(down, bottom) ++ place.(busy ++ idle, middle)
  end

  defp fishes(canvas, fish, geo, frame, ctx) do
    fish
    |> rows_for(geo)
    |> Enum.reduce(canvas, fn {f, y}, acc -> one_fish(acc, f, y, geo, frame, ctx) end)
  end

  defp one_fish(canvas, f, y, geo, frame, ctx) do
    label =
      case f.state do
        :waiting -> f.name <> " · needs you"
        :stuck -> f.name <> " · stuck"
        :finished -> f.name <> " · finished"
        _ -> f.name
      end

    label = Style.truncate(label, 28, ctx)
    {right, left} = body(f.state, ctx)
    len = Style.w(right, ctx) + 1 + Style.w(label, ctx)
    range = max(geo.w - len - 2, 1)
    phase = :erlang.phash2(f.name, 10_000)

    {x, facing} = swim(phase, speed(f.state), frame, range)
    x = x + 1

    {fish_x, label_x, mouth} =
      case facing do
        :right -> {x + Style.w(label, ctx) + 1, x, x + len}
        :left -> {x, x + Style.w(left, ctx) + 1, x - 1}
      end

    style = fish_style(f.state)

    canvas
    |> bubbles(f, mouth, y, frame, ctx)
    |> text({label_x, y}, label, label_style(f.state))
    |> text({fish_x, y}, if(facing == :right, do: right, else: left), style)
  end

  defp body(:busy, ctx), do: shape("><(((°>", "<°)))><", ctx)
  defp body(:waiting, ctx), do: shape("><((°>", "<°))><", ctx)
  defp body(:stuck, ctx), do: shape("><((×>", "<×))><", ctx)
  defp body(_, ctx), do: shape("><>", "<><", ctx)

  defp shape(r, l, %{ascii?: true}),
    do:
      {r |> String.replace("°", "o") |> String.replace("×", "x"),
       l |> String.replace("°", "o") |> String.replace("×", "x")}

  defp shape(r, l, _ctx), do: {r, l}

  # Columns a frame (ten frames a second).
  defp speed(:busy), do: 0.45
  defp speed(:waiting), do: 0.06
  defp speed(:stuck), do: 0.0
  defp speed(:finished), do: 0.0
  defp speed(_), do: 0.08

  # Back and forth across the tank.
  defp swim(phase, speed, frame, range) do
    period = 2 * range
    p = rem(round(phase + speed * frame), period)
    if p < range, do: {p, :right}, else: {period - p, :left}
  end

  defp fish_style(:busy), do: :bright
  defp fish_style(:waiting), do: :you
  defp fish_style(:stuck), do: :stuck
  defp fish_style(:finished), do: :progress
  defp fish_style(_), do: :quiet

  defp label_style(:waiting), do: :you
  defp label_style(:stuck), do: :stuck
  defp label_style(_), do: :quiet

  # Bubbles rise from the mouth of a fish whose session just did something;
  # a finished one, resting, breathes a slow z.
  defp bubbles(canvas, %{fresh?: true}, x, y, frame, ctx) when y > 2 do
    room = min(y - 1, 4)
    shapes = if ctx.ascii?, do: ["o", "o", "."], else: ["°", "o", "∘"]

    Enum.reduce(0..2, canvas, fn k, acc ->
      h = rem(div(frame, 2) + k * 2, room) + 1
      Map.put(acc, {x + rem(k, 2), y - h}, {Enum.at(shapes, min(h - 1, 2)), :quiet})
    end)
  end

  defp bubbles(canvas, %{state: :finished}, x, y, frame, _ctx) when y > 3 do
    h = rem(div(frame, 6), 3) + 1
    Map.put(canvas, {x, y - h}, {"z", :rule})
  end

  defp bubbles(canvas, _f, _x, _y, _frame, _ctx), do: canvas

  # -- out -------------------------------------------------------------------------

  defp put(canvas, cell, g, style, _ctx), do: Map.put(canvas, cell, {g, style})

  defp text(canvas, {x, y}, text, style) do
    text
    |> String.graphemes()
    |> Enum.with_index()
    |> Enum.reduce(canvas, fn {g, i}, acc -> Map.put(acc, {x + i, y}, {g, style}) end)
  end

  # The canvas as rows, runs of one style merged; a double-width glyph takes
  # the cell after it too.
  defp rows(canvas, geo, ctx) do
    for y <- 0..(geo.h - 1) do
      {cells, _skip} =
        Enum.reduce(0..(geo.w - 1), {[], false}, fn x, {acc, skip?} ->
          if skip? do
            {acc, false}
          else
            {g, style} = Map.get(canvas, {x, y}, {" ", :text})
            {[{g, style} | acc], Style.w(g, ctx) > 1}
          end
        end)

      cells
      |> Enum.reverse()
      |> Enum.chunk_by(&elem(&1, 1))
      |> Enum.map(fn run -> {Enum.map_join(run, &elem(&1, 0)), elem(hd(run), 1)} end)
    end
  end

  defp legend(ctx, w) do
    {big, small} = if ctx.ascii?, do: {"><(((o>", "><>"}, else: {"><(((°>", "><>"}
    bubble = if ctx.ascii?, do: "o", else: "°"

    Style.fit_segs(
      [
        {" " <> big, :bright},
        {" working  ", :quiet},
        {small, :quiet},
        {" idle  ", :quiet},
        {"at the surface", :you},
        {": needs you  ", :quiet},
        {"on the sand", :progress},
        {": finished its turn  ", :quiet},
        {bubble, :text},
        {" just did something", :quiet}
      ],
      w,
      ctx
    )
  end
end
