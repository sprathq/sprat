defmodule Sprat.CLI.Voice do
  @moduledoc """
  `sprat voice setup`: what talking to the board needs, installed with the
  owner's say-so. sox and whisper.cpp come from Homebrew; the speech model
  (#{Sprat.Voice.model_mb()} MB, multilingual) is downloaded into Sprat's data
  directory. Nothing is installed or downloaded without a yes.
  """

  alias Sprat.Voice

  def setup do
    IO.puts("Voice: hold space on the board, speak, let go. Speech becomes text on this Mac.\n")
    tools()
    model()

    case Voice.check() do
      :ok ->
        IO.puts("\nReady. Open the board and hold space. The first time, macOS asks whether")
        IO.puts("your terminal may use the microphone: allow it.")

      {:missing, what} ->
        IO.puts("\nStill missing: " <> Enum.join(what, ", ") <> ".")
        exit({:shutdown, 1})
    end
  end

  defp tools do
    missing =
      [is_nil(Voice.recorder_bin()) && "sox", is_nil(Voice.whisper_bin()) && "whisper.cpp"]
      |> Enum.filter(& &1)

    cond do
      missing == [] ->
        IO.puts("✓ sox and whisper.cpp are installed")

      brew = System.find_executable("brew") ->
        cmd = "brew install " <> Enum.join(missing, " ")

        if yes?("Install #{Enum.join(missing, " and ")} with `#{cmd}`?") do
          {_, code} = System.cmd(brew, ["install" | missing], into: IO.stream(:stdio, :line))
          if code != 0, do: IO.puts("brew exited #{code}")
        end

      true ->
        IO.puts(
          "Install #{Enum.join(missing, " and ")} with your package manager, then run this again."
        )
    end
  end

  defp model do
    path = Voice.model_path()

    if File.exists?(path) do
      IO.puts("✓ the speech model is in #{path}")
    else
      if yes?(
           "Download the speech model (#{Voice.model_mb()} MB) from huggingface.co into #{Path.dirname(path)}?"
         ) do
        File.mkdir_p!(Path.dirname(path))
        tmp = path <> ".part"

        {_, code} =
          System.cmd("curl", ["-fL", "--progress-bar", "-o", tmp, Voice.model_url()],
            into: IO.stream(:stdio, :line),
            stderr_to_stdout: true
          )

        if code == 0, do: File.rename!(tmp, path), else: IO.puts("download failed (curl #{code})")
      end
    end
  end

  defp yes?(question) do
    case IO.gets(question <> " [y/N] ") do
      answer when is_binary(answer) -> String.downcase(String.trim(answer)) in ["y", "yes"]
      _ -> false
    end
  end
end
