defmodule SpratSpike.Paths do
  @moduledoc """
  Platform app-data directory, following the layout in docs/spec-v1.md §13:
  `~/Library/Application Support/<app>` on macOS, `$XDG_DATA_HOME/<app>`
  (default `~/.local/share/<app>`) on Linux.
  """

  @app_name "sprat-spike"

  @doc "Returns the app data directory for this platform, creating it (mode 0700) if needed."
  def data_dir do
    dir = raw_data_dir()
    File.mkdir_p!(dir)
    File.chmod!(dir, 0o700)
    dir
  end

  defp raw_data_dir do
    case :os.type() do
      {:unix, :darwin} ->
        Path.join([System.user_home!(), "Library", "Application Support", @app_name])

      {:unix, _linux} ->
        base = System.get_env("XDG_DATA_HOME") || Path.join(System.user_home!(), ".local/share")
        Path.join(base, @app_name)

      other ->
        raise "unsupported platform: #{inspect(other)}"
    end
  end
end
