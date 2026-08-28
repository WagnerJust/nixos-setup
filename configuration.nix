# Shared, host-agnostic system-level configuration.
# Per-machine settings live in hosts/<hostname>/; user-level packages and
# dotfiles live in home.nix.
{
  config,
  lib,
  pkgs,
  inputs,
  ...
}:

let
  # Mintplex-Labs/anything-llm — Desktop app packaged from the upstream
  # AppImage release. Not in nixpkgs (checked: no `anythingllm` / `anythingllm-desktop`
  # attrs). appimageTools.wrapType2 mounts the AppImage into an FHS-like
  # runtime so the bundled Chromium + Node stack starts on NixOS.
  # `--no-sandbox` is what upstream's .desktop ships — Chromium's SUID
  # sandbox depends on chrome-sandbox owning setuid-root, which AppImage
  # extraction on NixOS can't guarantee. Trade-off is documented; the
  # workspace itself still lives under $HOME.
  # Version bump: change `version`, run
  #   nix-prefetch-url --type sha256 <url>
  # and re-encode with `nix hash to-sri --type sha256 <hash>`.
  anythingllm-desktop =
    let
      pname = "anythingllm-desktop";
      version = "1.15.0";
      src = pkgs.fetchurl {
        url = "https://github.com/Mintplex-Labs/anything-llm/releases/download/v${version}/AnythingLLMDesktop.AppImage";
        hash = "sha256-Dk/FeGzefACiJlyTf+/BVc8ZJryF9Gq8BWxZqXeAacs=";
      };
      contents = pkgs.appimageTools.extractType2 { inherit pname version src; };
    in
    pkgs.appimageTools.wrapType2 {
      inherit pname version src;
      extraInstallCommands = ''
        install -Dm644 ${contents}/${pname}.desktop \
          $out/share/applications/${pname}.desktop
        substituteInPlace $out/share/applications/${pname}.desktop \
          --replace-fail 'Exec=AppRun' 'Exec=${pname}'
        install -Dm644 ${contents}/usr/share/icons/hicolor/0x0/apps/${pname}.png \
          $out/share/icons/hicolor/512x512/apps/${pname}.png
      '';
      meta = {
        description = "AnythingLLM — all-in-one local RAG / agent chat desktop app";
        homepage = "https://anythingllm.com/";
        license = lib.licenses.mit;
        platforms = [ "x86_64-linux" ];
        mainProgram = "anythingllm-desktop";
      };
    };
in
{
  ############################################################
  # Nix / nixpkgs
  ############################################################
  nix.settings.experimental-features = [
    "nix-command"
    "flakes"
  ];
  # Default download buffer is 1 MiB, which fills constantly on big builds
  # (first install, niri/noctalia/claude-code together). 256 MiB silences the
  # "download buffer is full" warnings without meaningful memory cost.
  nix.settings.download-buffer-size = 256 * 1024 * 1024;
  # Weekly GC keeps /nix/store bounded; the 30-day window preserves enough
  # rollback headroom for a bad kernel or flake bump.
  nix.gc = {
    automatic = true;
    dates = "weekly";
    options = "--delete-older-than 30d";
  };
  nixpkgs.config.allowUnfree = true; # lmstudio, typora, 1password, spotify
  system.stateVersion = "26.05";

  ############################################################
  # Boot — systemd-boot now; lanzaboote later (see SECURE BOOT)
  ############################################################
  boot.loader.systemd-boot.enable = true;
  # Cap /boot entries. Each generation writes a kernel + initrd + entry, so an
  # uncapped list eventually fills the ESP and nixos-rebuild switch dies
  # mid-activation. 10 is the shared default; a host with a small ESP should
  # lower it in its own module (justin-powerhouse forces 5 for a ~1 GB ESP).
  boot.loader.systemd-boot.configurationLimit = 10;
  boot.loader.efi.canTouchEfiVariables = true;
  boot.kernelPackages = pkgs.linuxPackages_latest; # newest AMD CPU/GPU support

  # FAT32 doesn't support Unix perms, so the ESP defaults to world-readable.
  # bootctl writes a kernel random-seed file in /boot/loader and (correctly)
  # complains: any local user could read the seed and learn things about the
  # kernel's entropy pool. Mount /boot with restrictive masks so files and
  # directories under the ESP are owner-only (root). Merges with the
  # /boot entry that nixos-generate-config wrote to hardware-configuration.nix.
  fileSystems."/boot".options = [
    "fmask=0077"
    "dmask=0077"
  ];

  ############################################################
  # Disk encryption + sleep
  #
  # Disk layout is per-host: hardware-configuration.nix carries the root LUKS
  # UUID, filesystems and swapDevices. No host currently hibernates, so
  # nothing here sets boot.resumeDevice.
  #
  # A host that DOES want hibernation needs persistent-key encrypted swap
  # sized >= RAM (random-key swap can't survive a reboot) and must set
  # boot.resumeDevice in its own module — see the LVM-on-LUKS appendix in
  # CLAUDE.md, which is the layout to install against for that.

  # Only consulted on a host where suspend-then-hibernate can actually run.
  # justin-powerhouse disables the sleep targets outright, so this is inert
  # there; it is kept for a future host that sleeps.
  systemd.sleep.settings.Sleep.HibernateDelaySec = 10800; # 3h

  # Laptop-era setting: no current host has a lid, so this never fires.
  # Retained as the sane default for a future laptop host.
  services.logind.settings.Login.HandleLidSwitch = "suspend-then-hibernate";

  ############################################################
  # SECURE BOOT (lanzaboote) — uncomment after install, see secure-boot.md
  ############################################################
  # environment.systemPackages = with pkgs; [ sbctl ]; # merge into the list below
  # boot.loader.systemd-boot.enable = lib.mkForce false;
  # boot.lanzaboote = {
  #   enable = true;
  #   pkiBundle = "/var/lib/sbctl";
  # };

  ############################################################
  # Power & firmware
  ############################################################
  services.fwupd.enable = true;
  # power-profiles-daemon rather than tlp. Originally a laptop choice; on a
  # mains-powered desktop neither does much, but ppd is what Noctalia's power
  # profile selector talks to, so it stays. The two conflict — never enable both.
  services.power-profiles-daemon.enable = true;
  services.tlp.enable = false;
  services.fstrim.enable = true;
  # UPower must be registered on the system bus for any consumer to read power
  # state; without it Noctalia logs `org.freedesktop.DBus.Error.ServiceUnknown`.
  # power-profiles-daemon doesn't pull it in on its own. On a desktop there is
  # no battery to report, so this is mostly inert.
  services.upower.enable = true;

  ############################################################
  # Audio (PipeWire)
  ############################################################
  security.rtkit.enable = true;
  services.pipewire = {
    enable = true;
    alsa.enable = true;
    pulse.enable = true;
    wireplumber.enable = true;
  };

  ############################################################
  # Locale + timezone
  # America/Denver follows MST/MDT (DST-aware). en_US.UTF-8 gives
  # imperial measurement units, US paper sizes, etc.
  ############################################################
  time.timeZone = "America/Denver";
  i18n.defaultLocale = "en_US.UTF-8";

  ############################################################
  # Networking, Bluetooth, fingerprint (see note on fprintd below)
  ############################################################
  # networking.hostName is set per-host in hosts/<hostname>/default.nix.
  networking.networkmanager.enable = true;
  services.tailscale.enable = true;
  # DNS via systemd-resolved instead of legacy resolvconf. Tailscale integrates
  # with resolved over D-Bus; under resolvconf the NetworkManager<->resolvconf
  # <->tailscaled handoff raced and tailscaled periodically had "no upstream
  # resolvers set" -> SERVFAIL on every lookup until a link change forced a
  # re-read (looked like "network connected but nothing works" after idle/lock).
  services.resolved.enable = true;
  hardware.bluetooth.enable = true;
  hardware.bluetooth.powerOnBoot = true;
  # Fingerprint auth. No current host has a reader, so fprintd runs with
  # nothing to talk to and the PAM hooks below fall straight through to a
  # password — harmless, but not doing anything either. Kept because the PAM
  # wiring interacts with Noctalia's lock screen (see the note below) and
  # removing it wants testing on a machine that can actually exercise the
  # lock path. On a host that does have a reader, enroll with `fprintd-enroll`.
  services.fprintd.enable = true;
  security.pam.services = {
    sudo.fprintAuth = true; # sudo prompt
    login.fprintAuth = true; # TTY login
    su.fprintAuth = true; # su to another user
    polkit-1.fprintAuth = true; # GUI privilege prompts (e.g. password change)
    greetd.fprintAuth = true; # noctalia-greeter at the login screen
    # Noctalia's lock screen uses /etc/pam.d/login, so login.fprintAuth above
    # is what lights up the lock screen's fingerprint path. In v5 the lock
    # screen's auth is native (C++): it arms pam_fprintd at lock time and
    # manages the fingerprint-vs-password handoff itself. The v4 QML flags that
    # used to gate this (`allowPasswordWithFprintd` / `autoStartAuth`, once
    # asserted by home.activation.noctaliaConfigSeed) no longer exist and are
    # not needed. Re-verify the touch-to-unlock path after any Noctalia bump —
    # this system-side fprintd wiring assumes Noctalia arms the reader for us.
  };

  ############################################################
  # niri + greetd (noctalia-greeter) login
  ############################################################
  programs.niri.enable = true;
  # niri-flake's `programs.niri.package` defaults to niri-stable (v25.08).
  # Pin to niri-unstable because Quickshell-based shells (Noctalia and the
  # ecosystem that shares its Wayland-protocol footprint) track niri's
  # latest, and the stable tag lags. Also disable the in-build cargo test
  # suite — those tests sometimes SIGABRT inside the Nix build sandbox
  # (filesystem assumptions that don't hold), even when the binary itself
  # works at runtime. We don't gain confidence by running niri's own tests
  # during our system build.
  programs.niri.package =
    (inputs.niri.packages.${pkgs.stdenv.hostPlatform.system}.niri-unstable).overrideAttrs
      (old: {
        doCheck = false;
      });

  # noctalia-greeter on tty1 — a Quickshell-based login screen that mirrors
  # Noctalia Shell's palette/wallpaper (imperative sync via Settings → Shell →
  # Security → Noctalia Greeter → Sync Now — see TODO.md). The greeter's
  # NixOS module sets services.greetd.enable + default_session.command with
  # mkDefault, so no explicit greetd block is needed here.
  #   - allow_empty_password: fprintd's PAM module answers the password
  #     prompt with an empty reply after a fingerprint match; without this
  #     the greeter rejects that reply as invalid credentials.
  #   - keyboard.layout: greeter runs before the session's input config, so
  #     the layout has to be told explicitly.
  programs.noctalia-greeter = {
    enable = true;
    settings = {
      auth.allow_empty_password = true;
      keyboard.layout = "us";
    };
  };

  # Polkit auth agent: defer to Noctalia's native polkit agent (enabled via
  # programs.noctalia.settings.shell.polkit_agent in home.nix) rather than
  # niri-flake's bundled polkit-kde-agent service. Two agents would race on the
  # org.freedesktop.PolicyKit1.AuthenticationAgent bus name; the upstream
  # plugin docs explicitly require the other agent to be disabled. Force
  # the unit off — niri-flake hard-codes `wantedBy = [ "niri.service" ]`
  # with no opt-out option, so this is the only knob.
  systemd.user.services.niri-flake-polkit.enable = lib.mkForce false;

  # Tear out GNOME left behind by the Calamares base install. Harmless
  # to keep on if you used the manual install path (nothing to disable).
  services.xserver.enable = false;
  services.displayManager.gdm.enable = false;
  services.desktopManager.gnome.enable = false;

  xdg.portal = {
    enable = true;
    extraPortals = with pkgs; [
      xdg-desktop-portal-gtk
      xdg-desktop-portal-gnome
    ];
  };

  services.gnome.gnome-keyring.enable = true;
  services.accounts-daemon.enable = true;
  programs.dconf.enable = true;

  ############################################################
  # Shell
  ############################################################
  programs.zsh.enable = true;
  environment.shells = [ pkgs.zsh ];

  ############################################################
  # Non-Nix dynamic binaries (mise / pre-built toolchains)
  #
  # mise downloads upstream pre-built binaries — node from nodejs.org,
  # go from go.dev, python from python-build-standalone — that are all
  # linked against /lib64/ld-linux-x86-64.so.2 and a handful of common
  # shared libraries. NixOS doesn't have an FHS, so without a shim those
  # binaries fail to launch with "No such file or directory" pointing at
  # the linker. `programs.nix-ld` installs a stub at the canonical linker
  # path and uses the `libraries` list as the search path for the .so
  # files those binaries dlopen at runtime.
  #
  # Scope is intentional: this is only for mise-managed toolchains.
  # Everything Nix-native (everything in pkgs / home.packages) ignores
  # nix-ld and resolves through the usual store paths.
  ############################################################
  programs.nix-ld = {
    enable = true;
    libraries = with pkgs; [
      stdenv.cc.cc.lib # libstdc++ / libgcc_s — node's V8, many node native modules
      zlib # python zlib, node zlib bindings, gzipped tarballs unpacked at runtime
      openssl # python _ssl, node tls
      libffi # python ctypes
      ncurses # python _curses, readline backend
      readline # python readline
      bzip2 # python _bz2
      xz # python _lzma
      sqlite # python sqlite3
    ];
  };

  ############################################################
  # 1Password (GUI + CLI + browser integration)
  ############################################################
  programs._1password.enable = true;
  programs._1password-gui = {
    enable = true;
    polkitPolicyOwners = [ "justin" ];
  };

  ############################################################
  # Chromium + auto-installed extensions
  ############################################################
  # `programs.chromium` only writes a managed-policy file under
  # /etc/chromium/policies — it does NOT install chromium. The package
  # itself still has to be added to environment.systemPackages below.
  # The policy pre-installs each extension ID at first launch and locks
  # installation, so the user can disable but not remove without
  # editing this file. One-time sign-in for each extension is still
  # required and lives in TODO.md.
  programs.chromium = {
    enable = true;
    extensions = [
      "aeblfdkhhhdcdjpifhhbdiojplfjncoa" # 1Password
      "cnjifjpddelmedmihgijeibhnjfabmlf" # Obsidian Web Clipper
      "ldjkgaaoikpmhmkelcgkgacicjfbofhh" # Instapaper
    ];
  };

  ############################################################
  # Containers + local LLM serving
  ############################################################
  virtualisation.docker = {
    enable = true;
    enableOnBoot = true;
    autoPrune.enable = true;
  };

  services.ollama = {
    enable = true;
    # ROCm build for AMD GPUs; switch to pkgs.ollama (cpu) or
    # pkgs.ollama-vulkan if rocm crashes. NOTE: justin-powerhouse sets
    # services.ollama.enable = lib.mkForce false and runs llama.cpp on the
    # RX 7900 XTX instead, so none of this block is live on that host.
    package = pkgs.ollama-rocm;
    # Pulled on first start by ollama-model-loader.service.
    loadModels = [
      "llama3.2"
      "gemma4:latest"
      "gpt-oss:20b"
      "lfm2.5-thinking"
    ];
  };

  ############################################################
  # User
  ############################################################
  users.users.justin = {
    isNormalUser = true;
    description = "Justin";
    shell = pkgs.zsh;
    extraGroups = [
      "wheel"
      "networkmanager"
      "docker"
      "video"
      "input"
    ];
  };

  ############################################################
  # System-wide GUI applications
  ############################################################
  environment.systemPackages = with pkgs; [
    _1password-gui
    anythingllm-desktop
    chromium
    discord
    firefox
    vivaldi
    vivaldi-ffmpeg-codecs
    localsend
    nautilus
    obsidian
    lmstudio
    rpi-imager
    slack
    signal-desktop
    spotify
    typora
    zed-editor
    zoom-us

    git
    curl
    wget
    unzip
    cryptsetup # handy for inspecting/managing the LUKS volume post-install
  ];

  ############################################################
  # Firmware blobs, fonts
  ############################################################
  hardware.enableRedistributableFirmware = true;
  fonts.packages = with pkgs; [
    nerd-fonts.jetbrains-mono
    noto-fonts
    noto-fonts-color-emoji
  ];
}
