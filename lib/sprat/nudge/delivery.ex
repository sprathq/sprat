defmodule Sprat.Nudge.Delivery do
  @moduledoc """
  Puts a `[sprat]` message into a live Claude Code session (spec-v4 §9.3,
  decided in `docs/phase-v4/00-spikes.md`).

  Adapters, in order: **cmux** (the session's pid mapped to its surface),
  **tmux** (the registry's `tmux` pane), **clipboard** (the owner pastes).

  The rule that makes typing into someone else's terminal safe: read the pane
  first and only type when the session's input prompt is empty and no dialog
  is open. A dialog swallows input, and text the owner has half-typed would be
  glued onto the message — both were seen in the Phase 0 spike. Anything else
  is `{:hold, reason}` and the caller retries later.

  Every external call goes through `opts[:cmd]` (default `Sprat.Cmd`, 5s deadline), so
  the decision logic is tested without a terminal.
  """

  alias Sprat.Observer.Model.Session

  @type result ::
          {:ok, :cmux | :tmux | :clipboard}
          | {:hold, atom()}
          | {:error, term()}

  @doc """
  Delivers `text` to `session`. `opts[:adapters]` limits/orders the adapters
  (default `[:cmux, :tmux]`); `:clipboard` is only used when listed, because
  copying is not delivery and the caller must say so to the owner.
  """
  @spec deliver(Session.t(), String.t(), keyword()) :: result()
  def deliver(%Session{} = session, text, opts \\ []) do
    adapters = Keyword.get(opts, :adapters, [:cmux, :tmux])
    line = flatten(text)

    Enum.reduce_while(adapters, {:error, :no_adapter}, fn adapter, acc ->
      case try_adapter(adapter, session, line, opts) do
        :unavailable -> {:cont, acc}
        result -> {:halt, result}
      end
    end)
  end

  @doc """
  One line, no characters a terminal or cmux would turn into keys: real
  newlines would submit early, and cmux turns the two-character sequences
  `\\n`, `\\r`, `\\t` into Enter/Tab.
  """
  @spec flatten(String.t()) :: String.t()
  def flatten(text) do
    text
    |> String.replace(~r/[\r\n\t]+/, " ")
    |> String.replace("\\", "⧵")
    |> String.replace(~r/[\x00-\x1f\x7f]/, "")
    |> String.replace(~r/ {2,}/, " ")
    |> String.trim()
  end

  @doc """
  Reads a captured pane (plain text, newest line last) and says whether the
  Claude Code input prompt is ready for a message.

  Returns `:ready`, `{:hold, :dialog}`, `{:hold, :owner_typing}` or
  `{:hold, :no_prompt}`.
  """
  @spec prompt_state(String.t()) :: :ready | {:hold, :dialog | :owner_typing | :no_prompt}
  def prompt_state(screen) do
    lines = screen |> String.split("\n") |> Enum.map(&String.trim_trailing/1)

    cond do
      dialog?(lines) ->
        {:hold, :dialog}

      true ->
        case lines |> Enum.reverse() |> Enum.find(&prompt_line?/1) do
          nil ->
            {:hold, :no_prompt}

          prompt ->
            if empty_prompt?(prompt), do: :ready, else: {:hold, :owner_typing}
        end
    end
  end

  # -- adapters ---------------------------------------------------------------

  defp try_adapter(:cmux, %Session{surface: nil}, _line, _opts), do: :unavailable

  defp try_adapter(:cmux, %Session{surface: surface}, line, opts) do
    case Sprat.Observer.Surfaces.cmux_bin() do
      nil ->
        :unavailable

      bin ->
        with {:ok, screen} <-
               run(bin, ["read-screen", "--surface", surface, "--lines", "40"], opts),
             :ready <- prompt_state(screen),
             {:ok, _} <- run(bin, ["send", "--surface", surface, line], opts),
             :ok <- pause(opts),
             {:ok, _} <- run(bin, ["send-key", "--surface", surface, "enter"], opts) do
          {:ok, :cmux}
        else
          {:hold, _} = hold -> hold
          {:error, reason} -> {:error, {:cmux, reason}}
        end
    end
  end

  defp try_adapter(:tmux, %Session{tmux: nil}, _line, _opts), do: :unavailable

  defp try_adapter(:tmux, %Session{tmux: pane}, line, opts) do
    with {:ok, screen} <- run("tmux", ["capture-pane", "-p", "-t", pane], opts),
         :ready <- prompt_state(screen),
         {:ok, _} <- run("tmux", ["send-keys", "-t", pane, "-l", line], opts),
         :ok <- pause(opts),
         {:ok, _} <- run("tmux", ["send-keys", "-t", pane, "Enter"], opts) do
      {:ok, :tmux}
    else
      {:hold, _} = hold -> hold
      {:error, reason} -> {:error, {:tmux, reason}}
    end
  end

  defp try_adapter(:clipboard, _session, line, opts) do
    case copy(line, opts) do
      :ok -> {:ok, :clipboard}
      {:error, reason} -> {:error, {:clipboard, reason}}
    end
  end

  defp try_adapter(_other, _session, _line, _opts), do: :unavailable

  @doc "Copies `text` to the system clipboard (macOS `pbcopy`)."
  @spec copy(String.t(), keyword()) :: :ok | {:error, term()}
  def copy(text, opts \\ []) do
    case Keyword.get(opts, :copy_fun) do
      nil ->
        port =
          Port.open({:spawn_executable, System.find_executable("pbcopy") || "/usr/bin/pbcopy"}, [
            :binary
          ])

        Port.command(port, text)
        Port.close(port)
        :ok

      fun ->
        fun.(text)
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  # -- screen reading ---------------------------------------------------------

  # Claude Code draws its input as a `❯` line between two rules. Option lists
  # in dialogs also use `❯` ("❯ 1. Yes"), so those are dialogs, not prompts.
  defp prompt_line?(line),
    do: String.starts_with?(String.trim_leading(line), "❯") and not option_line?(line)

  defp option_line?(line), do: Regex.match?(~r/^\s*❯\s*\d+\.\s/, line)

  defp empty_prompt?(line) do
    rest = line |> String.trim_leading() |> String.replace_prefix("❯", "") |> String.trim()
    # A fresh session shows a dim placeholder suggestion: `❯ Try "…"`.
    rest == "" or Regex.match?(~r/^Try ".*"$/, rest)
  end

  @dialog_markers [
    "Enter to confirm",
    "Esc to cancel",
    "Do you want to",
    "Would you like to",
    "(y/n)",
    "Press Enter to continue"
  ]

  defp dialog?(lines) do
    tail = Enum.take(lines, -15)

    Enum.any?(tail, &option_line?/1) or
      Enum.any?(tail, fn l -> Enum.any?(@dialog_markers, &String.contains?(l, &1)) end)
  end

  # -- plumbing ---------------------------------------------------------------

  defp run(bin, args, opts) do
    cmd = Keyword.get_lazy(opts, :cmd, fn -> Sprat.Cmd.with_timeout(5_000) end)

    case cmd.(bin, args, stderr_to_stdout: true) do
      {out, 0} -> {:ok, out}
      {out, code} -> {:error, {code, String.trim(out)}}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp pause(opts) do
    Process.sleep(Keyword.get(opts, :pause_ms, 300))
    :ok
  end
end
