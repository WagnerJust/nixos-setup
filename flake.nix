{
  description = "justin-powerhouse — NixOS + niri + Noctalia (AMD desktop, encrypted, ROCm)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    nixos-hardware.url = "github:NixOS/nixos-hardware/master";

    niri = {
      url = "github:sodiboo/niri-flake";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    noctalia = {
      # Pinned to the v5.0.0 beta tag (major bump from the v4 line). Beta: expect
      # schema/module changes vs 4.x — re-verify programs.noctalia options
      # and the seeded settings.json after bumping. Move to the stable v5.0.0 tag
      # once it ships.
      url = "github:noctalia-dev/noctalia-shell/v5.0.0-beta2";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # noctalia-greeter — greetd greeter that mirrors Noctalia Shell's look.
    # Tracks main (no tagged releases yet). Bump with `nix flake update
    # noctalia-greeter`.
    noctalia-greeter = {
      url = "github:noctalia-dev/noctalia-greeter";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    claude-code-nix = {
      url = "github:sadjow/claude-code-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # Terminal workspace manager for AI coding agents (panes, sessions
    # that survive detach). Tag-pinned to keep client + server in lockstep;
    # bump by editing the `v0.7.x` in the URL below (plain `nix flake
    # update herdr` won't move a tag-pinned ref).
    herdr = {
      url = "github:ogulcancelik/herdr/v0.7.1";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # WagnerJust/yt-transcript — YouTube transcripts (video, playlist, channel)
    # as one static Go binary. The repo is private, so this uses the ssh form
    # rather than the `github:` shorthand: the shorthand goes through the GitHub
    # API and would need an access token in nix.conf on every machine, while ssh
    # reuses the key that is already there. Bump with
    # `nix flake update yt-transcript`.
    yt-transcript = {
      url = "git+ssh://git@github.com/WagnerJust/yt-transcript.git";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # ── SECURE BOOT ────────────────────────────────────────────────
    # Uncomment to enable lanzaboote. Do this ONLY after the system is
    # installed and booting (see secure-boot.md). Enabling it before
    # enrolling keys will leave you unbootable if you flip Secure Boot on.
    # lanzaboote = {
    #   url = "github:nix-community/lanzaboote/v1.0.0";
    #   inputs.nixpkgs.follows = "nixpkgs";
    # };
  };

  outputs =
    {
      self,
      nixpkgs,
      home-manager,
      niri,
      noctalia,
      noctalia-greeter,
      claude-code-nix,
      herdr,
      ...
    }@inputs:
    let
      lib = nixpkgs.lib;

      # Every directory under ./hosts is a machine. Drop in a new
      # hosts/<hostname>/ (a default.nix + its hardware-configuration.nix) and
      # it becomes nixosConfigurations.<hostname> automatically — no edit to
      # this file. scripts/new-host.sh scaffolds one; see hosts/README.md.
      hostNames = builtins.attrNames (
        lib.filterAttrs (_: type: type == "directory") (builtins.readDir ./hosts)
      );

      # Shared system definition. Only the per-host module (./hosts/<name>)
      # carries machine-specific state (hardware-configuration.nix, hostname,
      # the nixos-hardware model module, swap/resume UUIDs); configuration.nix
      # and home.nix are identical on every host.
      mkHost =
        hostname:
        lib.nixosSystem {
          system = "x86_64-linux";
          specialArgs = { inherit inputs; };
          modules = [
            ./hosts/${hostname}
            ./configuration.nix

            niri.nixosModules.niri
            noctalia-greeter.nixosModules.default

            # ── SECURE BOOT ──
            # Uncomment together with the input in the inputs block and the
            # block in configuration.nix:
            # inputs.lanzaboote.nixosModules.lanzaboote

            home-manager.nixosModules.home-manager
            {
              home-manager.useGlobalPkgs = true;
              home-manager.useUserPackages = true;
              home-manager.extraSpecialArgs = { inherit inputs; };
              home-manager.users.justin = import ./home.nix;
            }
          ];
        };
    in
    {
      nixosConfigurations = lib.genAttrs hostNames mkHost;

      # `nix fmt` formats all .nix files in the tree. pkgs.nixfmt is the RFC 166
      # implementation that ships in nixpkgs; running it has not yet been
      # applied to existing files, so expect a churn diff on first run.
      formatter.x86_64-linux = nixpkgs.legacyPackages.x86_64-linux.nixfmt;

      # ROCm dev shell for building llama.cpp (or anything HIP) by hand against
      # the RX 7900 XTX (gfx1100). Enter with:  nix develop /etc/nixos#llama-rocm
      # Then clone whatever llama.cpp version and build with your own flags.
      devShells.x86_64-linux.llama-rocm =
        let
          pkgs = nixpkgs.legacyPackages.x86_64-linux;
          rocm = pkgs.rocmPackages;
        in
        pkgs.mkShell {
          packages = with pkgs; [
            cmake
            ninja
            git
            pkg-config
            rocm.clr
            rocm.hipblas
            rocm.rocblas
            rocm.rocminfo
            rocm.rocm-smi
          ];
          shellHook = ''
            export HIPCXX="${rocm.clr.hipClangPath}/clang++"
            export ROCM_PATH="${rocm.clr}"
            echo "ROCm llama.cpp dev shell — gfx1100 / RX 7900 XTX"
            echo "Example build:"
            echo "  cmake -B build -DGGML_HIP=ON -DCMAKE_HIP_COMPILER=$HIPCXX -DCMAKE_HIP_ARCHITECTURES=gfx1100 -DCMAKE_BUILD_TYPE=Release"
            echo "  cmake --build build -j"
          '';
        };
    };
}
