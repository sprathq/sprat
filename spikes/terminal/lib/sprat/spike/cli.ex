defmodule Sprat.Spike.CLI do
  @moduledoc """
  Escript entry point. `mix escript.build` then run the produced binary
  directly against a real TTY — see docs/phase0/03-terminal-spike.md for why
  `mix run` is not used here (it interferes with raw stdin).
  """

  alias Sprat.Spike.{Terminal, Input, Renderer, Sanitize}

  def main(args) do
    case args do
      ["demo" | rest] ->
        run_demo(rest)

      ["keys", log_path] ->
        run_keys(log_path)

      ["resize"] ->
        run_resize()

      ["permission"] ->
        run_permission()

      ["sanitize"] ->
        run_sanitize()

      ["crash"] ->
        run_crash()

      ["ttystate"] ->
        run_ttystate()

      ["sigwinch-probe"] ->
        run_sigwinch_probe()

      _ ->
        IO.puts(
          "usage: spike <demo|keys LOGFILE|resize|permission|sanitize|crash|sigwinch-probe|ttystate>"
        )
    end
  end

  # -- point 3/4/5/6/7: full inline demo -----------------------------------

  defp run_demo(rest) do
    seconds =
      case rest do
        [s] -> String.to_integer(s)
        _ -> String.to_integer(System.get_env("SPIKE_DEMO_SECONDS", "60"))
      end

    with_raw_terminal(fn ->
      {:ok, _} = Renderer.start_link(exit_notify: self())
      {:ok, _} = Input.start_link(Renderer)

      task = Task.async(Sprat.Spike.Demo, :run, [seconds])
      task_ref = task.ref

      exit_reason =
        receive do
          {:renderer_exit, reason} -> reason
          {:signal_exit, reason} -> reason
          {^task_ref, :done} -> :completed
        after
          seconds * 1000 + 2_000 -> :timeout
        end

      Task.shutdown(task, :brutal_kill)

      report = Renderer.latency_report()
      IO.write(:stderr, "\n")
      File.write!(report_path(), :erlang.term_to_binary(report) |> Base.encode64())
      IO.puts(:stderr, "keypress-to-echo latency: #{inspect(report)}")
      IO.puts(:stderr, "exit_reason=#{exit_reason}")
    end)
  end

  # -- point 1/2: raw key + paste parser, logged for tmux-driven assertions -

  defp run_keys(log_path) do
    File.write!(log_path, "")

    with_raw_terminal(fn ->
      {:ok, _} = Input.start_link(self())
      key_loop(log_path)
    end)
  end

  defp key_loop(log_path) do
    receive do
      {:input_event, :input_closed} ->
        :ok

      {:input_event, {:ctrl, "d"}} ->
        :ok

      {:input_event, event} ->
        File.write!(log_path, inspect(event) <> "\n", [:append])
        key_loop(log_path)
    after
      30_000 -> :timeout
    end
  end

  # -- point 5: resize polling + SIGWINCH probe ------------------------------

  defp run_resize do
    with_raw_terminal(fn ->
      probe = sigwinch_probe_result()
      IO.puts(:stderr, "sigwinch: #{inspect(probe)}")
      {:ok, _} = Renderer.start_link(checklist: [{"Resize test", :active}])
      {:ok, _} = Input.start_link(Renderer)
      poll_and_report(20)
    end)
  end

  defp poll_and_report(0), do: :ok

  defp poll_and_report(n) do
    %{cols: c, rows: r} = Renderer.snapshot()
    IO.puts(:stderr, "size=#{c}x#{r}")
    Process.sleep(500)
    poll_and_report(n - 1)
  end

  defp sigwinch_probe_result do
    :os.set_signal(:sigwinch, :handle)
  rescue
    e -> {:error, e}
  end

  defp run_sigwinch_probe do
    set_result = sigwinch_probe_result()
    IO.puts("os.set_signal(:sigwinch, :handle) => #{inspect(set_result)}")

    parent = self()

    trap_result =
      try do
        System.trap_signal(:sigwinch, :spike_probe, fn -> send(parent, :sigwinch_fired) end)
      rescue
        e -> {:unsupported, e}
      end

    IO.puts("System.trap_signal(:sigwinch, ...) => #{inspect(trap_result)}")

    case trap_result do
      {:ok, _} ->
        IO.puts("waiting up to 8s — resize this terminal / pane now")

        receive do
          :sigwinch_fired -> IO.puts("RESULT: SIGWINCH delivered and handled")
        after
          8_000 -> IO.puts("RESULT: trap installed but no SIGWINCH delivered in 8s")
        end

      _ ->
        IO.puts(
          "RESULT: SIGWINCH is not a trappable signal on this OTP (confirms poll-based resize)"
        )
    end
  end

  # -- point 7: numbered permission prompt -----------------------------------

  defp run_permission do
    with_raw_terminal(fn ->
      {:ok, _} = Renderer.start_link()
      {:ok, _} = Input.start_link(Renderer)

      Renderer.open_permission(
        "Fetch URL",
        [
          "Researcher·2 wants to fetch a URL it composed itself:",
          "  https://example.com/api?q=booking+software"
        ],
        [
          "Yes",
          "Yes, and allow example.com for this mission",
          "No, and tell the Researcher what to do instead"
        ]
      )

      wait_for_permission_choice(150)
    end)
  end

  defp wait_for_permission_choice(0), do: IO.puts(:stderr, "selected=timeout")

  defp wait_for_permission_choice(tries_left) do
    case Renderer.snapshot() do
      %{last_permission_choice: n} when not is_nil(n) ->
        IO.puts(:stderr, "selected=#{n}")

      _ ->
        Process.sleep(100)
        wait_for_permission_choice(tries_left - 1)
    end
  end

  # -- point 9: sanitiser --------------------------------------------------

  defp run_sanitize do
    input = IO.read(:stdio, :eof) |> to_string()
    IO.write(Sanitize.strip(input))
  end

  # -- point 8: crash inside the renderer must still restore the terminal --

  # Diagnostic only: are ISIG-generated signals (Ctrl+C -> SIGINT, Ctrl+\ ->
  # SIGQUIT) still live after :shell.start_interactive({:noshell, :raw}), or
  # does raw mode suppress them like `stty raw` does? Prints termios flags
  # while raw mode is active, then restores.
  defp run_ttystate do
    saved = Terminal.saved_stty()
    {:ok, _mode} = Terminal.enable_raw!()
    {out, _} = System.cmd("sh", ["-c", "stty -a < /dev/tty"], stderr_to_stdout: true)
    IO.puts(out)
    Terminal.restore!(saved)
  end

  defp run_crash do
    with_raw_terminal(fn ->
      {:ok, _} = Renderer.start_link()
      Renderer.set_verb("About to crash")
      Process.sleep(200)
      raise "simulated renderer crash"
    end)
  end

  # -- shared raw-mode lifecycle (point 8) -----------------------------------

  defp with_raw_terminal(fun) do
    saved = Terminal.saved_stty()
    {:ok, mode} = Terminal.enable_raw!()
    IO.puts(:stderr, "raw mode entered via #{inspect(mode)}")
    Terminal.install_exit_traps!(saved, self())

    try do
      fun.()
    rescue
      e ->
        Terminal.restore!(saved)
        IO.puts(:stderr, "crashed: #{Exception.message(e)} (terminal restored)")
        reraise e, __STACKTRACE__
    after
      Terminal.restore!(saved)
    end
  end

  defp report_path, do: Path.join(System.tmp_dir!(), "sprat_spike_latency.b64")
end
