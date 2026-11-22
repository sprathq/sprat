defmodule Sprat.Voice.Recorder do
  @moduledoc """
  Records the microphone to a WAV file with sox's `rec`: 16 kHz, mono,
  16-bit (what whisper.cpp wants), at most 60 seconds. `stop/1` lets `rec`
  finish the file (SIGINT); `cancel/1` also deletes it.

  The first recording makes macOS ask whether the terminal may use the
  microphone.
  """

  defstruct [:port, :os_pid, :path]

  @max_s 60

  def start(path, opts \\ []) do
    bin = Keyword.get_lazy(opts, :bin, &Sprat.Voice.recorder_bin/0)

    if is_nil(bin) do
      {:error, "sox is not installed: run `sprat voice setup`"}
    else
      File.mkdir_p!(Path.dirname(path))

      port =
        Port.open({:spawn_executable, bin}, [
          :binary,
          :exit_status,
          :stderr_to_stdout,
          args: ["-q", "-c", "1", "-r", "16000", "-b", "16", path, "trim", "0", "#{@max_s}"]
        ])

      {:os_pid, os_pid} = Port.info(port, :os_pid)
      {:ok, %__MODULE__{port: port, os_pid: os_pid, path: path}}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  @doc """
  Copies what has been recorded so far to `out`, as a WAV whisper can read
  while `rec` is still writing (its header's sizes are only right once it
  stops). `{:ok, out}`, or `:too_short` under half a second of audio.
  """
  def snapshot(%__MODULE__{path: path}, out) do
    with {:ok, bin} <- File.read(path),
         {:ok, wav} <- Sprat.Voice.Recorder.Wav.close(bin),
         true <- byte_size(wav) > 44 + 16_000 do
      File.write!(out, wav)
      {:ok, out}
    else
      _ -> :too_short
    end
  end

  @doc "Stops and keeps the recording. `{:ok, path}`, or `{:error, why}` when nothing was recorded."
  def stop(%__MODULE__{} = r) do
    finish(r)

    case File.stat(r.path) do
      # A WAV header alone is 44 bytes: nothing was heard.
      {:ok, %{size: size}} when size > 3_200 -> {:ok, r.path}
      _ -> {:error, "nothing was recorded (is the microphone allowed for this terminal?)"}
    end
  end

  def cancel(%__MODULE__{} = r) do
    finish(r)
    File.rm(r.path)
    :ok
  end

  defp finish(%__MODULE__{port: port, os_pid: os_pid}) do
    System.cmd("kill", ["-INT", Integer.to_string(os_pid)], stderr_to_stdout: true)

    receive do
      {^port, {:exit_status, _}} -> :ok
    after
      2_000 -> System.cmd("kill", ["-9", Integer.to_string(os_pid)], stderr_to_stdout: true)
    end

    flush(port)
  end

  defp flush(port) do
    receive do
      {^port, _} -> flush(port)
    after
      0 -> :ok
    end
  end

  defmodule Wav do
    @moduledoc false
    # A WAV still being written: its RIFF and data sizes set to what is there.

    def close(<<"RIFF", _size::little-32, "WAVE", rest::binary>> = bin) do
      case data_offset(rest, 12) do
        nil ->
          :error

        off ->
          # Whole 16-bit samples only.
          len = byte_size(bin) - (off + 8)
          len = len - rem(len, 2)
          <<head::binary-size(off + 4), _::little-32, data::binary-size(len), _::binary>> = bin
          <<"RIFF", _::little-32, after_riff::binary>> = head
          head = <<"RIFF", off + 8 + len - 8::little-32, after_riff::binary>>
          {:ok, head <> <<len::little-32>> <> data}
      end
    end

    def close(_), do: :error

    defp data_offset(<<"data", _::binary>>, at), do: at

    defp data_offset(<<_id::binary-size(4), size::little-32, rest::binary>>, at)
         when byte_size(rest) >= size do
      pad = rem(size, 2)

      case rest do
        <<_::binary-size(size + pad), more::binary>> -> data_offset(more, at + 8 + size + pad)
        _ -> nil
      end
    end

    defp data_offset(_, _), do: nil
  end
end
