defmodule Sprat.Voice do
  @moduledoc """
  Talking to Sprat: hold space on the board, speak, let go.

  Speech becomes text on this Mac, never elsewhere: `rec` (sox) records the
  microphone to a temporary WAV, and `whisper-cli` (whisper.cpp) transcribes
  it with a local model. `sprat voice setup` installs what is missing, the
  model only after the owner says yes.

  On a session's screen the words go into the message line (dictation); on
  the board they are matched against a few commands (`Sprat.Voice.Intent`).
  """

  @model "ggml-base.bin"
  @model_url "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.bin"
  @model_mb 142

  def dir, do: Path.join(Sprat.Store.Paths.data_dir(), "voice")
  def model_path, do: Path.join(dir(), @model)
  def model_url, do: @model_url
  def model_mb, do: @model_mb

  @doc "The whisper.cpp binary, if installed."
  def whisper_bin, do: find("whisper-cli")

  @doc "sox's recorder, if installed."
  def recorder_bin, do: find("rec")

  defp find(name) do
    System.find_executable(name) ||
      Enum.find(["/opt/homebrew/bin/#{name}", "/usr/local/bin/#{name}"], &File.exists?/1)
  end

  @doc "`:ok`, or `{:missing, what}` naming what `sprat voice setup` would add."
  def check do
    missing =
      [
        is_nil(recorder_bin()) && "sox (records the microphone)",
        is_nil(whisper_bin()) && "whisper.cpp (turns speech into text)",
        not File.exists?(model_path()) && "the speech model (#{@model_mb} MB)"
      ]
      |> Enum.filter(& &1)

    if missing == [], do: :ok, else: {:missing, missing}
  end

  @doc """
  Transcribes a WAV file on this machine. `{:ok, text}` (possibly "" for
  silence) or `{:error, reason}`.
  """
  def transcribe(wav, opts \\ []) do
    run = Keyword.get(opts, :cmd, &Sprat.Cmd.run/3)
    bin = Keyword.get_lazy(opts, :whisper_bin, &whisper_bin/0)
    model = Keyword.get_lazy(opts, :model, &model_path/0)

    # A prompt naming what to expect (the board's commands, project and
    # session names) is how whisper learns words like "cupful".
    prompt = if p = opts[:prompt], do: ["--prompt", p], else: []

    args =
      ["-m", model, "-f", wav, "-nt", "-np", "-l", Keyword.get(opts, :language, "auto")] ++ prompt

    case bin && run.(bin, args, timeout: 60_000, stderr_to_stdout: false) do
      nil -> {:error, "whisper.cpp is not installed: run `sprat voice setup`"}
      {out, 0} -> {:ok, clean(out)}
      {_out, :timeout} -> {:error, "transcribing took too long"}
      {out, code} -> {:error, "whisper-cli exit #{code}: #{String.slice(out, 0, 160)}"}
    end
  end

  @doc false
  # whisper prints one line per segment, and markers for what isn't speech.
  def clean(out) do
    out
    |> String.split("\n")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join(" ")
    |> String.replace(~r/\[[A-Z_ ]+\]|\([^)]*(music|silence|noise)[^)]*\)/i, "")
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end
end
