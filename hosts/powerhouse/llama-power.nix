# llama-power — llama.cpp hot-swap proxy for powerhouse.
#
# A single stable OpenAI-compatible endpoint on :80 that routes to and
# hot-swaps multiple llama-server backends. Architecture, config schema and
# runbook: ~/Side/powerhouse/docs/llama-power.md.
#
# NixOS wiring (this replaces the old CachyOS install.sh + ~/.config/systemd/user
# unit, which hardcoded /usr/bin/python3 and /usr/local/bin symlinks that do not
# exist here):
#
#   • Runs as a systemd *user* service (uid 1000). users.users.justin.linger
#     (set in the host default.nix) keeps the user manager — and this service —
#     alive after logout and starts it at boot, no login required.
#
#   • Python runtime is a pinned python3.withPackages env (there is no system
#     pip on NixOS). llama_power.py only imports fastapi / uvicorn / httpx / yaml.
#
#   • llama-server is hand-built against ROCm in the flake's `llama-rocm`
#     devshell (`nix develop /etc/nixos#llama-rocm`, then cmake as in
#     docs/llama-power.md). The build bakes a complete RPATH, so the binary runs
#     standalone; LLAMA_SERVER_BIN points at it. The ROCm runtime libs are also
#     placed on LD_LIBRARY_PATH below — both as a resolution fallback and, more
#     importantly, to keep nix-gc from collecting the exact store paths the
#     binary's RPATH depends on. After any `nix flake update`, rebuild llama.cpp
#     so its RPATH and these libs stay on the same nixpkgs revision.
#
#   • The proxy binds 0.0.0.0:80; the firewall opens 80 on the tailnet
#     interface only (not the LAN).
#
# The turboquant fork (turbo-llama-server, for turbo2/turbo3 KV variants) is not
# built yet — the xlam-4x32k / 6x21k / 8x16k / 128k roster entries stay
# unavailable until it is. Everything else works.
{ config, lib, pkgs, ... }:
let
  user = "justin";
  home = "/home/${user}";
  # The proxy program + its config run straight from the powerhouse clone on
  # this machine: deploy = `git pull` + restart, and an on-box roster edit shows
  # up in `git status` instead of drifting in a copy. The clone's working tree
  # is therefore live — a branch checked out there runs at the next restart.
  # Kept out of the nix store so editing the roster never needs a nixos-rebuild.
  powerDir = "${home}/Side/powerhouse/os/nixos-niri/programs";

  # Only these four are imported by llama_power.py.
  pythonEnv = pkgs.python3.withPackages (ps: with ps; [
    fastapi
    uvicorn
    httpx
    pyyaml
  ]);

  # Hand-built HIP llama.cpp (gfx1100). See the build steps in docs/llama-power.md.
  llamaBin = "${home}/Src/llama.cpp/build-hip/bin";

  # ROCm runtime libraries — resolution fallback + GC pin for the binary's RPATH.
  rocmLibs = lib.makeLibraryPath (with pkgs.rocmPackages; [
    clr
    hipblas
    rocblas
    rocm-runtime
  ]);
in
{
  # User-service persistence: survive logout, start at boot (replaces the old
  # `loginctl enable-linger` step from install.sh).
  users.users.${user}.linger = true;

  # Single proxy port, tailnet-only (clients reach it as http://powerhouse).
  networking.firewall.interfaces."tailscale0".allowedTCPPorts = [ 80 ];

  # HTTPS front door: https://powerhouse.tail0163a.ts.net → the proxy on :80.
  # Browsers only allow the web UI's mic in a secure context, so voice input
  # needs this; plain http://powerhouse keeps working for API clients.
  #
  # Not services.tailscale.serve — that nixpkgs module only configures
  # Tailscale *Services* (svc:<name>), not this node's own serve config.
  # Serve state lives in tailscaled; re-applying it each boot keeps a
  # rebuild-from-scratch from silently losing it. Needs MagicDNS + HTTPS
  # certificates enabled in the tailnet admin console (one-time, not
  # declarable). Retries until tailscaled is logged in and running.
  systemd.services.tailscale-serve-llama-power = {
    description = "tailscale serve: HTTPS → llama-power";
    wantedBy = [ "multi-user.target" ];
    after = [ "tailscaled.service" "network-online.target" ];
    wants = [ "tailscaled.service" "network-online.target" ];
    startLimitIntervalSec = 0;
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = "${config.services.tailscale.package}/bin/tailscale serve --bg --yes --https=443 http://127.0.0.1:80";
      Restart = "on-failure";
      RestartSec = 10;
    };
  };

  # The proxy is a *user* unit, so it can't be granted CAP_NET_BIND_SERVICE
  # (the user manager has no capabilities to hand out). Lowering the
  # unprivileged-port floor to 80 is what lets it bind :80. Single-user box.
  boot.kernel.sysctl."net.ipv4.ip_unprivileged_port_start" = 80;

  systemd.user.services.llama-power = {
    description = "llama-power proxy (llama.cpp hot-swap router)";
    wantedBy = [ "default.target" ];
    after = [ "network.target" ];

    environment = {
      LLAMA_SERVER_BIN = "${llamaBin}/llama-server";
      LLAMA_POWER_CONFIG = "${powerDir}/llama_power.yml";
      LLAMA_POWER_LOG = "${home}/llama-power.log";
      LLAMA_PROXY_PORT = "80";
      # Voice input in the web UI: the proxy transcribes recordings through
      # whisper-server (./whisper.nix) before they reach the model.
      WHISPER_URL = "http://127.0.0.1:8178";
      # Spoken replies: the proxy injects voice.js into the web UI and serves
      # /v1/audio/speech from tts-server (./tts.nix).
      TTS_URL = "http://127.0.0.1:8180";

      # llama-server globals inherited by every spawned backend (see the env
      # table in docs/llama-power.md).
      LLAMA_CACHE = "${home}/models";
      LLAMA_ARG_NUMA = "distribute";
      LLAMA_ARG_MMAP = "on";
      LLAMA_ARG_SPLIT_MODE = "layer";
      LLAMA_ARG_MAIN_GPU = "0";

      # NixOS gives user services a sensible default PATH (coreutils/grep/sed/
      # systemd), and llama-server is launched via the absolute LLAMA_SERVER_BIN,
      # so PATH needs nothing extra yet. When the turboquant fork lands, add:
      #   PATH = lib.mkForce "${llamaBin}:${turboBin}:<defaults>";
      # so the bare `turbo-llama-server` server-bin override resolves.
      LD_LIBRARY_PATH = rocmLibs;
      HOME = home;
    };

    serviceConfig = {
      Type = "simple";
      ExecStart = "${pythonEnv}/bin/python ${powerDir}/llama_power.py";
      WorkingDirectory = powerDir;
      StandardOutput = "append:${home}/llama-power-proxy.log";
      StandardError = "append:${home}/llama-power-proxy.log";

      # The proxy handles SIGTERM and stops its llama-server children; KillMode
      # mixed then sweeps anything left after the timeout.
      Restart = "no";
      KillMode = "mixed";
      KillSignal = "SIGTERM";
      TimeoutStopSec = 30;
    };
  };
}
