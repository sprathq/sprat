defmodule Sprat.Terminal.ModeTest do
  use ExUnit.Case, async: false

  alias Sprat.Terminal.Mode

  # async: false — this exercises OTP's actual, process-wide `:logger`
  # handler registry (not a per-process fake), so it can't run concurrently
  # with anything else that adds/removes handlers.

  describe "silence_default_logger!/0 and restore_default_logger!/0" do
    test "removes the default handler, then puts back the same config" do
      assert {:ok, before_config} = :logger.get_handler_config(:default)

      try do
        assert :ok = Mode.silence_default_logger!()
        assert {:error, {:not_found, :default}} = :logger.get_handler_config(:default)

        assert :ok = Mode.restore_default_logger!()
        assert {:ok, after_config} = :logger.get_handler_config(:default)
        assert after_config.module == before_config.module
      after
        # Belt-and-braces: guarantee the real default handler is back even
        # if an assertion above failed mid-test, since the whole test
        # suite's output depends on it.
        Mode.restore_default_logger!()
      end
    end

    test "restore_default_logger!/0 is a no-op when nothing was silenced" do
      assert {:ok, _config} = :logger.get_handler_config(:default)
      assert :ok = Mode.restore_default_logger!()
      assert {:ok, _config} = :logger.get_handler_config(:default)
    end
  end
end
