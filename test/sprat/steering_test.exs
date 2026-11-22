defmodule Sprat.SteeringTest do
  use Sprat.StoreCase, async: true

  alias Sprat.Steering
  alias Sprat.Store.{Artifacts, Events, SteeringMessages}

  describe "queue/4" do
    test "persists the message immediately, queued", %{store: store} do
      {session, mission, _task} = fixture_chain(store)

      {:ok, message} = Steering.queue(store, session.id, mission.id, "UK only")

      assert message.status == "queued"
      assert [%{text: "UK only"}] = SteeringMessages.by_mission(store, mission.id)
    end

    test "marks every artifact this mission has already written stale", %{store: store} do
      {session, mission, _task} = fixture_chain(store)

      {:ok, _} =
        Artifacts.write(store, mission.id, %{
          type: :research_memo,
          owning_role: "researcher",
          content: %{"summary" => "s"},
          created_by: "researcher"
        })

      {:ok, _} = Steering.queue(store, session.id, mission.id, "UK only")

      assert Artifacts.stale_types(store, mission.id) == MapSet.new([:research_memo])
    end

    test "never fails a mission that has no artifacts yet (the quick single-agent path)", %{
      store: store
    } do
      {session, mission, _task} = fixture_chain(store)
      assert {:ok, _} = Steering.queue(store, session.id, mission.id, "UK only")
    end

    test "records a steering.queued event", %{store: store} do
      {session, mission, _task} = fixture_chain(store)
      {:ok, _} = Steering.queue(store, session.id, mission.id, "UK only")

      assert Enum.any?(Events.by_session(store, session.id), &(&1.type == "steering.queued"))
    end
  end

  describe "take_pending/3" do
    test "is a no-op returning [] when nothing is queued", %{store: store} do
      {session, mission, _task} = fixture_chain(store)
      assert Steering.take_pending(store, session.id, mission.id) == []
    end

    test "delivers every queued message, in order, and marks them delivered", %{store: store} do
      {session, mission, _task} = fixture_chain(store)
      {:ok, _} = Steering.queue(store, session.id, mission.id, "UK only")
      {:ok, _} = Steering.queue(store, session.id, mission.id, "focus on independent gyms")

      assert Steering.take_pending(store, session.id, mission.id) ==
               ["UK only", "focus on independent gyms"]

      assert SteeringMessages.pending(store, mission.id) == []
      # calling again delivers nothing new
      assert Steering.take_pending(store, session.id, mission.id) == []
    end

    test "records a steering.delivered event per message", %{store: store} do
      {session, mission, _task} = fixture_chain(store)
      {:ok, _} = Steering.queue(store, session.id, mission.id, "UK only")
      {:ok, _} = Steering.queue(store, session.id, mission.id, "focus on independent gyms")

      Steering.take_pending(store, session.id, mission.id)

      delivered =
        Events.by_session(store, session.id) |> Enum.filter(&(&1.type == "steering.delivered"))

      assert length(delivered) == 2
    end

    test "nothing is lost if the mission ends before delivery", %{store: store} do
      {session, mission, _task} = fixture_chain(store)
      {:ok, _} = Steering.queue(store, session.id, mission.id, "UK only")

      # The mission ends (fails/abandoned) without ever calling
      # `take_pending/3` again — the message is still durably there,
      # still queued, not silently dropped.
      assert [%{text: "UK only", status: "queued"}] =
               SteeringMessages.by_mission(store, mission.id)
    end
  end

  describe "context_section/3" do
    test "is empty when the mission has never received steering", %{store: store} do
      {session, mission, _task} = fixture_chain(store)
      assert Steering.context_section(store, session.id, mission.id) == ""
    end

    test "delivers anything still queued and renders the mission's whole steering history", %{
      store: store
    } do
      {session, mission, _task} = fixture_chain(store)
      {:ok, _} = Steering.queue(store, session.id, mission.id, "UK only")
      Steering.take_pending(store, session.id, mission.id)
      {:ok, _} = Steering.queue(store, session.id, mission.id, "focus on independent gyms")

      section = Steering.context_section(store, session.id, mission.id)

      assert section =~ "UK only"
      assert section =~ "focus on independent gyms"
      assert SteeringMessages.pending(store, mission.id) == []
    end

    test "still includes steering delivered in an earlier stage — carries forward", %{
      store: store
    } do
      {session, mission, _task} = fixture_chain(store)
      {:ok, _} = Steering.queue(store, session.id, mission.id, "UK only")
      Steering.take_pending(store, session.id, mission.id)

      # A brand-new stage's context is built well after that delivery —
      # the scope change must still be there.
      assert Steering.context_section(store, session.id, mission.id) =~ "UK only"
    end
  end
end
