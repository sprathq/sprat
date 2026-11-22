defmodule Sprat.Observer.UsageLimitTest do
  use ExUnit.Case, async: true

  alias Sprat.Observer.UsageLimit

  # 2026-11-23 09:00 UTC = 09:00 Europe/London (GMT, no DST).
  @now ~U[2026-11-23 09:00:00Z]

  test "five-hour limit with minutes, later today" do
    text = "You've hit your 5-hour limit · resets 11:50am (Europe/London)"

    assert {:ok, %{kind: :five_hour, reset_at: ~U[2026-11-23 11:50:00Z], text: ^text}} =
             UsageLimit.parse(text, @now)
  end

  test "time already passed today rolls to tomorrow" do
    assert {:ok, %{kind: :session, reset_at: ~U[2026-11-24 04:00:00Z]}} =
             UsageLimit.parse("You've hit your session limit · resets 4am (Europe/London)", @now)
  end

  test "session limit, hour only, pm" do
    assert {:ok, %{kind: :session, reset_at: ~U[2026-11-23 16:00:00Z], zone_fallback?: false}} =
             UsageLimit.parse("You've hit your session limit · resets 4pm (Europe/London)", @now)
  end

  test "12am and 12pm" do
    assert {:ok, %{reset_at: ~U[2026-11-23 12:00:00Z]}} =
             UsageLimit.parse("You've hit your session limit · resets 12pm (Europe/London)", @now)

    assert {:ok, %{reset_at: ~U[2026-11-24 00:30:00Z]}} =
             UsageLimit.parse(
               "You've hit your session limit · resets 12:30am (Europe/London)",
               @now
             )
  end

  test "weekly with a date, credits suffix and error tail" do
    text =
      "You've hit your weekly limit · resets Nov 24 at 5pm (Europe/London) · out of usage credits" <>
        " (error type rate_limit, HTTP 429, request id req_abc)"

    assert {:ok, %{kind: :weekly, reset_at: ~U[2026-11-24 17:00:00Z]}} =
             UsageLimit.parse(text, @now)
  end

  test "a date earlier in the year means next year" do
    assert {:ok, %{reset_at: ~U[2027-01-02 17:00:00Z]}} =
             UsageLimit.parse(
               "You've hit your weekly limit · resets Jan 2 at 5pm (Europe/London)",
               @now
             )
  end

  test "summer time converts with DST" do
    now = ~U[2026-07-01 08:00:00Z]

    assert {:ok, %{reset_at: ~U[2026-07-01 10:50:00Z]}} =
             UsageLimit.parse(
               "You've hit your 5-hour limit · resets 11:50am (Europe/London)",
               now
             )
  end

  test "other zones" do
    assert {:ok, %{reset_at: ~U[2026-11-23 21:00:00Z]}} =
             UsageLimit.parse(
               "You've hit your 5-hour limit · resets 4pm (America/New_York)",
               @now
             )
  end

  test "unknown zone falls back to UTC and says so" do
    assert {:ok, %{reset_at: ~U[2026-11-23 16:00:00Z], zone_fallback?: true}} =
             UsageLimit.parse("You've hit your session limit · resets 4pm (Mars/Olympus)", @now)
  end

  test "org spend limit carrying a session reset" do
    text =
      "You've hit your org's monthly spend limit · run /usage-credits to ask your admin for a higher limit · your session limit resets 9:30pm (Europe/London)"

    assert {:ok, %{kind: :session, reset_at: ~U[2026-11-23 21:30:00Z]}} =
             UsageLimit.parse(text, @now)
  end

  test "no reset or not a limit is :error" do
    assert :error =
             UsageLimit.parse(
               "You've hit your monthly spend limit. /model to switch models.",
               @now
             )

    assert :error = UsageLimit.parse("API Error: Connection refused", @now)
    assert :error = UsageLimit.parse("resets 4pm (Europe/London)", @now)
    assert :error = UsageLimit.parse(nil, @now)
  end
end
