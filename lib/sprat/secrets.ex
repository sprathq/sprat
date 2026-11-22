defmodule Sprat.Secrets do
  @moduledoc """
  Resolves the OpenAI API key (docs/spec-v1.md §7, owner decision #1) and
  keeps `Sprat.Store.Redact`'s secret set up to date so it can never reach a
  log, event payload, the database or the screen.

  Resolution order:

    1. `OPENAI_API_KEY` env var
    2. `.env` in the project root, or the nearest ancestor directory that
       has one (`KEY=value` lines only — no shell interpolation, no export,
       nothing written back)
    3. the OS credential store: macOS Keychain via `security`, Linux
       Secret Service via `secret-tool`

  Each source also reports itself so `sprat doctor` / `auth status` can say
  where the key came from without ever printing it — only `last4/1` is
  fit for display.
  """

  @service "sprat"
  @account "openai"

  @type source :: :env | {:dotenv, Path.t()} | :credential_store

  @doc """
  Resolves the key starting the search at `cwd` (defaults to
  `File.cwd!/0`). Returns `{:ok, key, source}` or `:error`.
  """
  def resolve(cwd \\ File.cwd!()) do
    with :error <- from_env(),
         :error <- from_dotenv(cwd),
         :error <- from_credential_store() do
      :error
    end
  end

  @persistent_key {__MODULE__, :redaction_set}

  @doc """
  Registers `key` in the process-wide redaction set consulted by
  `redaction_set/0`. Call once at startup with the resolved key, if any —
  every subsequent `Sprat.Store.Events.append/5` call that passes
  `Sprat.Secrets.redaction_set()` as its `secrets` argument then scrubs it
  from every payload before it touches disk. Uses `:persistent_term`
  rather than a process: this is written once at boot and read on every
  event append, the access pattern `:persistent_term` is for.
  """
  def register(nil), do: :ok

  def register(key) when is_binary(key) do
    :persistent_term.put(@persistent_key, [key | redaction_set()] |> Enum.uniq())
    :ok
  end

  @doc "The current redaction set: every secret registered via `register/1` so far. Pass this as `Sprat.Store.Events.append/5`'s `secrets` argument."
  def redaction_set, do: :persistent_term.get(@persistent_key, [])

  @doc "Last 4 characters of `key`, for display. Anything shorter is shown as `****`."
  def last4(key) when is_binary(key) and byte_size(key) >= 4,
    do: binary_part(key, byte_size(key) - 4, 4)

  def last4(_), do: "****"

  @doc "Human-readable label for a `source/0` value, for `doctor`/`auth status`."
  def describe_source(:env), do: "OPENAI_API_KEY environment variable"
  def describe_source({:dotenv, path}), do: ".env at #{path}"
  def describe_source(:credential_store), do: "OS credential store"

  # -- login / status, called by the CLI's `auth` subcommands -------------

  @doc "Stores `key` in the OS credential store. Returns `:ok` or `{:error, reason}`."
  def login(key) when is_binary(key) do
    case :os.type() do
      {:unix, :darwin} -> keychain_set(key)
      {:unix, _linux} -> secret_tool_set(key)
      other -> {:error, "unsupported platform: #{inspect(other)}"}
    end
  end

  @doc """
  `{:ok, %{present: boolean, source: source() | nil, last4: String.t() | nil}}`
  — never returns the key itself.
  """
  def status(cwd \\ File.cwd!()) do
    case resolve(cwd) do
      {:ok, key, source} -> {:ok, %{present: true, source: source, last4: last4(key)}}
      :error -> {:ok, %{present: false, source: nil, last4: nil}}
    end
  end

  @doc """
  Checks a `.env` file's permissions and git-ignore status
  (docs/PAUSE-adjacent owner note: "refuse to use a `.env` that is not
  ignored by git, or that is world- or group-readable"). Returns `:ok` or
  `{:warn, [String.t()]}` — never raises; used by `sprat doctor`.
  """
  def dotenv_safety(path) do
    warnings =
      []
      |> check_permissions(path)
      |> check_gitignored(path)

    if warnings == [], do: :ok, else: {:warn, warnings}
  end

  # -- env ------------------------------------------------------------------

  defp from_env do
    case System.get_env("OPENAI_API_KEY") do
      key when is_binary(key) and byte_size(key) > 0 -> {:ok, key, :env}
      _ -> :error
    end
  end

  # -- .env -------------------------------------------------------------------

  defp from_dotenv(cwd) do
    case find_dotenv(Path.expand(cwd)) do
      nil ->
        :error

      path ->
        case dotenv_get(path, "OPENAI_API_KEY") do
          nil -> :error
          key -> {:ok, key, {:dotenv, path}}
        end
    end
  end

  defp find_dotenv(dir) do
    candidate = Path.join(dir, ".env")
    parent = Path.dirname(dir)

    cond do
      File.regular?(candidate) -> candidate
      parent == dir -> nil
      true -> find_dotenv(parent)
    end
  end

  defp dotenv_get(path, key) do
    path
    |> File.read!()
    |> String.split("\n")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == "" or String.starts_with?(&1, "#")))
    |> Enum.find_value(fn line ->
      case String.split(line, "=", parts: 2) do
        [^key, value] -> unquote_value(value)
        _ -> nil
      end
    end)
  end

  defp unquote_value(value) do
    value = String.trim(value)

    case value do
      "\"" <> rest -> String.trim_trailing(rest, "\"")
      "'" <> rest -> String.trim_trailing(rest, "'")
      _ -> value
    end
  end

  defp check_permissions(warnings, path) do
    case File.stat(path) do
      {:ok, %File.Stat{mode: mode}} ->
        perms = Bitwise.band(mode, 0o777)

        if Bitwise.band(perms, 0o077) != 0 do
          [
            "#{path} is readable by group/other (mode #{Integer.to_string(perms, 8)}); run `chmod 600 #{path}`"
            | warnings
          ]
        else
          warnings
        end

      {:error, _} ->
        warnings
    end
  end

  defp check_gitignored(warnings, path) do
    dir = Path.dirname(path)

    case System.cmd("git", ["-C", dir, "check-ignore", "-q", path], stderr_to_stdout: true) do
      {_, 0} ->
        warnings

      {_, _} ->
        ["#{path} is not git-ignored; add it to .gitignore before it can be committed" | warnings]
    end
  rescue
    # git not installed / not a repo: nothing we can check, not a warning.
    ErlangError -> warnings
  end

  # -- credential store -------------------------------------------------------

  defp from_credential_store do
    case credential_store_get() do
      {:ok, key} -> {:ok, key, :credential_store}
      :error -> :error
    end
  end

  defp credential_store_get do
    case :os.type() do
      {:unix, :darwin} -> keychain_get()
      {:unix, _linux} -> secret_tool_get()
      _ -> :error
    end
  end

  defp keychain_get do
    case System.cmd("security", ["find-generic-password", "-s", @service, "-a", @account, "-w"],
           stderr_to_stdout: true
         ) do
      {out, 0} -> {:ok, String.trim(out)}
      {_, _} -> :error
    end
  rescue
    ErlangError -> :error
  end

  defp keychain_set(key) do
    # -U updates in place if an entry already exists, instead of erroring.
    case System.cmd(
           "security",
           ["add-generic-password", "-U", "-s", @service, "-a", @account, "-w", key],
           stderr_to_stdout: true
         ) do
      {_, 0} -> :ok
      {out, _} -> {:error, String.trim(out)}
    end
  rescue
    ErlangError -> {:error, "`security` not found"}
  end

  defp secret_tool_get do
    case System.cmd("secret-tool", ["lookup", "service", @service, "account", @account],
           stderr_to_stdout: true
         ) do
      {out, 0} when byte_size(out) > 0 -> {:ok, String.trim(out)}
      {_, _} -> :error
    end
  rescue
    ErlangError -> :error
  end

  defp secret_tool_set(key) do
    # secret-tool reads the secret from stdin, and System.cmd/3 has no way
    # to feed stdin (only capture stdout) — a raw Port gets us both.
    port =
      Port.open(
        {:spawn_executable, System.find_executable("secret-tool") || "/usr/bin/secret-tool"},
        [
          :binary,
          :exit_status,
          args: ["store", "--label=Sprat OpenAI key", "service", @service, "account", @account]
        ]
      )

    Port.command(port, key <> "\n")
    Port.close(port)
    :ok
  rescue
    ErlangError -> {:error, "`secret-tool` not found"}
  end
end
