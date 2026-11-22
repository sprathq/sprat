defmodule Sprat.Session.Subscriber do
  @moduledoc """
  The thin adapter between a `Sprat.Session` and `Sprat.Terminal.Renderer`
  (docs/spec-v1.md §13: UI subscribes to the projection via `Registry`
  pub/sub; the domain never calls the renderer). This is the only module
  that both `alias`es `Sprat.Session` and calls into
  `Sprat.Terminal.Renderer`/`Sprat.Session.Render`.

  On start it subscribes, takes one snapshot, and replays every existing
  block in a **single** `Renderer.commit/2` call (§16: résumé of a
  2,000-event session must not redraw one block at a time), then forwards
  the live region. After that it just relays `{:block_added, _}`,
  `{:live_updated, _}` and `{:mode_changed, _}` broadcasts one at a time —
  those already happen at interactive, not bulk, rates.

  Draw width is cached once at `init/1` (from the renderer's own reported
  content width, or the `:cols` option — tests pass this to avoid a live
  round-trip to the renderer) rather than re-queried on every block: it
  only matters for cosmetic wrapping, and re-fetching it on the hot path
  of every streamed block would cost a `GenServer.call` per commit for no
  correctness benefit. A live resize is picked up by the renderer itself
  re-laying-out the *live* region (`Sprat.Terminal.Renderer`'s own resize
  poll); committed scrollback, like a real terminal's, is never
  re-wrapped after the fact either.

  Under `ZonedRenderer`, "content width" is `ZonedRenderer.content_width/1`
  — the Conversation zone's actual interior width, not the raw terminal
  `cols` its `:snapshot` reports. Wrapping committed lines to the full
  terminal width and then having the zone's own bordered box
  ellipsis-truncate each already-"wrapped" line a second time (because it
  was still wider than the zone) was the cause of a real answer reading
  `"…involves packaging your application and its depende…"` — wrapped
  once for the wrong width, then cut, not wrapped, for the real one.
  `Renderer` (`--inline`) has no zones or borders, so its raw `cols` is
  already the right wrap width.
  """

  use GenServer

  alias Sprat.Terminal.{Renderer, ZonedRenderer}
  alias Sprat.Session
  alias Sprat.Session.Render

  defstruct [:session_id, :renderer, :cols]

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl true
  def init(opts) do
    session_id = Keyword.fetch!(opts, :session_id)
    renderer = Keyword.get(opts, :renderer, Renderer)
    cols = Keyword.get(opts, :cols) || fetch_content_width(renderer)
    {:ok, _owner} = Session.PubSub.subscribe(session_id)

    state = %__MODULE__{session_id: session_id, renderer: renderer, cols: cols}
    replay(state, Session.snapshot(session_id))

    {:ok, state}
  end

  @impl true
  def handle_info({:sprat_session, _session_id, {:block_added, block}}, state) do
    Renderer.commit(state.renderer, Render.to_lines(block, state.cols))
    {:noreply, state}
  end

  def handle_info({:sprat_session, _session_id, {:live_updated, live}}, state) do
    Renderer.set_live(state.renderer, live)
    {:noreply, state}
  end

  def handle_info({:sprat_session, _session_id, {:mode_changed, _mode}}, state) do
    {:noreply, state}
  end

  # `Sprat.Mission`'s per-turn view-model updates (agent state, message-flow
  # traffic, Inspector tabs) — ephemeral, not replayed on resume (the store
  # is the source of truth for all of it), so only the zoned renderer,
  # which actually has zones for them, gets these; `--inline` has no
  # Agents/Inspector zone and would crash on a cast it doesn't handle.
  def handle_info({:sprat_session, _session_id, {:agents_updated, view_model}}, state) do
    if zoned?(state), do: ZonedRenderer.set_agents(state.renderer, view_model)
    {:noreply, state}
  end

  def handle_info({:sprat_session, _session_id, {:message_added, message}}, state) do
    if zoned?(state), do: ZonedRenderer.add_message(state.renderer, message)
    {:noreply, state}
  end

  def handle_info({:sprat_session, _session_id, {:inspector_updated, view_model}}, state) do
    if zoned?(state), do: ZonedRenderer.set_inspector(state.renderer, view_model)
    {:noreply, state}
  end

  defp zoned?(state), do: state.renderer == ZonedRenderer

  defp replay(state, snapshot) do
    case Render.batch_to_lines(snapshot.blocks, state.cols) do
      [] -> :ok
      lines -> Renderer.commit(state.renderer, lines)
    end

    Renderer.set_live(state.renderer, snapshot.live)
  end

  # A short, explicit timeout (rather than `Renderer.snapshot/1`'s default
  # 5s) — this is only cosmetic wrap width at startup, so falling back to
  # 80 columns is always safe, and nothing should ever make the renderer
  # process take anywhere near 5s to answer a `:call`.
  @cols_timeout_ms 500

  # Both `Renderer` and `ZonedRenderer` implement `:content_width` (see
  # each module's own `content_width/1` doc) — `Renderer` just answers
  # with its raw `cols` (no zones/borders to account for), so this never
  # needs to guess which one it's talking to, and never risks crashing an
  # unrelated renderer by calling something it doesn't handle.
  defp fetch_content_width(renderer) do
    GenServer.call(renderer, :content_width, @cols_timeout_ms)
  catch
    :exit, _ -> 80
  end
end
