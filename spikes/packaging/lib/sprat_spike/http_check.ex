defmodule SpratSpike.HttpCheck do
  @moduledoc """
  Proves HTTPS + CA bundle work inside a packaged binary: one GET, report
  the status code.
  """

  @doc "GETs https://example.com and returns {:ok, status} | {:error, term}."
  def smoke_test do
    case Req.get("https://example.com") do
      {:ok, %Req.Response{status: status}} -> {:ok, status}
      {:error, reason} -> {:error, reason}
    end
  end
end
