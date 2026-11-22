defmodule Sprat.Engine.Notifier do
  @moduledoc """
  Desktop notification for a new **yours** ticket (spec-v4 §10.3): cmux's
  own notification when cmux is installed (it shows in the sidebar and
  respects the owner's cmux settings), otherwise macOS Notification Center.
  Best effort; never raises.
  """

  def notify(title, body) do
    body = String.slice(body || "", 0, 180)

    cond do
      bin = Sprat.Observer.Surfaces.cmux_bin() ->
        Sprat.Cmd.run(bin, ["notify", "--title", title, "--body", body], timeout: 5_000)

      osa = System.find_executable("osascript") ->
        script = "display notification #{osa_quote(body)} with title #{osa_quote(title)}"
        Sprat.Cmd.run(osa, ["-e", script], timeout: 5_000)

      true ->
        :ok
    end

    :ok
  rescue
    _ -> :ok
  end

  defp osa_quote(s), do: "\"" <> String.replace(s, ~r/["\\]/, "") <> "\""
end
