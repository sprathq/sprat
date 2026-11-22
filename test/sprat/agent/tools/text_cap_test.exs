defmodule Sprat.Agent.Tools.TextCapTest do
  use ExUnit.Case, async: true

  alias Sprat.Agent.Tools.TextCap

  describe "cap/2" do
    test "returns the text unchanged when under the budget" do
      assert {"hello", false, 0} = TextCap.cap("hello", 8_000)
    end

    test "truncates at a newline boundary and reports dropped chars" do
      text = String.duplicate("a", 10) <> "\n" <> String.duplicate("b", 10)
      {kept, truncated?, dropped} = TextCap.cap(text, 3)

      assert truncated?
      assert kept == String.duplicate("a", 10)
      assert dropped == byte_size(text) - byte_size(kept)
    end

    test "falls back to the hard limit with no newline to break on" do
      text = String.duplicate("a", 100)
      {kept, true, dropped} = TextCap.cap(text, 3)
      assert byte_size(kept) == 12
      assert dropped == 88
    end
  end

  describe "truncation_notice/3" do
    test "names the dropped character count and the token cap" do
      notice = TextCap.truncation_notice(42, 8_000)
      assert notice =~ "42 characters dropped"
      assert notice =~ "8000-token cap"
    end

    test "accepts a custom subject and kept-note" do
      notice =
        TextCap.truncation_notice(1, 10, subject: "CSV table", kept_note: "kept elsewhere.")

      assert notice =~ "CSV table exceeds"
      assert notice =~ "kept elsewhere."
    end
  end
end
