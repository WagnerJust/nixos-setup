# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

A personal NixOS flake managing every machine the owner runs. It is the **source of truth** for each system — the running machine is a function of these files. The layout is multi-host: each machine is a directory under `hosts/`, and `flake.nix` discovers them automatically.

The only host is `justin-powerhouse`: an AMD Ryzen 7 5800X desktop (MSI MS-7C95) with a Radeon RX 7900 XTX (gfx1100), 32 GB RAM, and two NVMe drives, running niri + Noctalia (Quickshell) on an encrypted root. It is an **always-on box** — the sleep/suspend/hibernate systemd targets are disabled outright so it stays SSH-reachable and keeps serving LLMs while idle. The second NVMe is a bare whole-disk ext4 mounted at `/home/justin/models` (~645 GB of GGUF weights).

Most of the shared `configuration.nix` / `home.nix` is hardware-agnostic; a future machine slots in as a new `hosts/<name>/` without touching shared files.

> **Note:** this repo previously managed a Framework 13 AMD laptop, `sjr-fw13`, which was removed in commit `4c3e656`. Shared `configuration.nix` still carries settings that only made sense on that laptop — see *Laptop leftovers* below before trusting a comment in there.

The repo is built to be cloned onto a fresh machine from the NixOS live ISO and installed against. Each host's `hardware-configuration.nix` (generated per-machine by `nixos-generate-config`) is **committed** under `hosts/<hostname>/` — flakes only evaluate git-tracked files, and the LUKS UUIDs it carries are identifiers, not secrets. To stand up a new machine, run `scripts/new-host.sh` on it; see `hosts/README.md`.

## Commands

All builds go through the flake. Substitute `<host>` for the directory name under `hosts/` (currently `justin-powerhouse` — `nix flake show` lists every host the flake exposes).

```bash
# Rebuild and switch (the default verb after any edit)
sudo nixos-rebuild switch --flake .#<host>

# Test a change without making it the default boot generation
sudo nixos-rebuild test --flake .#<host>

# Build only, don't activate
sudo nixos-rebuild build --flake .#<host>

# Bump nixpkgs / niri / noctalia / claude-code-nix
nix flake update
# Or one input at a time (Nix 2.19+ positional arg; `--update-input` is deprecated)
nix flake update noctalia

# Roll back the last activation (pair with `git revert` to keep repo + system aligned)
sudo nixos-rebuild --rollback switch

# Check the flake evaluates and outputs are well-formed
nix flake check
```

There are no tests and no linter (yet). CI runs `nix flake check --no-build` plus an eval of every discovered host's system closure on every PR and push to `main` (see `.github/workflows/check.yml`). No stubbing is needed anymore — each host's `hardware-configuration.nix` is committed, so the flake evaluates in CI as-is (device paths are just strings; evaluation never touches disks). Locally, `nix fmt` runs nixfmt — formatting has not yet been applied to existing files, so the first run will produce a churn diff.

## Architecture

Shared, host-agnostic files in the repo root; per-machine state under `hosts/`:

- **`flake.nix`** — Inputs (nixpkgs unstable, home-manager, nixos-hardware, niri-flake, noctalia, claude-code-nix) and the `nixosConfigurations` output. It does **not** hardcode a host: an `mkHost` helper builds each machine from its `hosts/<name>/` directory plus the shared `configuration.nix` + `home.nix`, and `builtins.readDir ./hosts` auto-discovers every host (so adding a machine never touches `flake.nix`). All inputs `follows = "nixpkgs"` so there is one nixpkgs in the closure. The `lanzaboote` input is **commented out** by design — see *Secure Boot* below.
- **`configuration.nix`** — Shared system-level config: bootloader, PipeWire, networking, niri + greetd/tuigreet, Docker, Ollama (ROCm), the `sroberts` user, and the system-wide GUI apps (`_1password-gui`, `chromium`, `obsidian`, …). Host-agnostic — no hostname, no per-disk UUIDs. The function signature is `{ config, lib, pkgs, inputs, … }`.
- **`home.nix`** — User-level (home-manager): Noctalia config, niri input + binds, CLI/TUI tooling, zsh + integrations (zoxide, fzf, eza, bat, starship, mise), and `home.activation.*` hooks for the imperative gaps Nix can't declare (LazyVim starter, CyberChef download, post-install TODO.md). Shared across hosts.
- **`ghostty/common.conf`** — Ghostty settings shared with the owner's Mac (which is *not* Nix-managed): behaviour, zellij-style keybinds, font family. `home.nix` pulls it in via `config-file = "${./ghostty/common.conf}"` and the Mac's own config includes it by working-copy path. **Ghostty loads an included file *after* the file that references it, so `common.conf` overrides the including config** — which is why theme and font-size are deliberately absent from it and pinned per-host instead. Being referenced by store path, it must stay git-tracked, and edits need a rebuild to land on NixOS.
- **`hosts/<hostname>/`** — Everything machine-specific. `default.nix` sets `networking.hostName` and imports the `nixos-hardware` modules for that machine. `hardware-configuration.nix` (committed) encodes the root LUKS UUID, filesystems, and swapDevices. The only host today is `hosts/justin-powerhouse/`, which also carries `llama-power.nix` (a user service running a llama.cpp hot-swap proxy), the `/home/justin/models` mount, the SSH/authorized-keys block, and the `lib.mkForce` overrides that turn off Ollama and the sleep targets from shared config. See `hosts/README.md` and `scripts/new-host.sh` for adding one.

### Disk layout — two supported paths

**Default (Calamares install) — what `justin-powerhouse` actually uses:** ESP + LUKS-encrypted ext4 root, plus a swap partition. **Hibernation is deliberately not set up here.** Swap uses `randomEncryption.enable = true` (a fresh key every boot), which means no passphrase prompt at boot and no emergency-mode risk if an unlock is missed — but swap contents cannot survive a reboot, so there is no `boot.resumeDevice`. That is the right trade for an always-on desktop that never sleeps. No LVM in this layout.

The ESP is only ~1 GB (Calamares default) and every generation writes a kernel + initrd into it, so the host module caps `boot.loader.systemd-boot.configurationLimit` at 5 to keep `/boot` from filling up.

**Appendix (manual LVM-on-LUKS):**

```
nvme0n1p1  ESP (FAT32, unencrypted)
nvme0n1p2  LUKS2 → LVM "vg"
             vg/swap  92 GiB  (encrypted, holds hibernation image)
             vg/root  rest    (encrypted, ext4)
```

This path is for users who specifically want the LVM layout (multi-volume management, easier resize), **and it is the path to take if a future host needs hibernation** — which no current host does. It requires setting `boot.resumeDevice = "/dev/vg/swap"` in the host module (`hosts/<hostname>/default.nix`) before the install. The path is a stable LVM device, independent of `hardware-configuration.nix`. Hibernation needs persistent-key encrypted swap ≥ RAM, which is why swap lives *inside* LUKS rather than as the random-key swap partition `justin-powerhouse` uses.

The Calamares teardown lines in `configuration.nix` (`services.xserver.enable = false`, `services.displayManager.gdm.enable = false`, `services.desktopManager.gnome.enable = false`) are harmless on the manual path — they're disabling things that were never installed.

### niri + Noctalia wiring

System side enables `programs.niri` and `services.greetd` (tuigreet on tty1 launching `niri-session`). User side imports `inputs.noctalia.homeModules.default`, enables `programs.noctalia-shell`, and adds Noctalia to niri's `spawn-at-startup` so the shell launches with the compositor. Noctalia does **not** ship a greeter or a polkit agent — niri-flake's polkit user service is left at its default (enabled) to fill that gap, and tuigreet handles login.

The lock screen is Noctalia's own (its own PAM context, raised via `WlSessionLock`). **Noctalia does not subscribe to logind's `Lock` signal**, so `loginctl lock-session` is a no-op — locking must go through Noctalia's IPC (`noctalia-shell ipc call lockScreen lock`), which is what the `Super+Alt+L` bind and swayidle's `before-sleep` use. Media/brightness keybinds in `home.nix` still go through `wpctl`, `playerctl`, and `brightnessctl` (shell-agnostic).

Idle is driven by **Noctalia's own idle manager**, configured declaratively via `programs.noctalia.settings.idle.behavior`: a single named behavior, `lock`, at `timeout = 600` (10 min) running the internal action `noctalia:session lock`. **There is no auto-suspend behavior** — this box stays always-on and remotely reachable, and the sleep targets are masked at the host level anyway. **swayidle** (in `home.nix`) is kept only for its `before-sleep` hook, which locks via Noctalia's IPC ahead of a sleep Noctalia didn't initiate; with sleep disabled on this host that hook is effectively dormant, but it costs nothing and is correct for any future host that does sleep.

### Laptop leftovers in shared config

`sjr-fw13` was deleted (`4c3e656`) but shared `configuration.nix` was never cleaned up after it. These settings are still applied to a desktop that has no battery, no lid, and no fingerprint reader. None of them break the build, and most are inert — but **do not read their inline comments as a description of the current machine**:

| Setting | Comment claims | Reality on `justin-powerhouse` |
| --- | --- | --- |
| `services.logind.settings.Login.HandleLidSwitch = "suspend-then-hibernate"` | lid close escalates to hibernate | No lid. Dead config — the sleep targets are masked in the host module anyway. |
| `services.power-profiles-daemon.enable = true` / `services.tlp.enable = false` | "NOT tlp on Ryzen 7040", per Framework's recommendation | Ryzen 5800X desktop. The 7040 rationale doesn't apply; a mains-powered desktop arguably wants neither. |
| `services.fprintd.enable = true` + the PAM wiring | Goodix fingerprint reader | No fingerprint reader. `fprintd` runs with nothing to talk to. |
| `services.ollama` with `pkgs.ollama-rocm` | "Radeon 780M iGPU" | Overridden — the host sets `services.ollama.enable = lib.mkForce false` and runs llama.cpp on the RX 7900 XTX instead. The 780M comment refers to the laptop's iGPU. |

Cleaning these up is a real task, not just a doc fix: the fprintd PAM block interacts with Noctalia's lock screen, so removing it needs testing rather than a blind delete.

## Editing patterns

- **Adding a system-wide package**: append to `environment.systemPackages` in `configuration.nix`.
- **Adding a user CLI tool**: append to `home.packages` in `home.nix`. Prefer this over system packages unless the tool needs to be on PATH for other users or services.
- **Adding an imperative install step** (something not in nixpkgs): add a `home.activation.<name>` block in `home.nix` following the existing `cyberchef` / `lazyvimStarter` patterns — guard with an existence check so reruns are idempotent.
- **Changing terminal behaviour or keybinds**: edit `ghostty/common.conf`, not `programs.ghostty.settings` — the Mac reads the same file. Only theme/font-size stay in `home.nix`.
- **Bumping niri or Noctalia independently of nixpkgs**: `nix flake update niri` (or `noctalia`). The `--update-input` form on `nix flake lock` is deprecated since Nix 2.19.
- **Adding a new host**: run `scripts/new-host.sh` on the target machine (see `hosts/README.md`). It scaffolds `hosts/<name>/` and the flake auto-discovers it — no `flake.nix` edit. Anything machine-specific (hostname, `nixos-hardware` model module, swap/resume UUIDs, `hardware-configuration.nix`) goes in that directory; shared config stays in `configuration.nix` / `home.nix`.
- **`allowUnfree` is on** (`nixpkgs.config.allowUnfree = true`) for `lmstudio`, `typora`, `1password`. Unfree additions are fine.

## Secure Boot

Lanzaboote is a deliberate **post-install** step, not part of the initial build. The `lanzaboote` flake input and its module line in `flake.nix`, plus the `boot.lanzaboote` block in `configuration.nix`, are all commented out. Enabling them before keys are enrolled in the firmware will brick the boot. The full runbook is in `secure-boot.md`; touch those commented blocks only when following it.

The lanzaboote block uses `lib.mkForce` to override systemd-boot; `lib` is already in `configuration.nix`'s function arguments (`{ config, lib, pkgs, inputs, ... }`), so no signature change is needed.

## What's *not* declarative (by design)

Listed in `home.activation.todoMd` (the generated `~/TODO.md`): authenticating Claude Code, signing into 1Password / Gmail / GitHub / Slack / Discord / Signal / Zoom, setting wallpaper in Noctalia (its Material You-style theme derives from the wallpaper), Obsidian Sync, Typora license, Chromium extensions, `sudo fwupdmgr update`. These are credentials, account state, and firmware updates — not something Nix should own.

Also not declarative on this host: the **llama.cpp build itself**. `llama-power.nix` runs a hand-built HIP `llama-server` from `~/Src/llama.cpp/build-hip/bin`, built in the flake's `llama-rocm` devshell — it is not a Nix derivation, and it must be rebuilt after any `nix flake update` because its baked RPATH points at store paths that update will garbage-collect. The runbook is in `~/Side/powerhouse/docs/llama-power.md`, outside this repo. (`~/TODO.md` still mentions pulling Ollama models; Ollama is force-disabled on this host, so that line is stale.)

## Reference docs in this repo

- **`INSTALL.md`** — The install runbook: partition → encrypt → install → set up the working copy → verify. Includes the auth model (token for the clone, then build from the local path so Nix never sees the token), the "Stack at a glance" rationale table, known gotchas, and Arch+DankLinux migration notes. **Stale:** it is still written against the removed Framework 13 host (`sjr-fw13`) and its hibernation swap, so its hardware-specific values do not match `justin-powerhouse`. The overall shape (Calamares base → `scripts/new-host.sh` → `nixos-rebuild`) is still the template to follow.
- **`hosts/README.md`** — The per-host layout and the runbook for standing up a new machine with `scripts/new-host.sh` (deterministic config across different hardware).
- **`secure-boot.md`** — lanzaboote enrollment runbook (hardware-agnostic for the `sbctl` steps; Framework-specific BIOS quirks flagged inline), including optional TPM2 LUKS auto-unlock and recovery from a bricked boot.
