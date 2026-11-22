defmodule Sprat.UISupervisor do
  @moduledoc """
  Supervises the terminal UI: `Sprat.Terminal.Input` (raw input reader) and
  one renderer (sole stdout writer), per spec §13's supervision tree. Only
  started when stdout is a real TTY and outside `Mix.env() == :test` — see
  `Sprat.Application` — so `mix test` never touches the real terminal or
  hangs on a tty read.

  `:mode` (default `:zoned`) picks which renderer is that sole writer —
  `Sprat.Terminal.ZonedRenderer` (the default UI, `docs/design/tui-zones.md`)
  or `Sprat.Terminal.Renderer` (`--inline`, the old line-append renderer).
  Exactly one of the two is ever started — never both — which is what
  keeps "exactly one stdout writer" true regardless of which UI is active.

  Enters raw mode and installs the terminal-restore exit traps before
  starting children, and restores on `Supervisor.stop/1` via `terminate/2`
  in whichever renderer is running.

  Also silences OTP's default `:logger` handler for as long as the UI owns
  the screen (`Mode.silence_default_logger!/0`) — that handler otherwise
  writes formatted log events and crash reports straight to stdout,
  independent of and interleaved with the renderer's own writes, which is
  a "second stdout writer" in violation of docs/spec-v1.md §13 just as
  surely as starting two renderers would be. `Sprat.LogHandler` (installed
  separately in `Sprat.Application.start/2`) is unaffected and keeps
  feeding `Sprat.LogBuffer`/the Debug overlay. Restored by `Mode.restore!/1`
  on every exit path that already restores terminal mode.
  """

  use Supervisor

  alias Sprat.Terminal.{Input, Mode, Renderer, ZonedRenderer}

  def start_link(opts \\ []), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(opts) do
    {:ok, saved} = Mode.enable_raw!()
    Mode.silence_default_logger!()
    Mode.install_exit_traps!(saved)

    renderer_mod =
      if Keyword.get(opts, :mode, :zoned) == :inline, do: Renderer, else: ZonedRenderer

    children = [
      {renderer_mod,
       Keyword.take(opts, [
         :commands,
         :history,
         :intent_subscriber,
         :io_device,
         :session_id,
         :project_path
       ])},
      %{id: Input, start: {Input, :start_link, [renderer_mod]}}
    ]

    Supervisor.init(children, strategy: :one_for_all)
  end

  @doc "Which renderer module is the active sole writer — `Renderer` (--inline) or `ZonedRenderer` (default)."
  def renderer_module(opts \\ []),
    do: if(Keyword.get(opts, :mode, :zoned) == :inline, do: Renderer, else: ZonedRenderer)
end
