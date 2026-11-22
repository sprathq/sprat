defmodule Sprat.MissionLiveTest do
  @moduledoc """
  Live smoke test against the real OpenAI API and a real site, proving
  two of this session's real-world fixes end to end rather than through a
  stub:

    * `Sprat.Agent.Tools.WebFetch` fetching a real page and recording it
      as evidence (not a domain-doesn't-exist narration).
    * `Sprat.Mission.build_context/7` giving a *second* submission the
      first exchange, so "analyse that page in more detail" resolves
      without repeating the URL.

  Skipped unless `SPRAT_LIVE=1` and a key is configured, same gate as
  `test/sprat/model/openai_live_test.exs`. Uses `gpt-5-nano` with a tight
  budget cap; total spend for both submissions is a few cents.

      SPRAT_LIVE=1 mix test test/sprat/mission_live_test.exs --include live
  """

  use Sprat.StoreCase

  alias Sprat.Mission
  alias Sprat.Session
  alias Sprat.Store.{Missions, Sessions, Sources, Tasks}

  @moduletag :live
  @model "gpt-5-nano"

  setup do
    if System.get_env("SPRAT_LIVE") != "1" do
      {:ok, skip: true}
    else
      case Sprat.Secrets.resolve() do
        {:ok, key, _source} -> {:ok, api_key: key, skip: false}
        :error -> {:ok, skip: true}
      end
    end
  end

  defp wait_until(fun, tries \\ 4000)
  defp wait_until(_fun, 0), do: false

  defp wait_until(fun, tries) do
    if fun.() do
      true
    else
      if rem(tries, 200) == 0, do: IO.puts("... still waiting (#{tries} ticks left)")
      Process.sleep(25)
      wait_until(fun, tries - 1)
    end
  end

  @tag timeout: 180_000
  test "a real fetch records a source, and a follow-up sees the first exchange without repeating the URL",
       ctx do
    if ctx.skip do
      IO.puts("skipping live test: set SPRAT_LIVE=1 and configure an OpenAI key to run it")
    else
      store = ctx.store

      {:ok, session} =
        Sessions.create(store, %{
          project_path: "/tmp/sprat-mission-live-#{System.unique_integer([:positive])}"
        })

      {:ok, _pid} = Sprat.SessionSupervisor.open(session.id, store: store)
      Sprat.Session.PubSub.subscribe(session.id)

      # A real model may decide to re-fetch a URL it composed itself on
      # the follow-up (not one the user typed), which needs approval
      # (§9) — auto-approve any prompt for the duration of this test so
      # it can't hang forever waiting on a human nobody is playing here.
      auto_approver =
        Task.async(fn ->
          # Long enough to outlast the whole test (its `@tag timeout` is
          # 180s) — an approval prompt that shows up late (e.g. on the
          # second submission, after the first has already taken a
          # while) must still get answered.
          Enum.each(1..3600, fn _ ->
            if Session.snapshot(session.id).live.permission do
              Session.answer_permission(session.id, 0)
            end

            Process.sleep(50)
          end)
        end)

      opts = [
        store: store,
        api_key: ctx.api_key,
        # `test_helper.exs` sets a *global* `:mission_defaults` app env
        # (`model_mod: Sprat.StubModel`) so the rest of the suite never
        # touches the network — this live test must explicitly override
        # it back to the real adapter, or it silently runs against the
        # stub and never calls OpenAI at all.
        model_mod: Sprat.Model.OpenAI,
        model_id: @model,
        budget_cap: Decimal.new("0.30"),
        sync?: false
      ]

      :ok =
        Mission.start(
          session.id,
          "Fetch https://elixir-lang.org and record it as a source with one fact about it.",
          opts
        )

      assert wait_until(fn ->
               case Missions.by_session(store, session.id) do
                 [m] ->
                   match?(
                     [%{status: s}] when s in ["completed", "failed"],
                     Tasks.by_mission(store, m.id)
                   )

                 _ ->
                   false
               end
             end)

      [mission] = Missions.by_session(store, session.id)
      [task1] = Tasks.by_mission(store, mission.id)
      assert task1.status == "completed"
      assert [_ | _] = Sources.by_mission(store, mission.id)

      # `Mission.start/3`'s "one task at a time per session" guard clears
      # its `:persistent_term` marker in the finishing task's own cleanup,
      # a few statements *after* the DB row already reads "completed" —
      # a real user can't type fast enough to lose that race, but this
      # automated follow-up can, so give it a beat.
      Process.sleep(300)

      :ok =
        Mission.start(
          session.id,
          "Without fetching anything new, in one more sentence: what is it built with?",
          opts
        )

      assert wait_until(fn ->
               length(Missions.by_session(store, session.id)) == 2 and
                 case Missions.by_session(store, session.id) do
                   [_, m2] ->
                     match?(
                       [%{status: s}] when s in ["completed", "failed"],
                       Tasks.by_mission(store, m2.id)
                     )

                   _ ->
                     false
                 end
             end)

      %{blocks: blocks} = Session.snapshot(session.id)
      answer = blocks |> Enum.filter(&(&1.kind == :agent_message)) |> List.last()

      refute answer.markdown =~ ~r/which (url|page|site|domain)/i
      refute answer.markdown =~ ~r/provide (the|a) url/i

      IO.puts("live mission follow-up answer: #{answer.markdown}")
      Task.shutdown(auto_approver, :brutal_kill)
    end
  end
end
