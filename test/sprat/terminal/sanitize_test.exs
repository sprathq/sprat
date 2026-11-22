defmodule Sprat.Terminal.SanitizeTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Sprat.Terminal.Sanitize

  test "strips CSI, OSC, and control bytes while preserving newline and tab" do
    raw = "\e[31mRED\e]0;title\aTEXT\a\e[?25lctrl\x01\x02\nkeep\tthis"
    assert Sanitize.strip(raw) == "REDTEXTctrl\nkeep\tthis"
  end

  test "leaves plain text untouched" do
    assert Sanitize.strip("hello world") == "hello world"
  end

  test "a bare ESC also consumes the byte right after it (can't distinguish from a broken sequence)" do
    assert Sanitize.strip("a\eb") == "a"
  end

  test "strips carriage return (can overwrite already-written same-line content)" do
    assert Sanitize.strip("a\rb") == "ab"
  end

  property "output never contains ESC or disallowed control bytes" do
    control_byte = StreamData.integer(0x00..0x1F) |> StreamData.map(&<<&1>>)
    fragment = StreamData.one_of([StreamData.string(:printable, max_length: 5), control_byte])

    check all(fragments <- StreamData.list_of(fragment, max_length: 30)) do
      text = Enum.join(fragments)
      out = Sanitize.strip(text)
      refute out =~ <<0x1B>>

      for byte <- 0x00..0x1F, byte not in [?\n, ?\t] do
        refute out =~ <<byte>>
      end

      refute out =~ <<0x7F>>
    end
  end
end
