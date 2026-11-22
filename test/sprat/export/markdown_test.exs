defmodule Sprat.Export.MarkdownTest do
  use ExUnit.Case, async: true

  alias Sprat.Export.Markdown

  describe "render/2" do
    test "known type with every field renders prose, no raw JSON" do
      content = %{
        "problem" => "manual booking spreadsheets",
        "customer" => "small gym owners",
        "mvp_scope" => "single-location booking calendar"
      }

      text = Markdown.render("product_brief", content)
      assert text =~ "manual booking spreadsheets"
      assert text =~ "small gym owners"
      assert text =~ "single-location booking calendar"
      refute text =~ "{\"problem\""
    end

    test "a missing field says so instead of being silently dropped" do
      text = Markdown.render("product_brief", %{"problem" => "x"})
      assert text =~ "_not recorded_"
    end

    test "nil content says so instead of crashing" do
      assert Markdown.render("product_brief", nil) == "_no content recorded_"
    end

    test "a skipped stage's incomplete placeholder renders as an explicit notice" do
      text =
        Markdown.render("research_memo", %{
          "incomplete" => true,
          "reason" => "user skipped after a failure"
        })

      assert text =~ "Skipped"
      assert text =~ "user skipped after a failure"
    end

    test "an unknown artifact type falls back to a generic key/value render, nothing dropped" do
      text = Markdown.render("competitor_matrix_v2", %{"foo" => "bar", "n" => 3})
      assert text =~ "foo"
      assert text =~ "bar"
      assert text =~ "n"
      assert text =~ "3"
    end

    test "validation_plan renders every experiment with its thresholds and decision" do
      content = %{
        "experiments" => [
          %{
            "assumption" => "users will pay",
            "method" => "in-app trial",
            "participant_criteria" => "5 pilot gyms",
            "budget" => "$500",
            "duration" => "2 weeks",
            "success_threshold" => "3 of 5 convert",
            "failure_threshold" => "0 of 5 convert",
            "decision" => "scale or pivot"
          }
        ]
      }

      text = Markdown.render("validation_plan", content)
      assert text =~ "users will pay"
      assert text =~ "3 of 5 convert"
      assert text =~ "0 of 5 convert"
      assert text =~ "scale or pivot"
    end
  end

  describe "summary/2" do
    test "one line, truncated, never the whole artifact" do
      long = String.duplicate("a", 200)
      summary = Markdown.summary("intake_summary", %{"objective" => long})
      assert String.length(summary) < 130
    end

    test "a skipped artifact's summary says so" do
      assert Markdown.summary("research_memo", %{"incomplete" => true, "reason" => "budget"}) =~
               "skipped"
    end
  end

  describe "research_memo/2 — claims with resolved sources" do
    test "a claim's source_ids resolve to Markdown links" do
      source = %Sprat.Store.Sources{id: "src_1", title: "Hex docs", url: "https://hex.pm"}

      content = %{
        "summary" => "s",
        "limitations" => "none",
        "claims" => [%{"text" => "hex lists dependents", "source_ids" => ["src_1"]}]
      }

      text = Markdown.research_memo(content, %{"src_1" => source})
      assert text =~ "[Hex docs](https://hex.pm)"
    end

    test "a claim source id with no matching source prints the bare id, not a broken link" do
      content = %{
        "summary" => "s",
        "limitations" => "none",
        "claims" => [%{"text" => "x", "source_ids" => ["src_missing"]}]
      }

      text = Markdown.research_memo(content, %{})
      assert text =~ "src_missing"
    end

    test "an assumption claim is marked as such, not as unsupported" do
      content = %{
        "summary" => "s",
        "limitations" => "none",
        "claims" => [%{"text" => "x", "is_assumption" => true}]
      }

      text = Markdown.research_memo(content, %{})
      assert text =~ "(assumption)"
      refute text =~ "unsupported"
    end

    test "a claim with no source and not an assumption is marked unsupported" do
      content = %{
        "summary" => "s",
        "limitations" => "none",
        "claims" => [%{"text" => "x"}]
      }

      text = Markdown.research_memo(content, %{})
      assert text =~ "unsupported"
    end

    test "nil content says so instead of crashing" do
      assert Markdown.research_memo(nil, %{}) == "_no content recorded_"
    end
  end
end
