defmodule Sprat.Store.GrantsTest do
  use Sprat.StoreCase, async: true

  alias Sprat.Store.Grants

  describe "record/2 and approved?/4" do
    test "an approved exact URL is reused, without re-recording action/resource/lifetime", %{
      store: store
    } do
      {session, mission, _task} = fixture_chain(store)

      {:ok, grant} =
        Grants.record(store, session.id, %{
          action: "web_fetch",
          resource: "https://example.com/a",
          resource_scope: "url",
          decision: "approved",
          mission_id: mission.id
        })

      assert grant.lifetime == "session"
      assert Grants.approved?(store, session.id, "web_fetch", "url", "https://example.com/a")
    end

    test "a different URL on the same host is not covered by a url-scoped grant", %{store: store} do
      {session, mission, _task} = fixture_chain(store)

      Grants.record(store, session.id, %{
        action: "web_fetch",
        resource: "https://example.com/a",
        resource_scope: "url",
        decision: "approved",
        mission_id: mission.id
      })

      refute Grants.approved?(store, session.id, "web_fetch", "url", "https://example.com/b")
    end

    test "a domain grant never widens to a subdomain", %{store: store} do
      {session, mission, _task} = fixture_chain(store)

      Grants.record(store, session.id, %{
        action: "web_fetch",
        resource: "example.com",
        resource_scope: "domain",
        decision: "approved",
        mission_id: mission.id
      })

      assert Grants.approved?(store, session.id, "web_fetch", "domain", "example.com")
      refute Grants.approved?(store, session.id, "web_fetch", "domain", "sub.example.com")
    end

    test "a grant from one session is not visible in another", %{store: store} do
      {session_a, mission_a, _task_a} = fixture_chain(store)
      {session_b, _mission_b, _task_b} = fixture_chain(store)

      Grants.record(store, session_a.id, %{
        action: "web_fetch",
        resource: "example.com",
        resource_scope: "domain",
        decision: "approved",
        mission_id: mission_a.id
      })

      refute Grants.approved?(store, session_b.id, "web_fetch", "domain", "example.com")
    end
  end
end
