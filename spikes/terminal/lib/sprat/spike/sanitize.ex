defmodule Sprat.Spike.Sanitize do
  @moduledoc """
  Point 9: untrusted text (simulated tool output) must not be able to emit
  terminal escape sequences or other control bytes — only Sprat's own
  renderer writes escape codes (spec §9 "Terminal safety").
  """

  @doc "Strip ANSI/escape sequences and C0/C1 control bytes, keep newline and tab."
  def strip(text) when is_binary(text) do
    text
    # CSI sequences: ESC [ ... final-byte
    |> String.replace(~r/\e\[[0-9;?]*[ -\/]*[@-~]/, "")
    # OSC sequences: ESC ] ... (BEL or ESC \)
    |> String.replace(~r/\e\][^\a\e]*(\a|\e\\)?/, "")
    # any other ESC-led sequence (2-3 bytes)
    |> String.replace(~r/\e[@-Z\\\]^_]/, "")
    |> String.replace(~r/\e./us, "")
    # bare control chars except \n and \t
    |> String.replace(~r/[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]/, "")
  end
end
