defmodule Sprat.FixturesExportTest do
  @moduledoc """
  Guards the one property `mix sprat.fixtures.export` (build brief step 1)
  must never violate: the owner's real API key can never land in a
  checked-in replay fixture. `Sprat.Secrets` (see its moduledoc) shapes
  every key it resolves as a plain string registered in
  `Sprat.Secrets.redaction_set/0`, and the concrete OpenAI key shape is
  `sk-` followed by 20+ alphanumeric/`-`/`_` characters — the pattern this
  test scans every exported fixture file for.
  """

  use ExUnit.Case, async: true

  @fixtures_dir "test/fixtures/missions"
  @key_pattern ~r/\bsk-[A-Za-z0-9_-]{20,}\b/

  @fixture_files @fixtures_dir
                 |> Path.join("**/*.json")
                 |> Path.wildcard()

  test "at least one mission fixture is checked in" do
    assert @fixture_files != [], "expected exported fixtures under #{@fixtures_dir}"
  end

  test "no fixture file contains anything shaped like a live OpenAI API key" do
    Enum.each(@fixture_files, fn path ->
      content = File.read!(path)
      refute content =~ @key_pattern, "#{path} contains what looks like a live API key"
    end)
  end

  # If this test run's own environment happens to have the real key
  # available (an env var, or `.env` in this project), it must not appear
  # verbatim either — the concrete case the redaction path exists for.
  test "no fixture file contains this environment's resolved API key" do
    case Sprat.Secrets.resolve() do
      {:ok, key, _source} ->
        Enum.each(@fixture_files, fn path ->
          refute File.read!(path) =~ key, "#{path} contains this environment's live API key"
        end)

      :error ->
        :ok
    end
  end
end
