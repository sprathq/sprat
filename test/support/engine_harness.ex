defmodule Sprat.EngineHarness do
  @moduledoc """
  Drives the real `Sprat.Engine` against a fake machine for integration
  tests: a temp Claude config dir with transcripts written in Claude Code's
  record shapes, temp git repos with a superpowers plan, a fake registry, a
  controllable clock, and scripted PM / delivery / notify functions that
  report back to the test process.
  """

  import ExUnit.Assertions

  alias Sprat.Observer.Model.Session
  alias Sprat.Observer.Store

  @t0 ~U[2026-11-23 10:10:00Z]

  @plan """
  # Cafe Networks Implementation Plan

  **Goal:** Cafes share one loyalty balance.

  ### Task 1: Schema and migration

  - [x] **Step 1: Write the failing schema tests**
  - [x] **Step 2: Commit**

  ### Task 2: `Loyalty.Networks` context

  - [x] **Step 1: Write the failing tests**
  - [ ] **Step 2: Implement**

  ### Task 3: Deal resolution at member venues

  - [ ] **Step 1: Write the failing tests**

  ### Task 4: Full gate

  - [ ] **Step 1: Run `mix precommit`.**
  """

  def t0, do: @t0

  @doc "Sets up the temp dirs, store, clock, fakes, and the engine (not started ticking)."
  def start(opts \\ []) do
    tmp = Path.join(System.tmp_dir!(), "sprat-engine-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    ExUnit.Callbacks.on_exit(fn -> File.rm_rf!(tmp) end)

    cfg = Path.join(tmp, "claude")
    File.mkdir_p!(Path.join(cfg, "sessions"))

    {:ok, store} = Store.start_link(path: Path.join(tmp, "observer.db"), name: nil)
    ExUnit.Callbacks.on_exit(fn -> if Process.alive?(store), do: GenServer.stop(store) end)

    test = self()
    {:ok, clock} = Agent.start_link(fn -> @t0 end)
    {:ok, sessions} = Agent.start_link(fn -> [] end)
    {:ok, pm} = Agent.start_link(fn -> fn _ctx -> {:error, :not_scripted, %{}} end end)
    {:ok, deliver} = Agent.start_link(fn -> fn _s, _t -> {:ok, :cmux} end end)

    h = %{
      tmp: tmp,
      cfg: cfg,
      store: store,
      clock: clock,
      sessions: sessions,
      pm: pm,
      deliver: deliver,
      test: test
    }

    engine_opts =
      [
        store: store,
        config_dirs: [cfg],
        autostart: false,
        now_fun: fn -> Agent.get(clock, & &1) end,
        registry_fun: fn _dirs -> Agent.get(sessions, & &1) end,
        surfaces_fun: fn -> %{} end,
        pm_fun: fn ctx, _opts ->
          send(test, {:pm, ctx.finding.rule, ctx.finding.id})
          Agent.get(pm, & &1).(ctx)
        end,
        deliver_fun: fn s, text, _opts ->
          res = Agent.get(deliver, & &1).(s, text)
          send(test, {:deliver, s.session_id, text, res})
          res
        end,
        notify_fun: fn title, body -> send(test, {:notify, title, body}) end,
        background_fun: fn root, text, _opts ->
          send(test, {:background, root, text})
          :ok
        end
      ]
      |> Keyword.merge(opts)

    # spec-v5 processes mode: the observer tree publishes, the engine reads.
    if engine_opts[:observers] == :processes,
      do: ExUnit.Callbacks.start_supervised!({Sprat.Observer.Supervisor, engine_opts})

    {:ok, engine} = Sprat.Engine.start_link(Keyword.put(engine_opts, :name, nil))
    ExUnit.Callbacks.on_exit(fn -> if Process.alive?(engine), do: GenServer.stop(engine) end)
    Map.put(h, :engine, engine)
  end

  # -- the world ------------------------------------------------------------------

  @doc "A git repo with the plan committed; returns its resolved (realpath) root."
  def repo(h, name) do
    dir = Path.join(h.tmp, name)
    File.mkdir_p!(Path.join(dir, "docs/superpowers/plans"))
    File.write!(Path.join(dir, "docs/superpowers/plans/2026-11-20-cafe.md"), @plan)
    git(dir, ["init", "-q", "-b", "main"])
    git(dir, ["add", "."])

    git(dir, ["-c", "user.email=t@t", "-c", "user.name=t", "commit", "-qm", "Add the plan"],
      env: [
        {"GIT_AUTHOR_DATE", "2026-11-20T09:00:00Z"},
        {"GIT_COMMITTER_DATE", "2026-11-20T09:00:00Z"}
      ]
    )

    dir |> git(["rev-parse", "--show-toplevel"]) |> String.trim()
  end

  defp git(dir, args, opts \\ []) do
    {out, 0} = System.cmd("git", ["-C", dir | args], Keyword.put(opts, :stderr_to_stdout, true))
    out
  end

  @doc "Registers a live session in the fake registry (replacing one with the same id)."
  def session(h, sid, root, attrs \\ []) do
    s =
      struct(
        %Session{
          session_id: sid,
          config_dir: Keyword.get(attrs, :config_dir, h.cfg),
          pid: :erlang.phash2(sid),
          live?: true,
          status: :busy,
          status_since: @t0,
          cwd: root,
          name: "agent-" <> String.slice(sid, 0, 4)
        },
        attrs
      )

    Agent.update(h.sessions, fn list ->
      Enum.reject(list, &(&1.session_id == sid)) ++ [s]
    end)

    File.mkdir_p!(Path.join(s.config_dir, "sessions"))
    s
  end

  @doc "Appends transcript records for a session under its config dir."
  def append(h, sid, records, config_dir \\ nil) do
    dir = Path.join([config_dir || h.cfg, "projects", "-tmp-project"])
    File.mkdir_p!(dir)
    lines = Enum.map_join(records, "", &(JSON.encode!(&1) <> "\n"))
    File.write!(Path.join(dir, sid <> ".jsonl"), lines, [:append])
  end

  # -- transcript records (Claude Code's shapes, `golden.jsonl`) -----------------------

  defp rec(type, at, extra) do
    Map.merge(
      %{
        "type" => type,
        "timestamp" => DateTime.to_iso8601(at),
        "isSidechain" => false,
        "userType" => "external",
        "gitBranch" => "main",
        "version" => "2.1.330",
        "uuid" => "u-" <> Integer.to_string(System.unique_integer([:positive]))
      },
      extra
    )
  end

  def user(at, text), do: rec("user", at, %{"message" => %{"role" => "user", "content" => text}})

  def say(at, text),
    do:
      rec("assistant", at, %{
        "message" => %{"role" => "assistant", "content" => [%{"type" => "text", "text" => text}]}
      })

  def bash(at, id, command),
    do:
      rec("assistant", at, %{
        "message" => %{
          "role" => "assistant",
          "content" => [
            %{
              "type" => "tool_use",
              "id" => id,
              "name" => "Bash",
              "input" => %{"command" => command}
            }
          ]
        }
      })

  def result(at, id, text, error?),
    do:
      rec("user", at, %{
        "message" => %{
          "role" => "user",
          "content" => [
            %{
              "tool_use_id" => id,
              "type" => "tool_result",
              "content" => text,
              "is_error" => error?
            }
          ]
        }
      })

  def limit(at, text),
    do:
      rec("assistant", at, %{
        "isApiErrorMessage" => true,
        "apiErrorStatus" => 429,
        "error" => "rate_limit",
        "message" => %{"role" => "assistant", "content" => [%{"type" => "text", "text" => text}]}
      })

  @doc "Three identical failing `mix test` runs a minute apart, starting at `at` (an L1 loop)."
  def error_loop(at, prefix \\ "t") do
    [user(DateTime.add(at, -300), "Fix the networks context please")] ++
      Enum.flat_map(0..2, fn i ->
        t = DateTime.add(at, i * 60)
        id = "#{prefix}#{i}"

        [
          bash(t, id, "mix test test/networks_test.exs"),
          result(
            DateTime.add(t, 5),
            id,
            "Exit code 2\n** (CompileError) lib/networks.ex:#{12 + i}: undefined function bar/0",
            true
          )
        ]
      end)
  end

  # -- driving ----------------------------------------------------------------------

  def set_now(h, %DateTime{} = at), do: Agent.update(h.clock, fn _ -> at end)
  def advance(h, seconds), do: Agent.update(h.clock, &DateTime.add(&1, seconds))
  def now(h), do: Agent.get(h.clock, & &1)

  def pm(h, fun), do: Agent.update(h.pm, fn _ -> fun end)
  def deliveries(h, fun), do: Agent.update(h.deliver, fn _ -> fun end)

  @doc "One forced tick, then waits for any PM runs it started to be acted on."
  def tick(h) do
    :ok = Sprat.Engine.refresh(h.engine)
    settle(h)
  end

  def settle(h, tries \\ 200) do
    st = :sys.get_state(h.engine)

    cond do
      st.pm_running == %{} and not Sprat.Engine.Jobs.running?(st) ->
        st

      tries == 0 ->
        flunk(
          "PM runs or jobs did not finish: #{inspect(Map.keys(st.pm_running))} " <>
            inspect(for {id, %{status: :running}} <- st.jobs, do: id)
        )

      true ->
        Process.sleep(10)
        settle(h, tries - 1)
    end
  end

  def state(h), do: :sys.get_state(h.engine)
  def snapshot(h), do: Sprat.Engine.snapshot(h.engine)
  def command(h, cmd), do: Sprat.Engine.command(h.engine, cmd)

  @doc "Runs a command and waits for any job it started; returns the reply and the jobs."
  def command_and_settle(h, cmd) do
    reply = command(h, cmd)
    st = settle(h)
    {reply, st.jobs |> Map.values() |> Enum.sort_by(& &1.id)}
  end

  def finding(h, rule, sid \\ nil) do
    h
    |> state()
    |> Map.get(:findings)
    |> Map.values()
    |> Enum.find(&(&1.rule == rule and (is_nil(sid) or &1.session_id == sid)))
  end

  def ticket(h, id), do: h |> snapshot() |> Map.get(:tickets) |> Enum.find(&(&1.id == id))
end
