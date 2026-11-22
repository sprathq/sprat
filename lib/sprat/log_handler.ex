defmodule Sprat.LogHandler do
  @moduledoc """
  A `:logger` handler (OTP's handler behaviour — `log/2`) that formats
  every log event as one line and writes it into `Sprat.LogBuffer`, after
  redacting it exactly like every other sink (`Sprat.Store.Redact.scrub/2`
  against `Sprat.Secrets.redaction_set/0` — docs/spec-v1.md §11: "API keys
  and any value loaded from the credential store are redacted before any
  write or render"). Installed once, in `Sprat.Application.start/2`, via
  `:logger.add_handler/3`; never touches stdout/stderr itself. Whether the
  *default* console handler still writes to stdout depends on whether the
  zoned/inline UI currently owns the screen: `Sprat.UISupervisor.init/1`
  removes it for as long as a renderer is the sole stdout writer
  (`Sprat.Terminal.Mode.silence_default_logger!/0`), restoring it on every
  exit path. Outside that window (headless/`--plain`/`-p`, no real tty)
  the default handler is left alone and keeps writing to stdout as usual.
  This module's own sink is unaffected either way — it always feeds
  `Sprat.LogBuffer`, silenced default handler or not.
  """

  alias Sprat.Store.Redact

  @doc "Installs this handler under `id` (idempotent: re-adding the same id is a no-op error this ignores)."
  def install(id \\ :sprat_log_buffer) do
    case :logger.add_handler(id, __MODULE__, %{level: :info}) do
      :ok -> :ok
      {:error, {:already_exist, ^id}} -> :ok
      other -> other
    end
  end

  @doc "The `:logger` handler callback."
  def log(%{level: level, msg: msg, meta: meta}, _config) do
    line = format(level, msg, meta)
    {scrubbed, _redacted?} = Redact.scrub(line, Sprat.Secrets.redaction_set())
    Sprat.LogBuffer.add(scrubbed)
  rescue
    # A logging sink must never itself crash the process that logged —
    # matches the console handler's own defensive posture.
    _ -> :ok
  end

  defp format(level, {:string, chardata}, meta),
    do: "#{timestamp(meta)} [#{level}] #{IO.chardata_to_string(chardata)}"

  defp format(level, {format, args}, meta) when is_list(args) do
    text = format |> :io_lib.format(args) |> IO.chardata_to_string()
    "#{timestamp(meta)} [#{level}] #{text}"
  rescue
    _ -> "#{timestamp(meta)} [#{level}] #{inspect({format, args})}"
  end

  defp format(level, {report_kind, report}, meta) when is_map(report) or is_list(report),
    do: "#{timestamp(meta)} [#{level}] #{inspect(report_kind)}: #{inspect(report)}"

  defp format(level, msg, meta), do: "#{timestamp(meta)} [#{level}] #{inspect(msg)}"

  defp timestamp(%{time: time}) when is_integer(time) do
    time
    |> DateTime.from_unix!(:microsecond)
    |> DateTime.to_iso8601()
  end

  defp timestamp(_meta), do: DateTime.utc_now() |> DateTime.to_iso8601()
end
