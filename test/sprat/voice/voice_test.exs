defmodule Sprat.VoiceTest do
  use ExUnit.Case, async: true

  alias Sprat.Voice
  alias Sprat.Voice.{Intent, Recorder}
  alias Sprat.Terminal.Board.{Fixture, Keys, View}

  @now ~U[2026-11-23 14:02:00Z]

  defp board, do: View.new(Fixture.snapshot(@now))

  describe "the key-release protocol" do
    test "kitty key events and the support answer parse; plain keys are unchanged" do
      parse = fn bytes -> elem(Sprat.Terminal.Keys.feed(Sprat.Terminal.Keys.new(), bytes), 0) end
      assert [{:key, 32, [], :release}] = parse.("\e[32;1:3u")
      assert [{:key, 32, [], :repeat}] = parse.("\e[32;1:2u")
      assert [{:key, 32, [], :press}] = parse.("\e[32u")
      assert [{:key, 27, [], :press}] = parse.("\e[27u")
      assert [{:kitty_flags, 11}] = parse.("\e[?11u")
      assert [:shift_enter] = parse.("\e[13;2u")
      assert [{:char, " "}] = parse.(" ")
    end
  end

  describe "keys while talking" do
    test "space starts; let go stops; a held repeat or other keys do nothing; esc cancels" do
      assert {_, [:voice_start]} = Keys.handle(board(), {:char, " "})
      v = %{board() | voice: %{state: :listening, hint: ""}}
      assert {_, [:voice_stop]} = Keys.handle(v, {:key, 32, [], :release})
      assert {_, []} = Keys.handle(v, {:key, 32, [], :repeat})
      assert {_, [:voice_space]} = Keys.handle(v, {:char, " "})
      assert {_, [:voice_cancel]} = Keys.handle(v, :esc)
      assert {_, []} = Keys.handle(v, {:char, "q"})
    end

    test "space inside a message is a space" do
      {v, []} = Keys.handle(%{board() | screen: {:session, "cf-4b"}}, {:char, "h"})
      {v, []} = Keys.handle(v, {:char, " "})
      assert v.composer.composer.text == "h "
    end
  end

  describe "what a sentence means" do
    test "verbs become the keys they stand for" do
      assert {:keys, [{:char, "a"}]} = Intent.parse("Activity.", board())
      assert {:keys, [{:char, "?"}]} = Intent.parse("help", board())
      assert {:keys, [{:char, "f"}]} = Intent.parse("Send it!", board())
      assert {:keys, [:esc]} = Intent.parse("go back", board())
      assert {:keys, [:right]} = Intent.parse("next ticket", board())
    end

    test "open a project or a session by its words; talk to a project's live session" do
      assert {:open, {:project, "/Users/owner/Projects/cupful"}, "cupful"} =
               Intent.parse("Open Cupful.", board())

      assert {:open, {:session, "cf-4b"}, "cafe-networks-4b"} =
               Intent.parse("open cafe networks 4b", board())

      assert {:open, {:session, _}, _} = Intent.parse("talk to studio", board())
      assert {:unknown, _} = Intent.parse("open the pod bay doors", board())
      assert {:unknown, _} = Intent.parse("make me a sandwich", board())
    end

    test "names heard run together, split apart or slightly off still match" do
      assert {:open, {:project, "/Users/owner/Projects/dreamboard"}, _} =
               Intent.parse("open dream board", board())

      assert {:open, {:project, "/Users/owner/Projects/studio"}, "studio"} =
               Intent.parse("open-studioo", board())

      assert {:open, {:project, "/Users/owner/Projects/cupful"}, _} =
               Intent.parse("open cup full", board())

      assert {:unknown, _} = Intent.parse("open st", board())
    end

    test "whisper is told what to expect: the commands and every name on the board" do
      vocab = Intent.vocabulary(board())
      assert vocab =~ "Open, talk to, activity, help"
      assert vocab =~ "cupful"
      assert vocab =~ "cafe-networks-4b"
    end

    test "on a session's screen speech is what to say; send and cancel end it" do
      v = %{board() | screen: {:session, "cf-4b"}}

      assert {:dictate, "Keep network_id on members."} =
               Intent.parse(" Keep network_id on members. ", v)

      assert {:keys, [:esc]} = Intent.parse("cancel", v)
      {composing, []} = Keys.handle(v, {:paste, "keep it"})
      assert {:keys, [:enter]} = Intent.parse("Send.", composing)
    end
  end

  describe "speech to text" do
    test "whisper's output, without its markers" do
      assert Voice.clean(" Open Studio.\n\n[BLANK_AUDIO]\n (music playing)\n") == "Open Studio."
      assert Voice.clean("[BLANK_AUDIO]\n") == ""
    end

    test "transcribe runs whisper-cli on the file with the local model" do
      test = self()

      fake = fn bin, args, _opts ->
        send(test, {:ran, bin, args})
        {" open studio\n", 0}
      end

      assert {:ok, "open studio"} =
               Voice.transcribe("/tmp/x.wav",
                 cmd: fake,
                 whisper_bin: "whisper-cli",
                 model: "/m.bin"
               )

      assert_received {:ran, "whisper-cli",
                       ["-m", "/m.bin", "-f", "/tmp/x.wav", "-nt", "-np", "-l", "auto"]}

      Voice.transcribe("/tmp/x.wav",
        cmd: fake,
        whisper_bin: "whisper-cli",
        model: "/m.bin",
        prompt: "Open, studio.",
        language: "en"
      )

      assert_received {:ran, _,
                       [_, _, _, _, "-nt", "-np", "-l", "en", "--prompt", "Open, studio."]}

      assert {:error, "whisper-cli exit 1: " <> _} =
               Voice.transcribe("/tmp/x.wav",
                 cmd: fn _, _, _ -> {"bad", 1} end,
                 whisper_bin: "w",
                 model: "m"
               )
    end
  end

  describe "the recorder" do
    setup do
      dir = Path.join(System.tmp_dir!(), "rec#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)

      # Stands in for sox's `rec`: writes audio to its 8th argument until SIGINT.
      bin = Path.join(dir, "fake-rec")

      File.write!(bin, """
      #!/bin/sh
      trap 'exit 0' INT
      head -c 8000 /dev/zero > "$8"
      while true; do sleep 0.05; done
      """)

      File.chmod!(bin, 0o755)
      %{dir: dir, bin: bin}
    end

    test "stop keeps the recording; cancel deletes it", %{dir: dir, bin: bin} do
      path = Path.join(dir, "a.wav")
      {:ok, rec} = Recorder.start(path, bin: bin)
      wait_for_audio(path)
      assert {:ok, ^path} = Recorder.stop(rec)
      assert File.exists?(path)

      path2 = Path.join(dir, "b.wav")
      {:ok, rec2} = Recorder.start(path2, bin: bin)
      wait_for_audio(path2)
      assert :ok = Recorder.cancel(rec2)
      refute File.exists?(path2)
    end

    test "stopped before any sound: says nothing was recorded", %{dir: dir} do
      silent = Path.join(dir, "silent")
      File.write!(silent, "#!/bin/sh\ntrap 'exit 0' INT\nwhile true; do sleep 0.05; done\n")
      File.chmod!(silent, 0o755)
      {:ok, rec} = Recorder.start(Path.join(dir, "c.wav"), bin: silent)
      assert {:error, "nothing was recorded" <> _} = Recorder.stop(rec)
    end

    test "a recording still being written can be read so far: sizes set to what is there" do
      # rec writes a header with placeholder sizes until it stops.
      fmt =
        <<"fmt ", 16::little-32, 1::little-16, 1::little-16, 16_000::little-32, 32_000::little-32,
          2::little-16, 16::little-16>>

      samples = :binary.copy(<<1, 0>>, 9_000) <> <<7>>

      growing =
        <<"RIFF", 0xFFFFFFFF::little-32, "WAVE">> <> fmt <> <<"data", 0::little-32>> <> samples

      assert {:ok, wav} = Recorder.Wav.close(growing)

      assert <<"RIFF", riff::little-32, "WAVE", _::binary-size(24), "data", len::little-32,
               _::binary>> = wav

      assert len == 18_000, "whole samples only"
      assert riff == byte_size(wav) - 8
      assert byte_size(wav) == 44 + 18_000
      assert Recorder.Wav.close("not a wav") == :error
    end

    test "snapshot: under half a second is too short to transcribe", %{dir: dir, bin: bin} do
      path = Path.join(dir, "s.wav")
      {:ok, rec} = Recorder.start(path, bin: bin)
      wait_for_audio(path)
      # The stand-in writes zeros, not a WAV: nothing to read yet.
      assert Recorder.snapshot(rec, Path.join(dir, "p.wav")) == :too_short
      Recorder.cancel(rec)
    end

    test "no recorder installed: says how to get one" do
      assert {:error, "sox is not installed" <> _} = Recorder.start("/tmp/x.wav", bin: nil)
    end
  end

  defp wait_for_audio(path, tries \\ 200) do
    case File.stat(path) do
      {:ok, %{size: size}} when size > 3_200 -> :ok
      _ when tries > 0 -> Process.sleep(10) && wait_for_audio(path, tries - 1)
      _ -> flunk("the stand-in recorder wrote nothing")
    end
  end
end
