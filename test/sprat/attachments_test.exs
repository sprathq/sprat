defmodule Sprat.AttachmentsTest do
  use ExUnit.Case, async: true

  alias Sprat.Attachments
  alias Sprat.Store.Blob

  setup do
    root = Path.join(System.tmp_dir!(), "sprat-attach-test-#{System.unique_integer([:positive])}")

    blob_root =
      Path.join(System.tmp_dir!(), "sprat-attach-blobs-#{System.unique_integer([:positive])}")

    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf(root) end)
    on_exit(fn -> File.rm_rf(blob_root) end)
    {:ok, root: root, blob_root: blob_root}
  end

  describe "mentions/1" do
    test "extracts every @token up to whitespace" do
      assert Attachments.mentions("look at @docs/plan.md and @data/churn.csv please") ==
               ["docs/plan.md", "data/churn.csv"]
    end

    test "an email address is still a mention token — resolve/2 is what filters it out" do
      assert Attachments.mentions("email me at foo@bar.com") == ["bar.com"]
    end

    test "no mentions in plain text" do
      assert Attachments.mentions("just a normal message") == []
    end
  end

  describe "resolve/2" do
    test "an in-root relative path resolves without confirmation", %{root: root} do
      File.write!(Path.join(root, "notes.txt"), "hi")
      assert {:ok, real, :in_root} = Attachments.resolve(root, "notes.txt")
      assert String.ends_with?(real, "notes.txt")
    end

    test "a missing file is reported as not_found (silently ignorable)", %{root: root} do
      assert {:error, :not_found} = Attachments.resolve(root, "nope.txt")
    end

    test "a deny-pattern file (.env) is reported as denied", %{root: root} do
      File.write!(Path.join(root, ".env"), "SECRET=1")
      assert {:error, :denied} = Attachments.resolve(root, ".env")
    end

    test "an absolute path outside root needs confirmation", %{root: root} do
      outside =
        Path.join(
          System.tmp_dir!(),
          "sprat-attach-outside-#{System.unique_integer([:positive])}.txt"
        )

      File.write!(outside, "outside content")
      on_exit(fn -> File.rm(outside) end)

      assert {:confirm, real} = Attachments.resolve(root, outside)
      assert Path.basename(real) == Path.basename(outside)
    end
  end

  describe "attach/4 — plain text and Markdown" do
    test "passes through small text unchanged and hashes it", %{root: root, blob_root: blob_root} do
      path = Path.join(root, "notes.md")
      File.write!(path, "# Title\n\nSome notes.")

      assert {:ok, attachment} = Attachments.attach(root, path, [], blob_root)
      assert attachment.text == "# Title\n\nSome notes."
      assert attachment.kind == :text
      refute attachment.truncated?
      assert {:ok, stored} = Blob.get(attachment.blob_hash, blob_root)
      assert stored == "# Title\n\nSome notes."
    end

    test "caps a large text file with a truncation notice", %{root: root, blob_root: blob_root} do
      path = Path.join(root, "big.txt")
      File.write!(path, String.duplicate("line #{inspect(:x)}\n", 20_000))

      assert {:ok, attachment} = Attachments.attach(root, path, [], blob_root)
      assert attachment.truncated?
      assert attachment.text =~ "truncated"
    end
  end

  describe "attach/4 — CSV" do
    test "renders a readable table with a row count", %{root: root, blob_root: blob_root} do
      path = Path.join(root, "churn.csv")
      File.write!(path, "name,plan\nalice,pro\nbob,free\n")

      assert {:ok, attachment} = Attachments.attach(root, path, [], blob_root)
      assert attachment.kind == :csv
      assert attachment.row_count == 2
      assert attachment.text =~ "| name | plan |"
      assert attachment.text =~ "| alice | pro |"
      refute attachment.truncated?
    end

    test "notes a row-cap truncation for a very large CSV", %{root: root, blob_root: blob_root} do
      path = Path.join(root, "big.csv")
      rows = Enum.map_join(1..600, "\n", &"row#{&1},#{&1}")
      File.write!(path, "a,b\n" <> rows)

      assert {:ok, attachment} = Attachments.attach(root, path, [], blob_root)
      assert attachment.truncated?
      assert attachment.text =~ "rows dropped"
    end
  end

  describe "attach/4 — JSON" do
    test "passes through valid JSON", %{root: root, blob_root: blob_root} do
      path = Path.join(root, "data.json")
      File.write!(path, ~s({"a":1}))

      assert {:ok, attachment} = Attachments.attach(root, path, [], blob_root)
      assert attachment.kind == :json
      refute attachment.text =~ "did not parse"
    end

    test "warns, but still returns the content, for invalid JSON", %{
      root: root,
      blob_root: blob_root
    } do
      path = Path.join(root, "broken.json")
      File.write!(path, "{not json")

      assert {:ok, attachment} = Attachments.attach(root, path, [], blob_root)
      assert attachment.text =~ "did not parse as valid JSON"
    end
  end

  describe "attach/4 — refusals" do
    test "refuses a PDF outright", %{root: root, blob_root: blob_root} do
      path = Path.join(root, "deck.pdf")
      File.write!(path, "%PDF-1.4 not a real pdf")

      assert {:error, {:unsupported, ".pdf"}} = Attachments.attach(root, path, [], blob_root)
    end

    test "refuses an image outright", %{root: root, blob_root: blob_root} do
      path = Path.join(root, "logo.png")
      File.write!(path, <<137, 80, 78, 71, 13, 10, 26, 10>>)

      assert {:error, {:unsupported, ".png"}} = Attachments.attach(root, path, [], blob_root)
    end

    test "refuses an unlabelled binary file (null bytes)", %{root: root, blob_root: blob_root} do
      path = Path.join(root, "weird.dat")
      File.write!(path, <<0, 1, 2, 3, 0, 0>>)

      assert {:error, {:unsupported, ".dat"}} = Attachments.attach(root, path, [], blob_root)
    end
  end

  describe "record_source/3 and content_block/1" do
    test "round-trips through the blob store as a user_provided source", %{
      root: root,
      blob_root: blob_root
    } do
      path = Path.join(root, "churn.csv")
      File.write!(path, "name,plan\nalice,pro\n")

      {:ok, attachment} = Attachments.attach(root, path, [], blob_root)

      fake_source = %{
        source_type: "user_provided",
        snapshot_blob_hash: attachment.blob_hash,
        url: attachment.url
      }

      block = Attachments.content_block(fake_source, blob_root)
      assert block =~ "Attached file content"
      assert block =~ "alice"
    end

    test "content_block/1 is blank for a non-user_provided source" do
      assert Attachments.content_block(%{source_type: "independent_reporting"}) == ""
    end
  end
end
