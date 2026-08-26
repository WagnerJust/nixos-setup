# llama-power — llama.cpp hot-swap proxy for justin-powerhouse.
#
# A single stable OpenAI-compatible endpoint on :8080 that routes to and
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
#   • The proxy binds 0.0.0.0:8080; the firewall opens 8080 on the tailnet
#     interface only (not the LAN).
#
# The turboquant fork (turbo-llama-server, for turbo2/turbo3 KV variants) is not
# built yet — the xlam-4x32k / 6x21k / 8x16k / 128k roster entries stay
# unavailable until it is. Everything else works.
{ config, lib, pkgs, ... }:
let
  user = "justin";
  home = "/home/${user}";
  # The proxy program + its editable config are deployed copies under ~/models
  # (mirrors the original ~/Models layout). Source of truth is the powerhouse
  # repo (os/<target>/programs/llama_power.{py,yml}); deploy = copy into ~/models.
  # Kept as runtime files rather than nix-store paths so editing the roster and
  # running llama-power-restart never needs a nixos-rebuild.
  powerDir = "${home}/models";

  # Only these four are imported by deploy/programs/llama_power.py.
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

  # Single proxy port, tailnet-only (clients reach it as justin-powerhouse:8080).
  networking.firewall.interfaces."tailscale0".allowedTCPPorts = [ 8080 ];

  systemd.user.services.llama-power = {
    description = "llama-power proxy (llama.cpp hot-swap router)";
    wantedBy = [ "default.target" ];
    after = [ "network.target" ];

    environment = {
      LLAMA_SERVER_BIN = "${llamaBin}/llama-server";
      LLAMA_POWER_CONFIG = "${powerDir}/llama_power.yml";
      LLAMA_POWER_LOG = "${home}/llama-power.log";
      LLAMA_PROXY_PORT = "8080";

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
