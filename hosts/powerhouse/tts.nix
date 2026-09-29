# tts-server — Kokoro text-to-speech for spoken replies in the llama-power web UI.
#
# CPU-only via sherpa-onnx (ONNX runtime, no PyTorch), so the GPU's VRAM stays
# with the LLM. Loopback only: llama-power fronts it at /v1/audio/speech, and
# the voice.js it injects into the web UI calls that.
#
# The program runs from the powerhouse clone, like llama-power
# (os/nixos-niri/programs/tts_server.py). The model is a runtime file:
#   curl -sL https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models/kokoro-multi-lang-v1_0.tar.bz2 \
#     | tar xj -C ~/models/tts
#
# Measured here, 8 threads: fp32 ~0.5 s per sentence (~5x real time); the int8
# builds were ~5x slower on this CPU. v1.0 over v1.1: v1.1 is the -zh release
# with few English voices, at the same speed.
{ pkgs, ... }:
let
  home = "/home/justin";
  programs = "${home}/Side/powerhouse/os/nixos-niri/programs";
  pythonEnv = pkgs.python3.withPackages (ps: with ps; [
    sherpa-onnx
    numpy
    fastapi
    uvicorn
  ]);
in
{
  systemd.user.services.tts-server = {
    description = "Kokoro text-to-speech server (CPU, sherpa-onnx)";
    wantedBy = [ "default.target" ];
    after = [ "network.target" ];

    environment = {
      TTS_MODEL_DIR = "${home}/models/tts/kokoro-multi-lang-v1_0";
      TTS_SID = "13";        # picked by ear from the v1.0 speakers
      TTS_SPEED = "0.85";    # picked by ear; 1.0 was too fast
      TTS_THREADS = "8";     # 8 measured ~30% faster than 4
      TTS_PORT = "8180";
    };

    serviceConfig = {
      Type = "simple";
      ExecStart = "${pythonEnv}/bin/python ${programs}/tts_server.py";
      WorkingDirectory = programs;
      Restart = "on-failure";
      RestartSec = 5;
      # Synthesis competes with llama-server's CPU threads; let the LLM win.
      Nice = 5;
    };
  };
}
