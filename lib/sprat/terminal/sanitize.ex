defmodule Sprat.Terminal.Sanitize do
  @moduledoc """
  Strips ANSI escape/control sequences from untrusted text (tool output,
  model output) before it is ever written to the terminal — only
  `Sprat.Terminal.Renderer` is allowed to emit escape codes.
  """

  @doc "Strip ANSI/escape sequences and C0/C1 control bytes, keep newline and tab."
  def strip(text) when is_binary(text) do
    text
    # CSI sequences: ESC [ ... final-byte
    |> String.replace(~r/\e\[[0-9;?]*[ -\/]*[@-~]/, "")
    # OSC sequences: ESC ] ... (BEL or ESC \)
    |> String.replace(~r/\e\][^\a\e]*(\a|\e\\)?/, "")
    # any other ESC-led sequence
    |> String.replace(~r/\e[@-Z\\\]^_]/, "")
    |> String.replace(~r/\e./us, "")
    # bare control chars except \n and \t (\r included — a lone CR can
    # overwrite already-written same-line content when written raw)
    |> String.replace(~r/[\x00-\x08\x0B-\x1F\x7F]/, "")
  end
end
