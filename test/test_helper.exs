ExUnit.start(exclude: [:live, :real_machine])

# Sprat.Mission (the real mission-join code) defaults to the real OpenAI
# adapter and network calls — never acceptable in the general test suite,
# which must run offline and free. Every test that goes through
# `Sprat.Session.Commands.handle/3`'s plain-message path (rather than
# calling `Sprat.Mission.start/3` directly with its own opts, the way
# `test/sprat/mission_test.exs` does) picks these up instead: a scripted
# `Sprat.StubModel` model id, a pre-set budget (skips the first-mission
# confirm prompt, which would otherwise block forever with nobody to
# answer it), and a fake key (never dereferenced — the stub never makes
# an HTTP call).
Application.put_env(:sprat, :mission_defaults,
  model_mod: Sprat.StubModel,
  model_id: "gpt-5-nano",
  api_key: "test-key",
  budget_cap: Decimal.new("5.00")
)

{:ok, _} =
  Sprat.StubModel.start_script(
    "gpt-5-nano",
    List.duplicate(
      %{content: "test stub answer", tool_calls: [], stop_reason: :stop, usage: %{}, raw: %{}},
      500
    )
  )
