defmodule Sprat.Session.BlockTest do
  use ExUnit.Case, async: true

  alias Sprat.Session.Block

  describe "decode/1 (docs backlog defect: legacy sessions crash on resume)" do
    test "round-trips a block written by encode/1" do
      block = %{kind: :agent_message, role: "researcher", markdown: "hi there"}
      assert Block.decode(Block.encode(block)) == block
    end

    # Found against a real database written by an older Sprat build:
    # `messages.content` used to just be the raw text, with no JSON
    # envelope at all — `JSON.decode!/1` raised on it, taking down
    # `Session.init/1`'s replay (and the whole session) the moment
    # `sprat --resume` hit one.
    test "a bare, pre-JSON-envelope string decodes to a placeholder instead of raising" do
      assert Block.decode("Assigned to Researcher: hello") == %{
               kind: :system,
               text: "(a message from an older Sprat build could not be read)"
             }
    end

    test "JSON with no \"kind\" field decodes to a placeholder instead of raising" do
      assert Block.decode(~s({"text":"hi"})) == %{
               kind: :system,
               text: "(a message from an older Sprat build could not be read)"
             }
    end

    test "a \"kind\" this build no longer recognizes decodes to a placeholder instead of raising" do
      assert Block.decode(~s({"text":"hi","kind":"no_longer_supported"})) == %{
               kind: :system,
               text: "(a message from an older Sprat build could not be read)"
             }
    end

    test "a \"kind\" that happens to name an atom that exists elsewhere in the VM, but isn't a real block kind, is still rejected" do
      # `:ok` is about as common an atom as exists — proves the fix checks
      # membership in `@kinds`, not just that `String.to_existing_atom/1`
      # didn't raise.
      assert Block.decode(~s({"text":"hi","kind":"ok"})) == %{
               kind: :system,
               text: "(a message from an older Sprat build could not be read)"
             }
    end

    test "JSON that isn't an object (a bare list) decodes to a placeholder instead of raising" do
      assert Block.decode(~s([1,2,3])) == %{
               kind: :system,
               text: "(a message from an older Sprat build could not be read)"
             }
    end
  end
end
