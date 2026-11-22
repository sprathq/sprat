defmodule Sprat.Terminal.BoardApp do
  @moduledoc """
  The Pass as a running full-screen app (`docs/spec-v4.md` §10): the
  alternate screen, raw mode, key input, resize handling and a line-diffed
  repaint around the pure `Sprat.Terminal.Board` / `Board.Keys`.

  `run/1` blocks the calling process until the owner quits (`q`, Ctrl+C)
  or input closes, and restores the terminal on every exit path: normal
  quit, a raised error or exit in the loop (`try/after`), SIGTERM and VM
  halt (`Sprat.Terminal.Mode.install_exit_traps!/1`).

  ## Options

    * `:snapshot_fun` — `(-> snapshot)`, called every tick and after every
      command (required)
    * `:command_fun` — `(command -> reply)`, where reply is `:ok`,
      `{:error, msg}` or `{:ok, payload}` and payload is one of
      `{:message, text}` (a transient status), `{:edit, path}` (suspend the
      board and run `$VISUAL`/`$EDITOR`/`vi` on the path), `{:brief, text}`
      (an in-place band, esc closes) or `{:session_lines, lines}` (the open
      session's condensed transcript). A bare `{:ok, text}` is a status too.
    * `:poll_ms` — snapshot interval, default 1000
    * `:subscribe` — `(pid -> any)`: called with the board's pid; whoever
      it registers with sends `{:sprat_update}` when a new snapshot is ready
    * `:color` — `:truecolor | :c256 | :c16 | :none`, default detected from
      `NO_COLOR`, `COLORTERM` and `TERM`
    * `:ascii?` — default `Sprat.Terminal.Glyphs.ascii?/0`
    * `:reduced_motion?` — default `SPRAT_REDUCED_MOTION=1`

  While the session view is open the app asks for `{:session_lines, sid}`
  on every poll. `E` on a ticket (`{:edit_in_editor, id, text}`) is handled
  here: the proposal goes to a temp file, the editor opens it, and a
  changed, non-empty result is sent as `{:fire, id, text}`.

  ## Handing the terminal to an editor

  Input is read with the tty in `min 0 time 1`, so the reader returns every
  100 ms and can stop between reads. Before the editor starts, the reader
  is stopped (no read left pending to swallow the editor's first key), the
  alternate screen is left and the tty restored; afterwards all of it is
  set up again and the board repainted from scratch.

  The fish and a live PM run's ticket animate at 10 fps; with nothing
  animating no frame timer runs at all (idle animates nothing).
  """

  alias Sprat.Terminal.{Board, Glyphs, Input, Mode, Screen}
  alias Sprat.Terminal.Board.{Keys, Mirror, View}

  @frame_ms 100
  @resize_ms 250
  @mirror_ms 500
  # The processes screen reads the daemon's processes this often.
  @procs_ms 500
  @status_ms 4_000

  @doc "Runs the board until quit. Returns `:ok`."
  def run(opts) do
    unless Mode.tty?() do
      raise "Sprat.Terminal.BoardApp needs a real terminal (stdin and stdout)"
    end

    snapshot_fun = Keyword.fetch!(opts, :snapshot_fun)
    saved = Mode.saved_stty()
    Mode.install_exit_traps!(saved)
    term = start_terminal(%{saved: saved, input: nil, reader: nil})

    try do
      {cols, rows} = terminal_size()

      state =
        Map.merge(term, %{
          view: %{View.new(safe_snapshot(snapshot_fun)) | first_run?: not help_seen?()},
          snapshot_fun: snapshot_fun,
          command_fun: Keyword.get(opts, :command_fun, fn _ -> :ok end),
          poll_ms: Keyword.get(opts, :poll_ms, 1_000),
          cols: cols,
          rows: rows,
          frame: 0,
          frame_timer: nil,
          status_token: nil,
          last: [],
          color: Keyword.get_lazy(opts, :color, &detect_color/0),
          ascii?: Keyword.get_lazy(opts, :ascii?, fn -> Glyphs.ascii?() end),
          mirror_busy?: false,
          procs_busy?: false,
          # the terminal reports key releases (kitty keyboard protocol)
          kitty?: false,
          # a recording in progress: nil | %{rec, pushed?, started, last_space, held?}
          voice: nil,
          reduced_motion?:
            Keyword.get_lazy(opts, :reduced_motion?, fn ->
              System.get_env("SPRAT_REDUCED_MOTION") == "1"
            end)
        })

      Process.send_after(self(), :tick, state.poll_ms)
      Process.send_after(self(), :resize_poll, @resize_ms)
      Process.send_after(self(), :mirror, @mirror_ms)
      Process.send_after(self(), :procs, @procs_ms)

      # A daemon that pushes its snapshots wakes the board on every change.
      if subscribe = Keyword.get(opts, :subscribe), do: subscribe.(self())
      state |> paint() |> loop()
    after
      stop_terminal(Process.get(:sprat_board_term) || term)
      Mode.restore!(saved)
    end
  end

  # -- terminal ownership --------------------------------------------------------

  defp start_terminal(term) do
    {:ok, saved} = Mode.enable_raw!()
    Mode.stty!(["min", "0", "time", "1"])
    Mode.silence_default_logger!()
    IO.write(Screen.enter_alt_screen() <> Screen.clear_screen())
    # Does the terminal report key releases? Its answer (`\e[?<flags>u`)
    # arrives as `{:kitty_flags, _}`; no answer means tap-to-talk.
    IO.write("\e[?u")

    app = self()
    {:ok, input} = Input.start_link(app, reader: fn parser -> reader(app, parser) end)

    reader =
      receive do
        {:board_reader, pid} -> pid
      after
        1_000 -> nil
      end

    term = %{term | saved: term.saved || saved, input: input, reader: reader}
    Process.put(:sprat_board_term, term)
    term
  end

  defp stop_terminal(%{input: nil} = term), do: term

  defp stop_terminal(term) do
    # Never leave the terminal reporting key releases.
    if Process.get(:sprat_voice_pushed), do: IO.write("\e[<u")

    if term.reader && Process.alive?(term.reader) do
      ref = Process.monitor(term.reader)
      send(term.reader, :stop)

      receive do
        {:DOWN, ^ref, _, _, _} -> :ok
      after
        500 -> :ok
      end
    end

    Process.unlink(term.input)
    Process.exit(term.input, :kill)
    drain_input()
    IO.write(Screen.leave_alt_screen())
    Mode.restore!(term.saved)
    term = %{term | input: nil, reader: nil}
    Process.put(:sprat_board_term, term)
    term
  end

  # Several pushes queued while painting: one refresh covers them all.
  defp drain_updates do
    receive do
      {:sprat_update} -> drain_updates()
    after
      0 -> :ok
    end
  end

  defp drain_input do
    receive do
      {:input_event, _} -> drain_input()
      {:board_reader, _} -> drain_input()
    after
      0 -> :ok
    end
  end

  # Polling reader: with the tty at `min 0 time 1` a read returns `:eof`
  # after 100 ms of quiet, so `:stop` is honoured between reads.
  defp reader(app, parser) do
    send(app, {:board_reader, self()})
    {:ok, fd} = File.open("/dev/stdin", [:read, :raw, :binary])
    poll(parser, fd)
  end

  defp poll(parser, fd) do
    receive do
      :stop -> File.close(fd)
    after
      0 ->
        case :file.read(fd, 256) do
          {:ok, bytes} ->
            send(parser, {:raw_bytes, bytes})
            poll(parser, fd)

          :eof ->
            poll(parser, fd)

          {:error, _} ->
            send(parser, :input_closed)
        end
    end
  end

  # Gives the real terminal to `fun` (an editor), then takes it back.
  defp suspended(state, fun) do
    stop_terminal(state)
    result = fun.()
    term = start_terminal(%{saved: state.saved, input: nil, reader: nil})
    {cols, rows} = terminal_size()
    {result, %{Map.merge(state, term) | last: [], cols: cols, rows: rows}}
  end

  @doc false
  def editor_command, do: ~s(exec ${VISUAL:-${EDITOR:-vi}} "$1")

  defp run_editor(path) do
    port =
      Port.open({:spawn_executable, System.find_executable("sh")}, [
        :nouse_stdio,
        :exit_status,
        args: ["-c", editor_command(), "sh", path]
      ])

    receive do
      {^port, {:exit_status, status}} -> status
    end
  end

  # -- the loop ------------------------------------------------------------------

  defp loop(state) do
    receive do
      {:input_event, :input_closed} ->
        :ok

      {:input_event, {:kitty_flags, _}} ->
        loop(%{state | kitty?: true})

      {:input_event, key} ->
        {view, commands} = Keys.handle(state.view, key)
        view = settle_help(state, view)

        case run_commands(%{state | view: view}, commands) do
          {:quit, _state} -> :ok
          {:cont, state} -> state |> arm_status() |> paint() |> loop()
        end

      :tick ->
        Process.send_after(self(), :tick, state.poll_ms)
        state |> refresh() |> poll_session() |> arm_status() |> paint() |> loop()

      :resize_poll ->
        Process.send_after(self(), :resize_poll, @resize_ms)

        case terminal_size() do
          {cols, rows} when {cols, rows} != {state.cols, state.rows} ->
            IO.write(Screen.clear_screen())
            %{state | cols: cols, rows: rows, last: []} |> paint() |> loop()

          _ ->
            loop(state)
        end

      {:voice_text, result, path} ->
        File.rm(path)
        state |> voice_heard(result) |> refresh() |> arm_status() |> paint() |> loop()

      :voice_check ->
        state |> voice_check() |> paint() |> loop()

      {:voice_partial, rec_path} ->
        state |> voice_partial(rec_path) |> loop()

      {:voice_partial_text, rec_path, result, wav} ->
        File.rm(wav)
        state |> voice_partial_heard(rec_path, result) |> paint() |> loop()

      {:sprat_update} ->
        drain_updates()
        state |> refresh() |> arm_status() |> paint() |> loop()

      :mirror ->
        Process.send_after(self(), :mirror, @mirror_ms)
        state |> read_mirror() |> loop()

      {:mirror_screen, sid, {:ok, text}} ->
        view = View.put_session_screen(state.view, sid, text)
        %{state | view: view, mirror_busy?: false} |> paint() |> loop()

      {:mirror_screen, _sid, {:error, _}} ->
        loop(%{state | mirror_busy?: false})

      :procs ->
        Process.send_after(self(), :procs, @procs_ms)
        state |> read_procs() |> loop()

      {:procs_map, reply} ->
        view =
          case reply do
            {:ok, {:process_map, map}} -> View.put_process_map(state.view, map)
            {:error, why} -> View.put_process_error(state.view, why)
            _ -> View.put_process_error(state.view, :old_daemon)
          end

        %{state | view: view, procs_busy?: false} |> paint() |> loop()

      :frame ->
        %{state | frame: state.frame + 1, frame_timer: nil} |> paint() |> loop()

      {:command_reply, ref, command, reply} ->
        view =
          case state.view.pending do
            %{ref: ^ref} -> %{state.view | pending: nil}
            _ -> state.view
          end

        %{state | view: view}
        |> apply_reply(command, reply)
        |> refresh()
        |> arm_status()
        |> paint()
        |> loop()

      {:clear_status, token} when token == state.status_token ->
        %{state | view: %{state.view | status: nil}, status_token: nil} |> paint() |> loop()

      _other ->
        loop(state)
    end
  end

  defp run_commands(state, commands) do
    Enum.reduce_while(commands, {:cont, state}, fn
      :quit, {_, state} -> {:halt, {:quit, state}}
      command, {_, state} -> {:cont, {:cont, run_command(state, command)}}
    end)
    |> case do
      {:quit, state} -> {:quit, state}
      {:cont, state} -> {:cont, if(commands == [], do: state, else: refresh(state))}
    end
  end

  defp run_command(state, {:edit_in_editor, id, text}) do
    path = Path.join(System.tmp_dir!(), "sprat-answer-#{System.unique_integer([:positive])}.md")
    File.write!(path, text)
    {_status, state} = suspended(state, fn -> run_editor(path) end)
    edited = path |> File.read() |> elem_ok("") |> String.trim()
    File.rm(path)

    cond do
      edited == "" -> set_status(state, "empty answer; nothing sent")
      edited == String.trim(text) -> set_status(state, "unchanged; nothing sent")
      true -> state |> set_status("sending the edited answer") |> run_command({:fire, id, edited})
    end
  end

  # == voice: hold space, speak, let go (Sprat.Voice) ==========================

  # While talking, what was said so far is transcribed again: the first pass
  # after this long, then again this long after each pass ends.
  @partial_first_ms 900
  @partial_every_ms 400

  defp run_command(state, :voice_start) do
    case Sprat.Voice.check() do
      {:missing, what} ->
        set_status(
          state,
          "talking needs " <> Enum.join(what, ", ") <> ": run `sprat voice setup`"
        )

      :ok ->
        path =
          Path.join(System.tmp_dir!(), "sprat-voice-#{System.unique_integer([:positive])}.wav")

        case Sprat.Voice.Recorder.start(path) do
          {:ok, rec} ->
            # Only while listening: ask the terminal to report when space is let go.
            if state.kitty? do
              IO.write("\e[>10u")
              Process.put(:sprat_voice_pushed, true)
            end

            now = System.monotonic_time(:millisecond)
            Process.send_after(self(), :voice_check, 150)
            Process.send_after(self(), {:voice_partial, rec.path}, @partial_first_ms)

            hint =
              if state.kitty?,
                do: "let go of space to stop · esc cancels",
                else: "let go of space (or tap it again) to stop · esc cancels"

            %{
              state
              | voice: %{
                  rec: rec,
                  pushed?: state.kitty?,
                  started: now,
                  last_space: now,
                  held?: false,
                  partial_busy?: false
                },
                view: %{state.view | voice: %{state: :listening, hint: hint}, status: nil}
            }

          {:error, why} ->
            set_status(state, "couldn't listen: " <> why)
        end
    end
  end

  defp run_command(%{voice: nil} = state, command)
       when command in [:voice_stop, :voice_space, :voice_cancel],
       do: state

  # Without key-release reports a held space arrives as auto-repeat: spaces
  # closer together than a pause are the hold; a space after a pause is a
  # second tap, which stops.
  defp run_command(state, :voice_space) do
    now = System.monotonic_time(:millisecond)

    if now - state.voice.last_space < 700,
      do: %{state | voice: %{state.voice | last_space: now, held?: true}},
      else: run_command(state, :voice_stop)
  end

  defp run_command(state, :voice_stop) do
    voice = state.voice
    if voice.pushed?, do: pop_key_reports()
    state = %{state | voice: nil}

    case Sprat.Voice.Recorder.stop(voice.rec) do
      {:ok, path} ->
        app = self()

        # Commands on the board are English and short (auto-detecting the
        # language of two words goes wrong); dictation can be any language.
        opts = voice_opts(state.view)
        partial = state.view.voice && state.view.voice[:partial]

        {:ok, _} =
          Task.start(fn -> send(app, {:voice_text, Sprat.Voice.transcribe(path, opts), path}) end)

        %{
          state
          | view: %{state.view | voice: %{state: :transcribing, hint: "", partial: partial}}
        }

      {:error, why} ->
        File.rm(voice.rec.path)
        %{state | view: %{state.view | voice: nil, status: why}}
    end
  end

  defp run_command(state, :voice_cancel) do
    if state.voice.pushed?, do: pop_key_reports()
    Sprat.Voice.Recorder.cancel(state.voice.rec)
    %{state | voice: nil, view: %{state.view | voice: nil, status: "stopped listening"}}
  end

  # A key for the open session's terminal (answering a dialog): sent from
  # here, then the mirror is read again so the answer shows at once.
  defp run_command(state, {:session_key, sid, key}) do
    case open_surface(state.view, sid) do
      nil ->
        set_status(state, "this session has no cmux tab to send keys to")

      surface ->
        app = self()

        {:ok, _} =
          Task.start(fn ->
            Mirror.key(surface, key)
            send(app, :mirror)
          end)

        state
    end
  end

  # Polled while the session screen is open; answered fast, kept in step.
  defp run_command(state, {:session_lines, _} = command),
    do: apply_reply(state, command, call_engine(state.command_fun, command))

  # Every other command goes to the engine without holding the board: the key
  # answers in the same frame with what is happening (spec-v5 §5), and the
  # reply lands when it comes.
  defp run_command(state, command) do
    app = self()
    ref = make_ref()
    fun = state.command_fun

    {:ok, _} =
      Task.start(fn -> send(app, {:command_reply, ref, command, call_engine(fun, command)}) end)

    label = View.pending_label(state.view, command)
    %{state | view: %{state.view | pending: %{ref: ref, label: label}, status: nil}}
  end

  # Commands on the board are English and short (auto-detecting the
  # language of two words goes wrong); dictation can be any language.
  defp voice_opts(view) do
    case view.screen do
      {:session, _} -> [prompt: Sprat.Voice.Intent.vocabulary(view)]
      _ -> [prompt: Sprat.Voice.Intent.vocabulary(view), language: "en"]
    end
  end

  # While the owner talks, what has been recorded so far is transcribed
  # again, one pass at a time, so the words appear as they speak. The pass
  # after the owner lets go is the one that counts.

  defp voice_partial(%{voice: %{rec: %{path: path}, partial_busy?: false} = v} = state, path) do
    wav = path <> ".partial.wav"

    case Sprat.Voice.Recorder.snapshot(v.rec, wav) do
      {:ok, wav} ->
        app = self()
        opts = voice_opts(state.view)

        {:ok, _} =
          Task.start(fn ->
            send(app, {:voice_partial_text, path, Sprat.Voice.transcribe(wav, opts), wav})
          end)

        %{state | voice: %{v | partial_busy?: true}}

      :too_short ->
        Process.send_after(self(), {:voice_partial, path}, @partial_every_ms)
        state
    end
  end

  # Stopped, cancelled, or a pass still running: nothing to do.
  defp voice_partial(state, _path), do: state

  defp voice_partial_heard(%{voice: %{rec: %{path: path}} = v} = state, path, result) do
    Process.send_after(self(), {:voice_partial, path}, @partial_every_ms)
    state = %{state | voice: %{v | partial_busy?: false}}

    case {result, state.view.voice} do
      {{:ok, text}, %{state: :listening} = shown} when text != "" ->
        %{state | view: %{state.view | voice: Map.put(shown, :partial, text)}}

      _ ->
        state
    end
  end

  # A late pass for a recording that has ended: its words are not shown.
  defp voice_partial_heard(state, _path, _result), do: state

  # A held space (tap mode) that stopped repeating has been let go.
  defp voice_check(%{voice: nil} = state), do: state

  defp voice_check(%{voice: v} = state) do
    now = System.monotonic_time(:millisecond)

    if v.held? and not v.pushed? and now - v.last_space > 500 do
      run_command(state, :voice_stop)
    else
      Process.send_after(self(), :voice_check, 150)
      state
    end
  end

  # What was said: dictation on a session's screen, a command on the board.
  defp voice_heard(state, {:error, why}),
    do: %{state | view: %{state.view | voice: nil, status: "couldn't hear: " <> why}}

  defp voice_heard(state, {:ok, ""}),
    do: %{
      state
      | view: %{state.view | voice: nil, status: "didn't catch that; hold space and try again"}
    }

  defp voice_heard(state, {:ok, text}) do
    view = %{state.view | voice: nil}
    said = "heard “#{text}”"

    case Sprat.Voice.Intent.parse(text, view) do
      {:keys, keys} ->
        {view, commands} =
          Enum.reduce(keys, {view, []}, fn key, {v, cmds} ->
            {v, more} = Keys.handle(v, key)
            {v, cmds ++ more}
          end)

        state = %{state | view: %{view | status: said}}

        case run_commands(state, commands) do
          {:quit, state} -> state
          {:cont, state} -> state
        end

      {:open, screen, label} ->
        view = View.clamp(%{view | screen: screen, opened_ticket: nil, overlay: nil})
        %{state | view: %{view | status: said <> " → opened #{label}"}}

      {:dictate, words} ->
        {view, _} = Keys.handle(view, {:paste, words})
        %{state | view: view}

      {:unknown, _} ->
        %{
          state
          | view: %{
              view
              | status:
                  said <>
                    ": not a command. Try “open <project>”, “talk to <session>”, “activity”, “help”."
            }
        }
    end
  end

  defp pop_key_reports do
    IO.write("\e[<u")
    Process.delete(:sprat_voice_pushed)
  end

  defp call_engine(fun, command) do
    fun.(command)
  rescue
    e -> {:error, "command failed: " <> Exception.message(e)}
  catch
    :exit, reason -> {:error, "command failed: " <> inspect(reason, limit: 3)}
  end

  # Help scrolls only as far as the page goes at this size; opening it once
  # retires the "? explains this screen" hint for good.
  defp settle_help(_state, %View{help?: false} = view), do: view

  defp settle_help(state, view) do
    if not state.view.help?, do: mark_help_seen()

    max =
      Board.help_max_offset(view, %{
        width: state.cols,
        height: state.rows,
        color: state.color,
        ascii?: state.ascii?,
        frame: state.frame
      })

    %{view | help_index: min(view.help_index, max)}
  end

  defp help_marker, do: Path.join([Sprat.Store.Paths.data_dir(), "v4", "help_seen"])

  defp help_seen?, do: File.exists?(help_marker())

  defp mark_help_seen do
    File.mkdir_p(Path.dirname(help_marker()))
    File.write(help_marker(), "")
  end

  defp elem_ok({:ok, v}, _default), do: v
  defp elem_ok(_, default), do: default

  @doc false
  # The view-only part of a reply (no terminal I/O), for tests.
  def apply_view_reply(view, command, reply) do
    case reply do
      {:error, msg} ->
        %{view | status: to_string(msg)}

      {:ok, {:message, text}} ->
        %{view | status: to_string(text)}

      {:ok, {:brief, text}} ->
        %{view | overlay: {:brief, to_string(text)}}

      {:ok, {:session_lines, lines}} when is_list(lines) ->
        sid =
          case {command, view.screen} do
            {{:session_lines, sid}, _} -> sid
            {_, {:session, sid}} -> sid
            _ -> nil
          end

        if sid, do: View.put_session_lines(view, sid, lines), else: view

      {:ok, text} when is_binary(text) ->
        %{view | status: text}

      _ ->
        view
    end
  end

  defp apply_reply(state, _command, {:ok, {:edit, path}}) do
    {status, state} = suspended(state, fn -> run_editor(path) end)
    msg = if status == 0, do: "edited " <> Path.basename(path), else: "editor exited #{status}"
    set_status(state, msg)
  end

  defp apply_reply(state, command, reply) do
    %{state | view: apply_view_reply(state.view, command, reply)}
  end

  defp poll_session(%{view: %View{screen: {:session, sid}}} = state),
    do: run_command(state, {:session_lines, sid})

  defp poll_session(state), do: state

  # While a session's screen shows its terminal, read it twice a second in
  # a task (one read at a time), so the board never waits on cmux.
  defp read_mirror(
         %{mirror_busy?: false, view: %View{screen: {:session, sid}, session_mode: :terminal}} =
           state
       ) do
    case open_surface(state.view, sid) do
      nil ->
        state

      surface ->
        app = self()
        lines = max(state.rows, 20)

        {:ok, _} =
          Task.start(fn -> send(app, {:mirror_screen, sid, Mirror.read(surface, lines)}) end)

        %{state | mirror_busy?: true}
    end
  end

  defp read_mirror(state), do: state

  # Sprat's own processes, while their screen is open: read in a task, one
  # reading at a time.
  defp read_procs(%{procs_busy?: false, view: %View{screen: {:processes, _}}} = state) do
    app = self()
    fun = state.command_fun

    {:ok, _} =
      Task.start(fn -> send(app, {:procs_map, call_engine(fun, :process_map)}) end)

    %{state | procs_busy?: true}
  end

  defp read_procs(state), do: state

  defp open_surface(view, sid) do
    case View.session(view, sid) do
      {%{surface: "surface:" <> _ = surface}, _p} -> surface
      _ -> nil
    end
  end

  defp set_status(state, msg), do: %{state | view: %{state.view | status: msg}}

  # A new status message expires after a few seconds.
  defp arm_status(%{view: %{status: nil}} = state), do: state

  defp arm_status(%{status_token: {status, _ref}} = state) when status == state.view.status,
    do: state

  defp arm_status(state) do
    ref = make_ref()
    token = {state.view.status, ref}
    Process.send_after(self(), {:clear_status, token}, @status_ms)
    %{state | status_token: token}
  end

  defp refresh(state) do
    case safe_snapshot(state.snapshot_fun) do
      nil ->
        state

      snapshot ->
        state |> Map.put(:view, View.put_snapshot(state.view, snapshot)) |> warn(snapshot)
    end
  end

  # A daemon that stopped publishing says so on every refresh, rather than
  # leaving a board that looks alive but never changes.
  defp warn(state, %{daemon_warning: msg}) when is_binary(msg), do: set_status(state, msg)
  defp warn(state, _snapshot), do: state

  defp safe_snapshot(fun) do
    fun.()
  rescue
    _ -> nil
  end

  defp paint(state) do
    lines =
      Board.render(state.view, %{
        width: state.cols,
        height: state.rows,
        color: state.color,
        ascii?: state.ascii?,
        frame: state.frame,
        reduced_motion?: state.reduced_motion?
      })

    last = state.last

    out =
      lines
      |> Enum.with_index()
      |> Enum.reject(fn {line, i} -> Enum.at(last, i) == line end)
      |> Enum.map(fn {line, i} ->
        ["\e[", Integer.to_string(i + 1), ";1H\e[0m", line, "\e[0m\e[K"]
      end)

    if out != [], do: IO.write(IO.iodata_to_binary(out))

    schedule_frame(%{state | last: lines})
  end

  defp schedule_frame(%{frame_timer: nil} = state) do
    if View.animating?(state.view, reduced_motion?: state.reduced_motion?) do
      %{state | frame_timer: Process.send_after(self(), :frame, @frame_ms)}
    else
      state
    end
  end

  defp schedule_frame(state), do: state

  @doc "Colour depth from the environment: NO_COLOR, COLORTERM, TERM."
  def detect_color do
    term = System.get_env("TERM") || ""
    colorterm = System.get_env("COLORTERM") || ""

    cond do
      System.get_env("NO_COLOR") not in [nil, ""] -> :none
      colorterm in ["truecolor", "24bit"] -> :truecolor
      String.contains?(term, "256color") -> :c256
      term in ["", "dumb"] -> :none
      true -> :c16
    end
  end

  defp terminal_size do
    with {:ok, cols} <- :io.columns(), {:ok, rows} <- :io.rows() do
      {cols, rows}
    else
      _ -> {80, 24}
    end
  end
end
