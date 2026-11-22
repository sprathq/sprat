defmodule SpratSpike.RawMode do
  @moduledoc """
  Proves OTP raw terminal mode works in a packaged binary: switch to
  `{:noshell, :raw}`, read one key, print its bytes, restore cooked mode.
  """

  @doc "Reads one keypress in raw mode and returns its bytes, restoring the terminal afterwards."
  def smoke_test do
    :shell.start_interactive({:noshell, :raw})

    result =
      case IO.getn("", 1) do
        data when is_binary(data) -> {:ok, :binary.bin_to_list(data)}
        :eof -> {:error, :eof}
        other -> {:error, other}
      end

    :shell.start_interactive({:noshell, :cooked})
    result
  end
end
