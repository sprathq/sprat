defmodule Sprat.Agent.Tools.WebFetchTest do
  use ExUnit.Case, async: true

  alias Sprat.Agent.Tools.WebFetch
  alias Sprat.Store.Blob

  @fixtures Path.join([__DIR__, "..", "..", "..", "fixtures", "web"])
  defp fixture(name), do: File.read!(Path.join(@fixtures, name))

  setup do
    root =
      Path.join(System.tmp_dir!(), "sprat-webfetch-test-#{System.unique_integer([:positive])}")

    on_exit(fn -> File.rm_rf(root) end)
    {:ok, blob_root: root}
  end

  test "a URL from search results (exact match) is auto-approved" do
    context = %{auto_fetch_urls: MapSet.new(["https://example.com/a"])}
    assert WebFetch.auto_approved?("https://example.com/a", context)
  end

  test "a same-site link from an already-fetched page's host is auto-approved" do
    context = %{auto_fetch_hosts: MapSet.new(["example.com"])}
    assert WebFetch.auto_approved?("https://example.com/other-page", context)
  end

  test "a model-composed URL on an unseen host is not auto-approved" do
    refute WebFetch.auto_approved?("https://attacker.example/exfiltrate?q=secret", %{})
  end

  test "call/2 asks for approval instead of fetching when not auto-approved" do
    assert {:needs_approval, %{url: "https://unknown.example/x"}} =
             WebFetch.call(%{"url" => "https://unknown.example/x"}, %{})
  end

  describe "call/2 when auto-approved" do
    test "extracts readable text instead of returning raw HTML, and reports metadata", %{
      blob_root: blob_root
    } do
      bypass = Bypass.open()
      html = fixture("nav_heavy.html")

      Bypass.expect_once(bypass, "GET", "/page", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("text/html")
        |> Plug.Conn.resp(200, html)
      end)

      url = "http://localhost:#{bypass.port}/page"
      context = %{auto_fetch_urls: MapSet.new([url]), blob_root: blob_root}

      assert {:ok, result} = WebFetch.call(%{"url" => url}, context)

      # the model sees the extract, not the raw page
      refute result["text"] =~ "<nav"
      refute result["text"] =~ "gtag"
      assert result["text"] =~ "Getting started"

      assert result["status"] == 200
      assert result["content_type"] =~ "text/html"
      assert result["original_size_bytes"] == byte_size(html)
      assert result["extracted_size_bytes"] < result["original_size_bytes"]
      assert result["truncated"] == false
      assert String.starts_with?(result["url"], "http://localhost:")
    end

    test "stores the full raw body in the blob store, addressed by the returned hash", %{
      blob_root: blob_root
    } do
      bypass = Bypass.open()
      html = fixture("nav_heavy.html")

      Bypass.expect_once(bypass, "GET", "/page", fn conn ->
        conn |> Plug.Conn.put_resp_content_type("text/html") |> Plug.Conn.resp(200, html)
      end)

      url = "http://localhost:#{bypass.port}/page"
      context = %{auto_fetch_urls: MapSet.new([url]), blob_root: blob_root}

      assert {:ok, %{"blob_hash" => hash}} = WebFetch.call(%{"url" => url}, context)
      assert {:ok, stored} = Blob.get(hash, blob_root)
      # the full snapshot is preserved even though the model only saw an extract
      assert stored == html
    end

    test "truncates the extract at the token cap and says plainly how much was dropped", %{
      blob_root: blob_root
    } do
      bypass = Bypass.open()
      html = fixture("long_article.html")

      Bypass.expect_once(bypass, "GET", "/long", fn conn ->
        conn |> Plug.Conn.put_resp_content_type("text/html") |> Plug.Conn.resp(200, html)
      end)

      url = "http://localhost:#{bypass.port}/long"
      # small cap so the fixture (deliberately generated large) is guaranteed to exceed it
      context = %{
        auto_fetch_urls: MapSet.new([url]),
        blob_root: blob_root,
        max_extract_tokens: 200
      }

      assert {:ok, result} = WebFetch.call(%{"url" => url}, context)
      assert result["truncated"] == true
      assert result["text"] =~ "truncated"
      assert result["text"] =~ "200-token cap"
      # never cut mid-word: the notice is appended after a full line
      refute Regex.match?(~r/[a-z]\.\.\.\[/, result["text"])
      assert byte_size(result["text"]) < byte_size(html)

      # the full extract (pre-truncation) is still reflected in the reported size
      assert result["extracted_size_bytes"] > 200 * 4
    end

    test "does not truncate a short page", %{blob_root: blob_root} do
      bypass = Bypass.open()

      Bypass.expect_once(bypass, "GET", "/page", fn conn ->
        Plug.Conn.resp(conn, 200, "hello from the page")
      end)

      url = "http://localhost:#{bypass.port}/page"
      context = %{auto_fetch_urls: MapSet.new([url]), blob_root: blob_root}

      assert {:ok, %{"text" => "hello from the page", "truncated" => false}} =
               WebFetch.call(%{"url" => url}, context)
    end

    test "refuses a non-text content type instead of feeding bytes to the model", %{
      blob_root: blob_root
    } do
      bypass = Bypass.open()

      Bypass.expect_once(bypass, "GET", "/report.pdf", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/pdf")
        |> Plug.Conn.resp(200, <<0x25, 0x50, 0x44, 0x46, 1, 2, 3>>)
      end)

      url = "http://localhost:#{bypass.port}/report.pdf"
      context = %{auto_fetch_urls: MapSet.new([url]), blob_root: blob_root}

      assert {:error, %{"kind" => "unsupported_content_type", "message" => message}} =
               WebFetch.call(%{"url" => url}, context)

      assert message =~ "application/pdf"
    end

    test "refuses an image content type", %{blob_root: blob_root} do
      bypass = Bypass.open()

      Bypass.expect_once(bypass, "GET", "/pic.png", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("image/png")
        |> Plug.Conn.resp(200, <<137, 80, 78, 71>>)
      end)

      url = "http://localhost:#{bypass.port}/pic.png"
      context = %{auto_fetch_urls: MapSet.new([url]), blob_root: blob_root}

      assert {:error, %{"kind" => "unsupported_content_type", "message" => message}} =
               WebFetch.call(%{"url" => url}, context)

      assert message =~ "image/png"
    end
  end

  describe "distinguishable failures (a fetch failure must not read like \"doesn't exist\")" do
    test "a 404 is reported as not_found, distinct from a network error", %{blob_root: blob_root} do
      bypass = Bypass.open()

      Bypass.expect_once(bypass, "GET", "/missing", fn conn ->
        Plug.Conn.resp(conn, 404, "nope")
      end)

      url = "http://localhost:#{bypass.port}/missing"
      context = %{auto_fetch_urls: MapSet.new([url]), blob_root: blob_root}

      assert {:error, %{"kind" => "not_found", "message" => message}} =
               WebFetch.call(%{"url" => url}, context)

      assert message =~ "404"
    end

    test "a non-2xx/404 status is reported as http_error", %{blob_root: blob_root} do
      bypass = Bypass.open()

      Bypass.expect_once(bypass, "GET", "/broken", fn conn ->
        Plug.Conn.resp(conn, 500, "boom")
      end)

      url = "http://localhost:#{bypass.port}/broken"

      context = %{
        auto_fetch_urls: MapSet.new([url]),
        blob_root: blob_root,
        req_opts: [retry: false]
      }

      assert {:error, %{"kind" => "http_error", "message" => message}} =
               WebFetch.call(%{"url" => url}, context)

      assert message =~ "500"
    end

    test "a DNS/connection failure is reported as network_error, never claiming nonexistence" do
      # An unroutable TLD triggers a real DNS failure without any network
      # dependency being controllable in CI — this is what a typo'd,
      # model-composed domain (the real bug: "rierty.co.uk" instead of
      # "rielty.co.uk") actually returns.
      url = "https://this-domain-does-not-resolve.invalid/"
      context = %{auto_fetch_urls: MapSet.new([url])}

      assert {:error, %{"kind" => "network_error", "message" => message}} =
               WebFetch.call(%{"url" => url}, context)

      refute message =~ "the domain does not exist"
      assert message =~ "not proof the domain doesn't exist"
      assert message =~ "misspelled"
    end
  end

  @tag :live
  test "live check: fetching a real page shrinks input tokens a lot (report before/after), and a schemeless URL still resolves" do
    # "elixir-lang.org" with no "https://" — same shape a model composes —
    # exercises `ensure_scheme/1` against a real DNS lookup, not a mock.
    context = %{auto_fetch_urls: MapSet.new(["elixir-lang.org"])}
    assert {:ok, result} = WebFetch.call(%{"url" => "elixir-lang.org"}, context)

    before_tokens = div(result["original_size_bytes"], 4)
    after_tokens = div(byte_size(result["text"]), 4)

    IO.puts(
      "web_fetch live check: elixir-lang.org  before~=#{before_tokens} tokens  " <>
        "after~=#{after_tokens} tokens  (extracted #{result["extracted_size_bytes"]} bytes " <>
        "from #{result["original_size_bytes"]} original bytes, truncated=#{result["truncated"]})"
    )

    assert after_tokens < before_tokens
    refute result["text"] =~ "<script"
  end
end
