defmodule Sprat.Nudge.DeliveryTest do
  use ExUnit.Case, async: true

  alias Sprat.Nudge.Delivery
  alias Sprat.Observer.Model.Session

  @empty """
  ● full  $0.00  0s
  ───────────────────────────
  ❯
  ───────────────────────────
    ⏵⏵ auto mode on
  """

  @placeholder """
  ───────────────────────────
  ❯ Try "how do I log an error?"
  ───────────────────────────
  """

  @typing """
  ───────────────────────────
  ❯ hello I was half way through wri
  ───────────────────────────
  """

  @dialog """
    Teach auto mode about your environment?
    ❯ 1. Yes
      2. Not now
    Enter to confirm · Esc to cancel
  ───────────────────────────
  ❯
  ───────────────────────────
  """

  describe "prompt_state/1" do
    test "an empty prompt is ready" do
      assert Delivery.prompt_state(@empty) == :ready
    end

    test "the fresh-session placeholder counts as empty" do
      assert Delivery.prompt_state(@placeholder) == :ready
    end

    test "text in the prompt means the owner is typing" do
      assert Delivery.prompt_state(@typing) == {:hold, :owner_typing}
    end

    test "an open dialog holds delivery even with an empty prompt below it" do
      assert Delivery.prompt_state(@dialog) == {:hold, :dialog}
    end

    test "no prompt on screen holds" do
      assert Delivery.prompt_state("$ ls\nfoo bar\n") == {:hold, :no_prompt}
    end
  end

  describe "flatten/1" do
    test "removes newlines, tabs and backslash escapes cmux would turn into keys" do
      assert Delivery.flatten("[sprat] a\nb\tc \\n d") == "[sprat] a b c ⧵n d"
    end
  end

  describe "deliver/3" do
    setup do
      parent = self()

      cmd = fn
        "tmux", ["capture-pane" | _], _ ->
          {@empty, 0}

        "tmux", args, _ ->
          send(parent, {:tmux, args})
          {"", 0}
      end

      %{cmd: cmd}
    end

    test "types the message then presses Enter in the tmux pane", %{cmd: cmd} do
      s = %Session{session_id: "s1", config_dir: "/c", tmux: "%3"}

      assert {:ok, :tmux} =
               Delivery.deliver(s, "[sprat] hi\nthere", adapters: [:tmux], cmd: cmd, pause_ms: 0)

      assert_received {:tmux, ["send-keys", "-t", "%3", "-l", "[sprat] hi there"]}
      assert_received {:tmux, ["send-keys", "-t", "%3", "Enter"]}
    end

    test "holds without typing when the owner is typing" do
      s = %Session{session_id: "s1", config_dir: "/c", tmux: "%3"}
      parent = self()

      cmd = fn
        "tmux", ["capture-pane" | _], _ -> {@typing, 0}
        "tmux", args, _ -> send(parent, {:typed, args}) && {"", 0}
      end

      assert {:hold, :owner_typing} = Delivery.deliver(s, "x", adapters: [:tmux], cmd: cmd)
      refute_received {:typed, _}
    end

    test "with no surface and no pane, falls through to the clipboard only when asked" do
      s = %Session{session_id: "s1", config_dir: "/c"}
      assert {:error, :no_adapter} = Delivery.deliver(s, "x", adapters: [:cmux, :tmux])

      parent = self()
      copy = fn t -> send(parent, {:copied, t}) && :ok end

      assert {:ok, :clipboard} =
               Delivery.deliver(s, "x", adapters: [:cmux, :tmux, :clipboard], copy_fun: copy)

      assert_received {:copied, "x"}
    end
  end
end
