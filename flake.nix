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
      nixosConfigurations = {
        # Dev VM on the Mac: aarch64 so it runs natively under HVF.
        vm-aarch64 = mkHost "aarch64-linux" [ ./hosts/vm-aarch64 ];
      };
    };
}
