defmodule Sprat.Terminal.Board.Mirror do
  @moduledoc """
  The open session's own terminal, as the session screen shows it: reads
  its cmux surface (`cmux read-screen`) and sends it single keys
  (`cmux send-key`) to answer a dialog.

  The board runs these itself, not the engine: the board runs inside cmux
  (so cmux answers it), the reads are polled twice a second while the
  screen is open, and keys must land at once. Messages go through the
  engine (`{:send_to_session, …}`) so they wait for a free prompt and show
  on the activity stream.
  """

  alias Sprat.Observer.Surfaces

  @doc "The last `lines` lines of the surface's screen, or `{:error, reason}`."
  def read(surface, lines, opts \\ []) do
    with {:ok, bin} <- cmux(opts) do
      case run(opts).(bin, ["read-screen", "--surface", surface, "--lines", "#{lines}"],
             timeout: 2_000
           ) do
        {out, 0} -> {:ok, out}
        {out, status} -> {:error, "cmux read-screen #{status}: #{String.slice(out, 0, 120)}"}
      end
    end
  end

  @doc "Sends one key: a digit is typed, `up`/`down`/`enter`/`escape` are keys."
  def key(surface, key, opts \\ []) do
    with {:ok, bin} <- cmux(opts) do
      args =
        if key =~ ~r/^[0-9]$/,
          do: ["send", "--surface", surface, key],
          else: ["send-key", "--surface", surface, key]

      case run(opts).(bin, args, timeout: 2_000) do
        {_, 0} -> :ok
        {out, status} -> {:error, "cmux #{status}: #{String.slice(out, 0, 120)}"}
      end
    end
  end

  defp cmux(opts) do
    case Keyword.get_lazy(opts, :cmux_bin, &Surfaces.cmux_bin/0) do
      nil -> {:error, "cmux is not installed"}
      bin -> {:ok, bin}
    end
  end

  defp run(opts), do: Keyword.get(opts, :cmd, &Sprat.Cmd.run/3)
end
