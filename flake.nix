{
  description = "Kiwami — a personal NixOS desktop";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";

    home-manager = {
      url = "github:nix-community/home-manager/release-26.05";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # The desktop shell. Pinned deliberately: Quickshell is alpha and ships
    # breaking QML API changes, so it must move when we say so, not when a
    # distro packager pushes.
    quickshell = {
      url = "github:quickshell-mirror/quickshell";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, home-manager, ... }@inputs:
    let
      systems = [ "aarch64-linux" "x86_64-linux" "aarch64-darwin" ];
      forAllSystems = f:
        nixpkgs.lib.genAttrs systems (s: f nixpkgs.legacyPackages.${s});

      mkHost = system: modules:
        nixpkgs.lib.nixosSystem {
          inherit system;
          # Makes every flake input reachable inside modules as `inputs.*`.
          specialArgs = { inherit inputs; };
          modules = modules ++ [
            # Set here rather than in a shared module: nixosTest supplies its
            # own pkgs instance and rejects a config being set from inside.
            { nixpkgs.config.allowUnfree = true; }
            home-manager.nixosModules.home-manager
            {
              home-manager.useGlobalPkgs = true;
              home-manager.useUserPackages = true;
              home-manager.extraSpecialArgs = { inherit inputs; };
            }
          ];
        };
    in
    {
      # The kiwami CLI. Built once here and consumed by the hosts below, so the
      # binary that ships on an image is the same one `nix run` gives you.
      packages = forAllSystems (pkgs: rec {
        kiwami = pkgs.rustPlatform.buildRustPackage {
          pname = "kiwami";
          version = "0.1.0";
          src = ./cli;
          cargoLock.lockFile = ./cli/Cargo.lock;
          meta.mainProgram = "kiwami";

          nativeBuildInputs = [ pkgs.makeWrapper ];
          # `kiwami install` shells out to these. On the installer ISO they
          # happen to be present; everywhere else they are not, and the
          # installer would fail partway through with "command not found"
          # after it had already started writing. Carry them explicitly.
          postInstall = ''
            wrapProgram $out/bin/kiwami --prefix PATH : ${pkgs.lib.makeBinPath (with pkgs; [
              parted
              dosfstools      # mkfs.fat
              e2fsprogs       # mkfs.ext4
              util-linux      # mount
              systemd         # udevadm
            ])}
          '';
        };
        default = kiwami;
      });

      # Boots the desktop stack in a real VM and asserts it comes up. Linux
      # only: nixosTest needs a Linux builder, which is exactly why this runs
      # in CI rather than on the Mac.
      checks = forAllSystems (pkgs:
        pkgs.lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
          desktop = pkgs.testers.nixosTest {
            name = "kiwami-desktop";

            nodes.machine = { ... }: {
              # common.nix takes `inputs` to reach the kiwami package; the
              # test framework does not thread specialArgs through for us.
              _module.args.inputs = inputs;
              imports = [
                home-manager.nixosModules.home-manager
                ./modules/common.nix
                ./modules/desktop.nix
              ];
              home-manager.useGlobalPkgs = true;
              home-manager.useUserPackages = true;
              home-manager.extraSpecialArgs = { inherit inputs; };
              home-manager.users.nixos = {
                imports = [ ./modules/home/shell.nix ];
                home.stateVersion = "26.05";
              };
              users.users.nixos.initialPassword = "kiwami";
              virtualisation.memorySize = 4096;
              virtualisation.cores = 2;
              virtualisation.qemu.options = [ "-vga virtio" ];
            };

            testScript = ''
              machine.wait_for_unit("multi-user.target")

              # greetd autologins straight into Hyprland through uwsm.
              machine.wait_for_unit("greetd.service")
              machine.wait_until_succeeds("pgrep -f 'bin/Hyprland'", timeout=120)

              # The shell is a user unit gated on WAYLAND_DISPLAY, so its
              # running at all proves uwsm activated graphical-session.target
              # and exported the environment.
              machine.wait_until_succeeds("pgrep -f 'quickshell -p'", timeout=120)

              machine.succeed("su nixos -c 'XDG_RUNTIME_DIR=/run/user/1000 kiwami theme list' | grep -q kiwami")
              machine.screenshot("desktop")
            '';
          };
        });

      nixosConfigurations = {
        # Dev VM on the Mac: aarch64 so it runs natively under HVF.
        vm-aarch64 = mkHost "aarch64-linux" [ ./hosts/vm-aarch64 ];

        # Same desktop on x86_64. Nothing runs this interactively; it exists so
        # CI builds and boots the architecture the real machine will use.
        vm-x86_64 = mkHost "x86_64-linux" [ ./hosts/vm-x86_64 ];
      };
    };
}
