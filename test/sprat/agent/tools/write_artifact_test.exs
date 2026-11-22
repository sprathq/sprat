defmodule Sprat.Agent.Tools.WriteArtifactTest do
  use Sprat.StoreCase, async: true

  alias Sprat.Agent.Tools.WriteArtifact
  alias Sprat.Store.{Artifacts, Missions, Sessions}

  describe "write_artifact call" do
    test "writes an allowed artifact type", %{store: store} do
      {:ok, session} = Sessions.create(store, %{project_path: "/tmp/x"})
      {:ok, mission} = Missions.create(store, session.id, %{objective: "test"})

      context = %{
        store: store,
        mission_id: mission.id,
        role: "researcher",
        allowed_artifact_types: MapSet.new(["intake_summary"])
      }

      args = %{
        "type" => "intake_summary",
        "content" => %{"objective" => "o", "depth" => "quick", "open_questions" => ["q1"]}
      }

      assert {:ok, %{"type" => "intake_summary", "version" => 1}} =
               WriteArtifact.call(args, context)

      assert Artifacts.latest(store, mission.id, :intake_summary)["objective"] == "o"
    end

    test "refuses a type not in this stage's deliverables", %{store: store} do
      {:ok, session} = Sessions.create(store, %{project_path: "/tmp/x"})
      {:ok, mission} = Missions.create(store, session.id, %{objective: "test"})

      context = %{
        store: store,
        mission_id: mission.id,
        role: "researcher",
        allowed_artifact_types: MapSet.new(["intake_summary"])
      }

      args = %{"type" => "product_brief", "content" => %{}}

      assert {:error, %{"kind" => "not_a_deliverable", "message" => message}} =
               WriteArtifact.call(args, context)

      assert message =~ "not a deliverable of this stage"
    end

    test "refuses content that fails the artifact's schema", %{store: store} do
      {:ok, session} = Sessions.create(store, %{project_path: "/tmp/x"})
      {:ok, mission} = Missions.create(store, session.id, %{objective: "test"})

      context = %{
        store: store,
        mission_id: mission.id,
        role: "researcher",
        allowed_artifact_types: MapSet.new(["intake_summary"])
      }

      args = %{"type" => "intake_summary", "content" => %{}}

      assert {:error,
              %{
                "kind" => "validation_failed",
                "artifact_type" => "intake_summary",
                "message" => message
              }} =
               WriteArtifact.call(args, context)

      assert message =~ "objective"
    end

    test "wraps a bare-list content under the type's sole field instead of rejecting it",
         %{store: store} do
      {:ok, session} = Sessions.create(store, %{project_path: "/tmp/x"})
      {:ok, mission} = Missions.create(store, session.id, %{objective: "test"})

      context = %{
        store: store,
        mission_id: mission.id,
        role: "researcher",
        allowed_artifact_types: MapSet.new(["source_register"])
      }

      args = %{
        "type" => "source_register",
        "content" => [%{"title" => "t", "url" => "https://example.com"}]
      }

      assert {:ok, %{"type" => "source_register", "version" => 1}} =
               WriteArtifact.call(args, context)

      assert Artifacts.latest(store, mission.id, :source_register)["sources"] == [
               %{"title" => "t", "url" => "https://example.com"}
             ]
    end

    test "a malformed call names the artifact type and shows what's expected", %{store: store} do
      {:ok, session} = Sessions.create(store, %{project_path: "/tmp/x"})
      {:ok, mission} = Missions.create(store, session.id, %{objective: "test"})

      context = %{
        store: store,
        mission_id: mission.id,
        role: "researcher",
        allowed_artifact_types: MapSet.new(["research_memo"])
      }

      args = %{"type" => "research_memo", "content" => "not an object"}

      assert {:error,
              %{
                "kind" => "malformed_call",
                "artifact_type" => "research_memo",
                "message" => message
              }} =
               WriteArtifact.call(args, context)

      assert message =~ "research_memo"
    end
  end
end
