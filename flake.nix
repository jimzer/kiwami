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

      nixosConfigurations = {
        # Dev VM on the Mac: aarch64 so it runs natively under HVF.
        vm-aarch64 = mkHost "aarch64-linux" [ ./hosts/vm-aarch64 ];
      };
    };
}
