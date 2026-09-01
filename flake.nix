{
  description = "Kiwami — a personal NixOS desktop";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";

    home-manager = {
      url = "github:nix-community/home-manager/release-26.05";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # Declarative disk layout. The installer writes a disk.nix per machine and
    # disko both formats from it and derives fileSystems, so the layout is
    # stated once instead of once in Rust and once in Nix.
    disko = {
      url = "github:nix-community/disko";
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

      # No `system` argument: every host's hardware.nix sets
      # nixpkgs.hostPlatform, which is where nixosSystem takes it from. Saying
      # it twice means a machine whose architecture can disagree with its own
      # hardware description.
      mkHost = modules:
        nixpkgs.lib.nixosSystem {
          # Makes every flake input reachable inside modules as `inputs.*`.
          specialArgs = { inherit inputs; };
          modules = modules ++ [
            # Our own hosts are built from the same module we export, so
            # anything that breaks for a consumer breaks for us first.
            self.nixosModules.default
            inputs.disko.nixosModules.disko
            # Set here rather than in a shared module: nixosTest supplies its
            # own pkgs instance and rejects a config being set from inside.
            { nixpkgs.config.allowUnfree = true; }
          ];
        };

      # Every directory under hosts/ is a machine. Adding one is creating a
      # folder and `git add`-ing it - there is no second list to keep in sync,
      # which matters because `kiwami install` scaffolds these directories and
      # nothing should have to edit this file to register them.
      hostNames = builtins.attrNames
        (nixpkgs.lib.filterAttrs (_: t: t == "directory") (builtins.readDir ./hosts));
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
          #
          # parted, mkfs and mount are gone: disko's generated script carries
          # its own dependencies, so the installer runs none of them itself.
          #
          # nmcli is deliberately NOT here. It is a client for a running
          # NetworkManager daemon, so bundling it would add NM's whole closure
          # to every desktop for a binary that is useless without the service
          # - and a bundled client can skew from the daemon it talks to.
          # `kiwami net` looks it up on PATH and says so when it is missing.
          postInstall = ''
            wrapProgram $out/bin/kiwami --prefix PATH : ${pkgs.lib.makeBinPath (with pkgs; [
              curl            # the "am I online" probe
              git             # staging the generated hardware.nix
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
                ./modules/options.nix
                ./modules/themes.nix
                ./modules/generated.nix
              ];
              home-manager.useGlobalPkgs = true;
              home-manager.useUserPackages = true;
              home-manager.extraSpecialArgs = { inherit inputs; };
              home-manager.users.nixos = {
                imports = [
                  ./modules/home/configs.nix
                  ./modules/home/shell.nix
                ];
                home.stateVersion = "26.05";
              };
              users.users.nixos.initialPassword = "kiwami";
              kiwami.autoLogin = true;
              virtualisation.memorySize = 4096;
              virtualisation.cores = 2;
              virtualisation.qemu.options = [ "-vga virtio" ];
            };

            testScript = ''
              machine.wait_for_unit("multi-user.target")

              # greetd autologins straight into Hyprland through uwsm.
              machine.wait_for_unit("greetd.service")

              # Every `systemctl --user` below talks to this manager's bus.
              # Without waiting, an early check races the manager's startup and
              # fails with "Failed to connect to user scope bus" - which looks
              # like a broken unit and is really just an impatient test.
              machine.wait_for_unit("user@1000.service")
              machine.wait_until_succeeds("pgrep -f 'bin/Hyprland'", timeout=120)

              # The shell is a user unit gated on WAYLAND_DISPLAY, so its
              # running at all proves uwsm activated graphical-session.target
              # and exported the environment.
              machine.wait_until_succeeds("pgrep -f 'quickshell -p'", timeout=120)

              # Themes must resolve without a checkout: they come from
              # /etc/kiwami/themes on an installed machine.
              machine.succeed(
                  "su nixos -c 'KIWAMI_REPO=/nonexistent kiwami theme list' | grep -q kiwami"
              )

              # A flapping unit still matches pgrep, so assert it is not
              # restarting. This is the check that would have caught the
              # shell being broken in CI for two green runs.
              #
              # wait_until_succeeds, not succeed: the user bus can still be
              # coming up. A genuinely flapping unit only ever grows NRestarts,
              # so retrying cannot turn a real failure into a pass - it times
              # out instead.
              machine.wait_until_succeeds(
                  "su nixos -c 'XDG_RUNTIME_DIR=/run/user/1000 "
                  "systemctl --user show -p NRestarts --value kiwami-shell.service'"
                  " | grep -qE '^[0-3]$'",
                  timeout=60,
              )

              # Our Hyprland config must actually be loaded. Without this the
              # compositor silently falls back to its autogenerated default -
              # different binds, different wallpaper - and every other
              # assertion still passes.
              machine.wait_until_succeeds(
                  "su nixos -c '"
                  "export XDG_RUNTIME_DIR=/run/user/1000; "
                  "export HYPRLAND_INSTANCE_SIGNATURE=$(systemctl --user show-environment "
                  "| sed -n s/^HYPRLAND_INSTANCE_SIGNATURE=//p); "
                  # gaps_in is 4 in our config and 5 in Hyprland's default,
                  # so this distinguishes them. Binds cannot be used: with a
                  # Lua config hyprctl reports every dispatcher as "__lua".
                  "hyprctl getoption general:gaps_in' | grep -q '4 4 4 4'",
                  timeout=60,
              )

              # The bar manifest is generated from kiwami.bar.*; if this is
              # missing the shell silently falls back to hardcoded defaults
              # and the whole option surface is decorative.
              machine.succeed("test -f /etc/kiwami/bar.json")
              machine.succeed("grep -q '\"position\": *\"top\"' /etc/kiwami/bar.json || grep -q '\"position\":\"top\"' /etc/kiwami/bar.json")

              # Stronger than a screenshot: ask the compositor whether the
              # shell actually mapped a layer surface. A process being alive
              # only proves it started, not that it drew anything.
              machine.wait_until_succeeds(
                  "su nixos -c '"
                  "export XDG_RUNTIME_DIR=/run/user/1000; "
                  "export HYPRLAND_INSTANCE_SIGNATURE=$(systemctl --user show-environment "
                  "| sed -n s/^HYPRLAND_INSTANCE_SIGNATURE=//p); "
                  "hyprctl layers' | grep -q quickshell",
                  timeout=120,
              )

              # Let the first frame land before capturing, or the screenshot is
              # a blank framebuffer that still passes every assertion above.
              machine.sleep(5)
              machine.screenshot("desktop")
            '';
          };
        });

      # The distro as an importable module, so a machine can be built from
      # Kiwami without forking it. Deliberately excludes anything
      # host-specific - hardware, hostname, users - which the consumer
      # supplies alongside it.
      nixosModules.default = { lib, ... }: {
        imports = [
          home-manager.nixosModules.home-manager
          ./modules/common.nix
          ./modules/desktop.nix
          ./modules/options.nix
          ./modules/themes.nix
          ./modules/generated.nix
        ];

        # Modules reach the flake's own inputs (the kiwami package, quickshell)
        # through this rather than the consumer having to thread it.
        _module.args.inputs = inputs;

        nixpkgs.config.allowUnfree = lib.mkDefault true;

        home-manager.useGlobalPkgs = lib.mkDefault true;
        home-manager.useUserPackages = lib.mkDefault true;
        home-manager.extraSpecialArgs = { inherit inputs; };
      };

      nixosConfigurations =
        # The installer image. Deliberately not a hosts/ entry: those all get
        # nixosModules.default, and an installer has no business carrying a
        # Hyprland desktop it will never start.
        let
          # The harness key, present only in the -test images. A shipped
          # installer must not carry a key from this repository; the test
          # variant carries it so `vmssh` works and the whole installer matrix
          # runs against the real image instead of being rewritten to drive a
          # serial console.
          # Missing is an error, not an empty list. A -test image whose entire
          # purpose is carrying this key built happily without one, and the
          # only symptom was ssh refusing a connection several minutes later.
          harnessKey =
            let f = ./vm/keys/kiwami_vm.pub;
            in if builtins.pathExists f
               then [ (builtins.readFile f) ]
               else throw ''
                 installer-*-test needs vm/keys/kiwami_vm.pub, which is not in
                 this flake. Generate it with `just vm install`, and remember
                 that flakes only see git-tracked files.
               '';

          mkInstaller = { system, testKey ? false }:
        nixpkgs.lib.nixosSystem {
          specialArgs = { inherit inputs; };
          modules = [
            ({ modulesPath, pkgs, lib, ... }: {
              imports = [ (modulesPath + "/installer/cd-dvd/installation-cd-minimal.nix") ];

              nixpkgs.hostPlatform = system;

              # The whole point: `kiwami install`, not a nix run incantation.
              # git comes too - installing a new machine needs a writable
              # checkout to generate hardware.nix into.
              environment.systemPackages = [
                self.packages.${system}.kiwami
                pkgs.git
                # `kiwami remote` drives this. Present but not started: joining
                # a tailnet is an explicit act, not something live media should
                # do on its own.
                pkgs.tailscale
              ];

              systemd.services.tailscaled = {
                description = "Tailscale, started on demand by `kiwami remote`";
                wantedBy = lib.mkForce [ ];
                serviceConfig.ExecStart = "${pkgs.tailscale}/bin/tailscaled";
              };

              users.users.nixos.openssh.authorizedKeys.keys =
                lib.optionals testKey harnessKey;

              # The installer shells out to `nix build` for the disko script,
              # and the stock ISO does not enable flakes.
              nix.settings.experimental-features = [ "nix-command" "flakes" ];

              # zstd, not the default xz: the image is recompressed in full for
              # every change, however small, and that cost dominates the build.
              # A throwaway image booted in QEMU does not care about its size.
              isoImage.squashfsCompression = "zstd -Xcompression-level 3";

              # Long enough to actually catch. The default hurried past too
              # fast to pick anything from the boot menu.
              boot.loader.timeout = 10;

              # Keep the serial console so the harness can drive the image
              # exactly as it drives the stock ISO.
              #
              # copytoram reads the squashfs into memory once, at boot, and
              # runs from there. Without it the whole live system is paged off
              # the USB stick for the length of the install, and a link that
              # drops - a portable SSD renegotiating power, a marginal USB-C
              # port - takes everything with it: squashfs I/O errors, then
              # processes segfaulting because their pages cannot be read back.
              # Seen on an XPS 13 mid-install.
              #
              # It costs the image's size in RAM (1.5G here) and a slower boot,
              # which is one long sequential read instead of thousands of small
              # random ones under load. That trade is worth taking by default;
              # a machine too small for it is not one this installs on.
              boot.kernelParams =
                [ "console=tty0" "copytoram" ]
                ++ lib.optional (system == "aarch64-linux") "console=ttyAMA0,115200"
                ++ lib.optional (system == "x86_64-linux") "console=ttyS0,115200";

              services.getty.helpLine = lib.mkForce ''

                Kiwami installer.

                  sudo kiwami net                 get online, if you are not
                  sudo kiwami remote              reachable over your tailnet, for help debugging
                  sudo kiwami install             reinstall a machine this flake already describes

                For a new machine, which needs somewhere to write its detected
                hardware:

                  git clone https://github.com/jimzer/kiwami ~/kiwami
                  sudo kiwami install --flake ~/kiwami --host <name> --new
              '';
            })
          ];
        };
        in
        nixpkgs.lib.genAttrs hostNames (name: mkHost [ (./hosts + "/${name}") ])
        // {
          installer-x86_64 = mkInstaller { system = "x86_64-linux"; };
          installer-aarch64 = mkInstaller { system = "aarch64-linux"; };

          # Same image plus the harness key, so the installer matrix can be
          # run against the media people actually boot.
          installer-aarch64-test =
            mkInstaller { system = "aarch64-linux"; testKey = true; };
        };
    };
}
