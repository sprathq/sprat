defmodule Sprat.Observer.UsageLimit do
  @moduledoc """
  Parses Claude Code's usage-limit messages (spec §7.1, `00-spikes.md` §3):

      You've hit your 5-hour limit · resets 11:50am (Europe/London)
      You've hit your session limit · resets 4pm (Europe/London)
      You've hit your weekly limit · resets Nov 24 at 5pm (Europe/London) · out of usage credits

  optionally followed by ` (error type rate_limit, …)`. A time with no date is
  the next occurrence after `now` in the message's zone; a date with no year
  is the next occurrence too. An unknown zone falls back to UTC and says so
  (`zone_fallback?: true`).
  """

  @type kind :: :five_hour | :session | :weekly
  @type result :: %{
          kind: kind(),
          reset_at: DateTime.t(),
          text: String.t(),
          zone: String.t(),
          zone_fallback?: boolean()
        }

  @months ~w(jan feb mar apr may jun jul aug sep oct nov dec)

  @reset ~r/resets\s+(?:(?<mon>[A-Za-z]{3})[a-z]*\.?\s+(?<day>\d{1,2})(?:,?\s*(?<year>\d{4}))?\s+at\s+)?(?<h>\d{1,2})(?::(?<m>\d{2}))?\s*(?<ampm>am|pm)?\s*\((?<zone>[^)]+)\)/i

  @doc "Parses a limit message; `:error` when it is not one or carries no reset time."
  @spec parse(String.t(), DateTime.t()) :: {:ok, result()} | :error
  def parse(text, %DateTime{} = now) when is_binary(text) do
    with kind when kind != nil <- kind(text),
         %{} = c <- Regex.named_captures(@reset, text),
         {:ok, hour, minute} <- clock(c["h"], c["m"], c["ampm"]) do
      {zone, fallback?} = zone(c["zone"])
      now_local = DateTime.shift_zone!(now, zone)

      reset =
        case c["mon"] do
          "" -> next_time(now, now_local, hour, minute, zone)
          mon -> next_date(now, now_local, mon, c["day"], c["year"], hour, minute, zone)
        end

      case reset do
        {:ok, dt} ->
          {:ok,
           %{
             kind: kind,
             reset_at: DateTime.shift_zone!(dt, "Etc/UTC"),
             text: text,
             zone: zone,
             zone_fallback?: fallback?
           }}

        _ ->
          :error
      end
    else
      _ -> :error
    end
  end

  def parse(_, _), do: :error

  @doc "True when the text reads like a usage-limit message, with or without a reset."
  @spec limit_text?(String.t()) :: boolean()
  def limit_text?(text) when is_binary(text),
    do: Regex.match?(~r/hit your .*limit/i, text)

  def limit_text?(_), do: false

  @doc "Maps Claude Code's `quotaLimits.rateLimitType` to a kind."
  @spec kind_from_type(String.t() | nil) :: kind()
  def kind_from_type("five_hour"), do: :five_hour
  def kind_from_type("seven_day" <> _), do: :weekly
  def kind_from_type(_), do: :session

  defp kind(text) do
    down = String.downcase(text)

    cond do
      not limit_text?(text) -> nil
      String.contains?(down, "weekly") -> :weekly
      Regex.match?(~r/5[- ]hour/, down) -> :five_hour
      String.contains?(down, "session") -> :session
      true -> :session
    end
  end

  defp clock(h, m, ampm) do
    hour = String.to_integer(h)
    minute = if m == "", do: 0, else: String.to_integer(m)

    hour24 =
      case String.downcase(ampm) do
        "am" when hour == 12 -> 0
        "am" -> hour
        "pm" when hour == 12 -> 12
        "pm" -> hour + 12
        "" -> hour
      end

    if hour24 in 0..23 and minute in 0..59, do: {:ok, hour24, minute}, else: :error
  end

  defp zone(name) do
    name = String.trim(name)

    case DateTime.now(name) do
      {:ok, _} -> {name, false}
      _ -> {"Etc/UTC", true}
    end
  end

  defp next_time(now, now_local, hour, minute, zone) do
    date = DateTime.to_date(now_local)

    with {:ok, dt} <- at(date, hour, minute, zone) do
      if DateTime.compare(dt, now) == :gt,
        do: {:ok, dt},
        else: at(Date.add(date, 1), hour, minute, zone)
    end
  end

  defp next_date(now, now_local, mon, day, year, hour, minute, zone) do
    month_idx = Enum.find_index(@months, &(&1 == String.downcase(mon)))
    day = String.to_integer(day)

    cond do
      month_idx == nil ->
        :error

      year != "" ->
        with {:ok, d} <- Date.new(String.to_integer(year), month_idx + 1, day),
             do: at(d, hour, minute, zone)

      true ->
        # No year: this year's date, unless that is more than a day in the past.
        with {:ok, d} <- Date.new(now_local.year, month_idx + 1, day),
             {:ok, dt} <- at(d, hour, minute, zone) do
          if DateTime.diff(now, dt) > 86_400 do
            with {:ok, d2} <- Date.new(now_local.year + 1, month_idx + 1, day),
                 do: at(d2, hour, minute, zone)
          else
            {:ok, dt}
          end
        end
    end
  end

  defp at(date, hour, minute, zone) do
    case DateTime.new(date, Time.new!(hour, minute, 0), zone) do
      {:ok, dt} -> {:ok, dt}
      {:ambiguous, first, _second} -> {:ok, first}
      {:gap, _before, after_gap} -> {:ok, after_gap}
      _ -> :error
    end
  end
end
