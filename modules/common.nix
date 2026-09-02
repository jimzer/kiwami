# Settings every Kiwami host gets, regardless of hardware.
{ config, lib, pkgs, inputs, ... }:

{
  nix.settings = {
    experimental-features = [ "nix-command" "flakes" ];
    auto-optimise-store = true;
  };

  time.timeZone = lib.mkDefault "Europe/Zurich";
  i18n.defaultLocale = lib.mkDefault "en_US.UTF-8";

  # One way to set a password, everywhere. `passwd` writes to /etc/shadow,
  # which an ephemeral root discards while reporting success - so rather than
  # supporting two modes and explaining when each applies, users are immutable
  # on every machine and the hash comes from a file. nixpkgs drops the setuid
  # passwd wrapper when mutableUsers is off, so the wrong command is absent
  # rather than merely wrong.
  users.mutableUsers = false;

  users.users.${config.kiwami.user} = {
    isNormalUser = true;
    extraGroups = [ "wheel" "video" "audio" "networkmanager" ];
    # Written by `kiwami install`, changed by `kiwami passwd`. Without it the
    # account has no password at all - and with immutable users there is no
    # initialPassword fallback, so that is discovered at a greeter.
    hashedPasswordFile = "${config.kiwami.passwordFile}/${config.kiwami.user}";
  };
  security.sudo.wheelNeedsPassword = false;

  # State this distro knows it needs. Everything here was learned the hard
  # way or is a well-known trap:
  #
  #   ssh host keys      - regenerate and every client warns about a changed
  #                        key, which is indistinguishable from an attack
  #   /var/lib/nixos     - uid and gid allocation. Lose it and a rebuilt user
  #                        can get a different uid than the files they own
  #   /var/lib/systemd   - machine-id, which journald and much else key on
  #   NetworkManager     - the wifi networks you have joined, and separately
  #                        NM's own state: leases and seen-bssids. Declaring
  #                        only the profiles leaves it half-remembering
  #                        networks. Found by the doctor check, not by me
  #   tailscale          - the node identity; losing it means a fresh browser
  #                        login on a machine that may have no browser
  #   /var/lib/kiwami    - the keyfile that opens a second encrypted disk
  kiwami.persist.directories = [
    "/var/lib/nixos"
    "/var/lib/systemd"
    "/var/lib/kiwami"
    "/etc/NetworkManager/system-connections"
    "/var/lib/NetworkManager"
  ] ++ lib.optional config.services.tailscale.enable "/var/lib/tailscale";

  kiwami.persist.files = [
    "/etc/machine-id"
    "/etc/ssh/ssh_host_ed25519_key"
    "/etc/ssh/ssh_host_ed25519_key.pub"
    "/etc/ssh/ssh_host_rsa_key"
    "/etc/ssh/ssh_host_rsa_key.pub"
  ];

  # NetworkManager, not scripted DHCP. `kiwami net` drives nmcli, so without
  # this the command ships on every machine and works on none of them - and a
  # laptop with no way to join a wireless network is not a laptop. The VM
  # never noticed, having only ever had a wired connection that came up by
  # itself.
  networking.networkmanager.enable = lib.mkDefault true;
  # NetworkManager owns the interfaces; leaving the scripted DHCP client on as
  # well means two things bringing up the same link.
  networking.useDHCP = lib.mkDefault false;

  # The daemon, running but joined to nothing. `tailscale up` - which is what
  # `kiwami remote` calls - is still an explicit act, so this grants no access
  # by itself; it only means the machine can be reached for help without
  # first having to install something on a machine that has no network.
  services.tailscale.enable = lib.mkDefault true;

  services.openssh = {
    enable = true;
    settings.PasswordAuthentication = lib.mkDefault true;
  };

  environment.systemPackages = [
    # The distro's own CLI, built from cli/ by this flake.
    inputs.self.packages.${pkgs.stdenv.hostPlatform.system}.kiwami

    # And passwd taken away. Immutable users drop its setuid wrapper, so an
    # unprivileged passwd fails loudly - but `sudo passwd` still reports
    # "password updated successfully" and is reverted at the next activation.
    # That was verified, not assumed. Detecting it afterwards is worse than
    # not shipping the footgun, so the binary is shadowed by one that says
    # where to go instead. hiPrio wins the collision with the shadow package,
    # which is still needed for su and friends.
    (lib.hiPrio (pkgs.writeShellScriptBin "passwd" ''
      echo "passwd does nothing here: users are immutable, so the hash comes" >&2
      echo "from a file and /etc/shadow is regenerated at activation." >&2
      echo >&2
      echo "  sudo kiwami passwd" >&2
      exit 1
    ''))
  ] ++ (with pkgs; [ git vim curl htop rsync jq ]);
}
