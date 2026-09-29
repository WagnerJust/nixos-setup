# whisper-server — speech-to-text for voice chat in the llama-power web UI.
#
# CPU-only on purpose: the GPU's VRAM belongs to the LLM, the same reason the
# embedding model runs on CPU. nixpkgs' whisper-cpp builds only the CPU backend.
#
# Listens on loopback only. Browsers never reach it directly — llama-power
# fronts it (it swaps the UI's input_audio parts for transcripts), and the
# tailnet reaches llama-power through `tailscale serve` on HTTPS.
#
# The model is a runtime file under ~/models/whisper, like the LLM weights:
#   curl -L -o ~/models/whisper/ggml-small.en.bin \
#     https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small.en.bin
#
# Model and thread count were measured on this box (7.4 s clip, cold load):
# small.en 1.9 s at 8 threads, 2.0 s at 16 (SMT doesn't help);
# large-v3-turbo-q5_0 7.5 s — slower than real time, so not usable here.
#
# whisper-server's API is POST /inference (multipart: file, response_format…),
# not OpenAI's /v1/audio/transcriptions. It decodes and resamples WAV itself
# (48 kHz stereo verified); --convert would need ffmpeg and isn't used.
{ pkgs, ... }:
let
  home = "/home/justin";
in
{
  systemd.user.services.whisper-server = {
    description = "whisper.cpp speech-to-text server (CPU)";
    wantedBy = [ "default.target" ];
    after = [ "network.target" ];

    serviceConfig = {
      Type = "simple";
      ExecStart = builtins.concatStringsSep " " [
        "${pkgs.whisper-cpp}/bin/whisper-server"
        "--model ${home}/models/whisper/ggml-small.en.bin"
        "--threads 8"
        "--host 127.0.0.1"
        "--port 8178"
      ];
      WorkingDirectory = "${home}/models/whisper";
      Restart = "on-failure";
      RestartSec = 5;
      # Transcription competes with llama-server's CPU threads; let the LLM win.
      Nice = 5;
    };
  };
}
