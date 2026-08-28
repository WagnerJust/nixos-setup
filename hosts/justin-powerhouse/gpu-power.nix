# GPU power management for justin-powerhouse — AMD Radeon RX 7900 XTX (gfx1100).
#
# Ports the tuned profile stack from the machine's previous CachyOS install.
# Three pieces, switched together by the `pwrh-mode` menu in home.nix:
#
#   GPU     LACT profiles (Daily / Gaming / AI) — power cap, fan curve,
#           performance level. The profiles in ./lact-config.yaml are the ones
#           dialed in on CachyOS, carried over unchanged.
#   CPU     power-profiles-daemon. Already enabled in the shared
#           configuration.nix, where it is described as a Framework leftover —
#           it is NOT dead config on this host, it is the CPU half of the mode
#           switch. The 5800X runs the amd-pstate-epp driver, so ppd drives
#           governor + energy_performance_preference together and exposes
#           power-saver / balanced / performance over polkit. That replaces
#           CachyOS's hand-written sysfs loops (and the ananicy-cpp pause they
#           needed), which is why none of that came across.
#   Monitor niri, driven from the menu — see pwrhMode in home.nix.
{ config, lib, pkgs, ... }:
{
  # OverDrive. Without this the amdgpu driver never creates pp_od_clk_voltage
  # and clamps power1_cap_max to the stock 303 W, so LACT can set neither the
  # fan curve nor the AI profile's 402 W cap — the ceiling is firmware, not
  # policy. This is exactly the `amdgpu.ppfeaturemask=0xffffffff` that lived in
  # /etc/default/limine on CachyOS.
  #
  # The nixpkgs default mask is 0xfffd7fff, which withholds one feature bit that
  # can cause flicker on some panels. 0xffffffff is what this card ran under for
  # months, so it is what we use; drop to the default if flicker ever appears.
  #
  # Requires a reboot — a kernel parameter cannot be applied by `switch`.
  hardware.amdgpu.overdrive = {
    enable = true;
    ppfeaturemask = "0xffffffff";
  };

  services.lact.enable = true;

  # NOT services.lact.settings. That option writes /etc/lact/config.yaml as a
  # read-only store symlink, and LACT persists the active profile by writing
  # `current_profile` back into that same file — so a declarative config would
  # make `lact cli profile set` (and every GUI edit) fail. Seed it instead:
  # tmpfiles `C` copies the file only when it does not already exist, so LACT
  # owns the live copy and the repo keeps the canonical one.
  #
  # To re-apply edits made here: `sudo rm /etc/lact/config.yaml` then rebuild.
  # To capture edits made in the LACT GUI: copy /etc/lact/config.yaml back over
  # hosts/justin-powerhouse/lact-config.yaml and commit.
  systemd.tmpfiles.rules = [
    "C /etc/lact/config.yaml 0644 root root - ${./lact-config.yaml}"
  ];

  # LACT's daemon authorises by group; `admin_group: wheel` in the config above
  # is why `lact cli` needs no sudo here. justin is already in wheel.
}
