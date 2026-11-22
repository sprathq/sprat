defmodule Sprat.Store.RedactTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Sprat.Store.Redact

  describe "scrub/2" do
    test "replaces a secret string with the marker" do
      {scrubbed, redacted?} = Redact.scrub("api key is sk-ant-abc123", ["sk-ant-abc123"])
      assert redacted?
      assert scrubbed == "api key is [REDACTED]"
    end

    test "returns the payload unchanged when no secret matches" do
      assert {"hello world", false} = Redact.scrub("hello world", ["sk-ant-abc123"])
    end

    test "returns the payload unchanged when the secret set is empty" do
      assert {"hello world", false} = Redact.scrub("hello world", [])
    end

    test "scrubs secrets nested in maps, lists and tuples" do
      payload = %{
        "headers" => %{"authorization" => "Bearer sk-ant-abc123"},
        "log_lines" => ["fetching...", "using key sk-ant-abc123 now"],
        "pair" => {"sk-ant-abc123", "safe"}
      }

      {scrubbed, redacted?} = Redact.scrub(payload, ["sk-ant-abc123"])

      assert redacted?
      assert scrubbed["headers"]["authorization"] == "Bearer [REDACTED]"
      assert scrubbed["log_lines"] == ["fetching...", "using key [REDACTED] now"]
      assert scrubbed["pair"] == {"[REDACTED]", "safe"}
    end

    test "ignores secrets shorter than 4 characters" do
      {scrubbed, redacted?} = Redact.scrub("the cat sat", ["at"])
      refute redacted?
      assert scrubbed == "the cat sat"
    end

    test "handles multiple distinct secrets in one payload" do
      {scrubbed, redacted?} = Redact.scrub("key1=sk-aaaa key2=sk-bbbb", ["sk-aaaa", "sk-bbbb"])
      assert redacted?
      assert scrubbed == "key1=[REDACTED] key2=[REDACTED]"
    end
  end

  property "a secret placed anywhere in generated text never survives scrubbing" do
    check all(
            prefix <- StreamData.string(:alphanumeric, max_length: 30),
            suffix <- StreamData.string(:alphanumeric, max_length: 30),
            secret <- StreamData.string(:alphanumeric, min_length: 8, max_length: 24)
          ) do
      payload = prefix <> secret <> suffix
      {scrubbed, _redacted?} = Redact.scrub(payload, [secret])
      refute String.contains?(scrubbed, secret)
    end
  end

  property "a secret nested anywhere in a term tree never survives scrubbing" do
    check all(
            secret <- StreamData.string(:alphanumeric, min_length: 8, max_length: 24),
            other <- StreamData.string(:alphanumeric, max_length: 20)
          ) do
      payload = %{
        "a" => [other, %{"b" => "prefix-" <> secret <> "-suffix"}],
        "c" => {secret, other}
      }

      {scrubbed, redacted?} = Redact.scrub(payload, [secret])

      assert redacted?
      encoded = inspect(scrubbed)
      refute String.contains?(encoded, secret)
    end
  end
end
